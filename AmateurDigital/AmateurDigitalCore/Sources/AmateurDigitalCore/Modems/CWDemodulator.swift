//
//  CWDemodulator.swift
//  AmateurDigitalCore
//
//  CW demodulator: decodes CW (Morse code) audio to text
//
//  Algorithm:
//  1. Goertzel tone detection at configurable frequency (10ms blocks)
//  2. Adaptive threshold using independent signal/noise level tracking
//  3. State machine: idle → in-tone → after-tone → idle
//  4. Adaptive speed tracking via dot-dash pair validation (fldigi-style)
//  5. Morse binary tree character lookup
//  6. AFC via multi-bin Goertzel scanning
//

import Foundation

/// Delegate protocol for receiving demodulated CW characters
public protocol CWDemodulatorDelegate: AnyObject {
    func demodulator(
        _ demodulator: CWDemodulator,
        didDecode character: Character,
        atFrequency frequency: Double
    )

    func demodulator(
        _ demodulator: CWDemodulator,
        signalDetected detected: Bool,
        atFrequency frequency: Double
    )
}

/// CW Demodulator for reception
public final class CWDemodulator {

    private enum RxState {
        case idle
        case inTone
        case afterTone
    }

    // MARK: - Configuration

    private var configuration: CWConfiguration
    public weak var delegate: CWDemodulatorDelegate?

    // MARK: - Tone Detection

    private var toneFilter: GoertzelFilter
    private let blockSize: Int
    private var sampleBuffer: [Float] = []

    /// Narrow FFT bandpass filter centered on the CW tone for noise rejection.
    /// OverlapAddFilter provides -73 dB stopband rejection vs ~-12 dB from IIR biquad,
    /// dramatically reducing false tone detections from out-of-band noise.
    private var fftBandpassFilter: OverlapAddFilter

    // MARK: - Adaptive Threshold

    /// Tracked signal level (power when tone present)
    private var signalLevel: Double = 0

    /// Tracked noise level (power when silence)
    private var noiseLevel: Double = 1e-10

    /// Fast-tracking signal level for threshold adaptation during fading
    private var recentSignal: Double = 0

    /// Whether we've bootstrapped the signal level
    private var signalBootstrapped: Bool = false

    /// Block counter
    private var blockCount: Int = 0

    /// Whether initial AFC scan has been done
    private var afcInitialScanDone: Bool = false

    /// Noise floor estimation during preamble
    private var noiseEstimateAccum: Double = 0

    /// Hysteresis gate: open while a tone is being tracked
    private var toneGateOpen: Bool = false

    // MARK: - Sub-Block Edge Timing

    /// Fractions (0–1) into the gate-transition blocks where the tone
    /// edge actually sits, measured from quarter-block Goertzel powers.
    /// 0.5 is neutral: with both fractions at 0.5 every duration below
    /// reduces exactly to the historical whole-block value, so the
    /// refinement only removes quantization jitter around it. At 10 ms
    /// blocks, ±1 block is 25–37% of a dit at 30–45 WPM — the binding
    /// timing error at speed; quarter-block edges cut it to ~9%.
    private var toneStartFraction: Double = 0.5
    private var toneEndFraction: Double = 0.5

    /// Locate the tone edge inside a gate-transition block. Falls back to
    /// neutral (0.5) when SNR is too poor for quarter-block decisions or
    /// the sub-blocks disagree with the block-level verdict.
    private func measureEdgeFraction(block: [Float], fullBlockThreshold: Double, rising: Bool) -> Double {
        guard signalBootstrapped, signalLevel > noiseLevel * 10 else { return 0.5 }
        let sub = blockSize / 4
        guard sub >= 32 else { return 0.5 }
        // Coherent tone power scales as N², so a quarter block sees 1/16
        // of the full-block power.
        let subThreshold = Float(fullBlockThreshold / 16.0)
        for i in 0..<4 {
            var filter = GoertzelFilter(
                frequency: currentToneFrequency,
                sampleRate: configuration.sampleRate,
                blockSize: sub
            )
            let power = filter.processBlock(Array(block[(i * sub)..<((i + 1) * sub)]))
            if rising, power > subThreshold {
                return Double(i) / 4.0        // tone begins here
            }
            if !rising, power < subThreshold {
                return Double(i) / 4.0        // tone ended here
            }
        }
        return 0.5
    }

    // MARK: - Min-Statistics Noise Tracking

    /// Rolling-minimum noise floor: the estimate can never exceed
    /// minStatsFactor × the quietest ~100 ms seen in the last second.
    /// Rescues the decoder when the startup preamble "noise" estimate was
    /// contaminated by a tone already on the air (cold start, post-TX
    /// resume): inter-element gaps expose the true floor within a second.
    private var minStatsSubMin: Double = .greatestFiniteMagnitude
    private var minStatsRing: [Double] = []
    private var minStatsBlockCount: Int = 0
    /// Smoothed power feeding the rolling minimum. Raw Goertzel noise
    /// power is ~exponentially distributed, so a raw minimum over 100
    /// blocks sits far below the mean and would drag the floor down in
    /// legitimate noise; smoothing first narrows the distribution.
    private var minStatsSmoothed: Double = 0
    /// Multiplier from the rolling minimum (a low-biased order statistic)
    /// to a usable mean-noise estimate.
    public var minStatsFactor: Double = 6.0

    // MARK: - State Machine

    private var state: RxState = .idle
    private var stateDurationBlocks: Int = 0

    /// Silent blocks since the last tone ended (-1 = no tone yet).
    /// Unlike stateDurationBlocks this survives the afterTone→idle
    /// transition, so gaps that cross into idle (Farnsworth character
    /// gaps read as word gaps) still reach the gap-cluster learner.
    private var blocksSinceToneEnd: Int = -1

    /// Consecutive above-threshold blocks before first bootstrap.
    private var bootstrapRun: Int = 0

    // MARK: - Adaptive Gap Clustering

    /// Learned gap statistics in dit units. Fixed multiples (2× / 5×)
    /// split Farnsworth senders (stretched inter-character gaps read as
    /// word gaps) and merge run-together fists (gaps under 2 dits).
    /// Tracking the sender's actual intra- and inter-character gap
    /// clusters puts both boundaries where *this* fist keys them.
    private var intraGapDits: Double = 1.0
    private var charGapDits: Double = 3.0
    /// Recent above-boundary (inter-character and word) gaps, in dits.
    private var recentCharGaps: [Double] = []

    private var interCharThresholdDits: Double {
        min(max((intraGapDits * charGapDits).squareRoot() * 1.08, 1.35), 3.6)
    }

    /// Word boundary from an order statistic of the observed gap window:
    /// 1.6× the second-smallest recent above-boundary gap. Word gaps are
    /// ≥ 2.3× inter-character gaps in any consistent fist (7:3 nominal),
    /// so this locks on after two character gaps — fast enough to follow
    /// a Farnsworth sender whose character gaps exceed a fixed 5×dit rule
    /// within one word. An EMA converges far too slowly for that.
    private var wordThresholdDits: Double {
        guard recentCharGaps.count >= 2 else {
            return min(max(charGapDits * 1.8, 2.6), 40.0)
        }
        let sorted = recentCharGaps.sorted()
        return min(max(sorted[1] * 1.6, 2.6), 40.0)
    }

    private func updateGapClusters(gapDits: Double) {
        guard gapDits > 0.15, gapDits < 60 else { return }
        // Assign to the nearer cluster in log space — NOT by the flush
        // boundary. A compressed fist's char gaps can sit just under a
        // stale boundary; boundary-based assignment then feeds them to the
        // intra cluster, which drags the boundary up further (runaway).
        let dIntra = abs(log(gapDits / max(intraGapDits, 0.1)))
        let dChar = abs(log(gapDits / max(charGapDits, 0.1)))
        if dIntra < dChar {
            intraGapDits = min(max(intraGapDits * 0.8 + gapDits * 0.2, 0.5), 1.9)
        } else {
            // Clamped step so occasional word gaps can't drag the
            // inter-character cluster up to the word cluster.
            let step = min(max(gapDits - charGapDits, -0.3 * charGapDits), 0.3 * charGapDits)
            charGapDits = min(max(charGapDits + step * 0.25, intraGapDits * 1.7), 30)
            // Seed the window with a double entry so the word threshold
            // locks on after the FIRST character gap, not the second —
            // one spurious word break per transmission start otherwise.
            if recentCharGaps.isEmpty { recentCharGaps.append(gapDits) }
            recentCharGaps.append(gapDits)
            if recentCharGaps.count > 12 { recentCharGaps.removeFirst() }
        }
    }

    // MARK: - Speed Tracking

    private var ditBlocks: Double
    /// Initial dit estimate from configuration (used as a floor for gap thresholds)
    private var initialDitBlocks: Double
    private var speedTracker: [Double] = []
    private let speedTrackerSize: Int = 16
    private var lastKeyDownBlocks: Double = 0
    private var lastElementWasDit: Bool = true

    // MARK: - Morse Decoder

    /// Duration of the last inTone period (for debounce merging)
    private var lastToneDuration: Int = 0

    private var currentElements: [MorseElement] = []
    private var characterFlushed: Bool = false
    private var wordSpaceEmitted: Bool = false

    // MARK: - Signal Detection

    private var _signalDetected: Bool = false
    private var toneBlocksSeen: Int = 0

    // MARK: - AFC

    private var afcFilters: [GoertzelFilter] = []
    private var afcCenterFilter: GoertzelFilter
    private var afcOffsets: [Double] = []
    private var afcBlockCount: Int = 0
    private let afcUpdateInterval: Int = 30  // Update every 30 blocks (~300ms) for faster tracking
    private var afcAccumulators: [Double] = []
    private var afcCenterAccum: Double = 0
    private var currentToneFrequency: Double

    // MARK: - Phase-Slope Fine AFC

    /// Sub-bin frequency tracking from the Goertzel phase advance between
    /// consecutive in-tone blocks. Follows slow VFO drift continuously —
    /// something the 25 Hz coarse scan can't do while the health veto
    /// (rightly) blocks retunes on a strong signal — and rebuilds only
    /// the cheap Goertzel bank, not the FIR, until cumulative drift
    /// approaches the passband edge. Unambiguous to ±(blockRate/2) ≈ ±50 Hz.
    private var lastTonePhase: Double?
    private var fineFreqError: Double = 0
    private var firCenterFrequency: Double

    // MARK: - Public Properties

    public var estimatedWPM: Double {
        let blockDuration = Double(blockSize) / configuration.sampleRate
        let ditSeconds = ditBlocks * blockDuration
        guard ditSeconds > 0 else { return configuration.wpm }
        return MorseCodec.wpm(forDitDuration: ditSeconds)
    }

    public var signalDetected: Bool { _signalDetected }
    public var toneFrequency: Double { currentToneFrequency }

    public var signalStrength: Float {
        guard signalLevel > 0 && noiseLevel > 0 else { return 0 }
        return Float(min(1.0, (signalLevel / noiseLevel) / 20.0))
    }

    public var currentConfiguration: CWConfiguration { configuration }
    public var minWPM: Double = 4.0
    public var maxWPM: Double = 60.0

    /// Enable debug output
    public var debugEnabled: Bool = false

    // MARK: - Tunable Parameters (for Optuna/CMA-ES optimization)

    /// Threshold fraction for clean signals (SNR > 100). Lower = more sensitive
    /// to fading and to amplitude modulation from receiver AGC pumping: a
    /// nearby station's keying can swing the whole passband ±7.5 dB, which
    /// pushes the tone's trough to ~0.18× its tracked peak. At SNR ≥ 100 a
    /// fraction of 0.08 still leaves the threshold ~9× above the noise floor,
    /// so sensitivity costs no false triggers. (Benchmark: agc_pumping
    /// 62 → 100 with no regression in clean/noise/fading.)
    public var thresholdFractionClean: Double = 0.08
    /// Threshold fraction for moderate noise (SNR > 10).
    public var thresholdFractionModerate: Double = 0.30
    /// Threshold fraction for heavy noise (SNR ≤ 10). Higher = fewer false detections.
    public var thresholdFractionNoisy: Double = 0.40
    /// Signal level decay rate (0-1). Higher = slower decay, more fading resilience.
    public var signalDecayRate: Double = 0.85
    /// Multiplier on noise level for initial tone detection threshold.
    public var toneDetectMultiplier: Double = 5.0
    /// Multiplier on noise level for first-signal bootstrap threshold.
    public var bootstrapMultiplier: Double = 8.0
    /// Hysteresis: the tone-off threshold as a fraction of the tone-on
    /// threshold (above noise). Once a tone opens the gate it stays open
    /// until power falls below the lower threshold, so mid-element dips
    /// (AGC pumping, flutter) don't chop elements while the on-threshold
    /// stays high enough to keep edges crisp. 1.0 = no hysteresis.
    public var hysteresisOffRatio: Double = 1.0

    /// Elements that must accumulate after a fresh bootstrap before held
    /// characters can be released (see `emissionConfirmed`).
    public var probationMinElements: Int = 8
    /// Per-class (dit, dah) coefficient of variation ceiling for
    /// confirmation. Hand-sent swing is a systematic bias — its clusters
    /// shift but stay tight — while noise-burst "elements" are a
    /// continuum that a threshold split can't make tight.
    public var probationMaxClassCV: Double = 0.28
    /// Mean gap rhythm error ceiling (gaps vs the 1/3/7-dit grid),
    /// lenient enough for compressed hand-sent spacing.
    public var probationMaxGapError: Double = 0.40
    /// Post-confirmation rhythm EMA above which emission is revoked and
    /// probation restarts. A signal that stops keying cleanly (noise
    /// after a squeaked-through confirmation) gets cut off within a few
    /// characters instead of chattering until un-bootstrap. Real copy
    /// holds ~0.05–0.15 even hand-sent; noise sits near 0.3. A genuine
    /// speed change can spike across this bar — that revokes emission,
    /// but revoked characters are held and re-flushed when the new
    /// speed confirms, so the cost is latency, not lost copy.
    public var probationRevokeEMA: Double = 0.25

    /// Dump each probation evaluation (benchmark tuning aid).
    public var probationDebug = false

    /// False until the first post-bootstrap characters prove CW-like
    /// element rhythm. Impulsive room noise, level wander, and tonal
    /// flutter all pass the amplitude gates (they bootstrap the tracker
    /// and clear the SNR emission bar during bursts), but their "element"
    /// durations are random where real keying clusters tightly at 1 and
    /// 3 dits. Until confirmation, decoded characters are held in
    /// `probationChars` — released together on confirmation, discarded
    /// at un-bootstrap.
    private var emissionConfirmed = false
    private var probationDurations: [Double] = []
    private var probationGaps: [Double] = []
    private var probationChars: [Character] = []
    private var rhythmEMA = 0.0
    private let probationWindow = 16
    /// Element count at the first passing evaluation: confirmation
    /// requires the check to still pass `probationSustain` elements
    /// later, so one lucky noise window can't open the gate.
    private var provisionalSince: Int?
    private var probationElementCount = 0
    private let probationSustain = 4

    // MARK: - Initialization

    public init(configuration: CWConfiguration = .standard) {
        self.configuration = configuration
        self.currentToneFrequency = configuration.toneFrequency
        self.firCenterFrequency = configuration.toneFrequency
        self.blockSize = configuration.goertzelBlockSize

        self.toneFilter = GoertzelFilter(
            frequency: configuration.toneFrequency,
            sampleRate: configuration.sampleRate,
            blockSize: blockSize
        )

        let ditSeconds = MorseCodec.ditDuration(forWPM: configuration.wpm)
        let blockDuration = Double(blockSize) / configuration.sampleRate
        self.ditBlocks = ditSeconds / blockDuration
        self.initialDitBlocks = ditSeconds / blockDuration

        // FFT bandpass filter: ±100 Hz around the CW tone with -73 dB stopband rejection.
        // 513 taps gives ~374 Hz transition band → -73 dB at ±474 Hz from center.
        // Much better than the IIR biquad's ~-12 dB at ±200 Hz.
        self.fftBandpassFilter = OverlapAddFilter.bandpass(
            lowCutoff: configuration.toneFrequency - 100,
            highCutoff: configuration.toneFrequency + 100,
            sampleRate: configuration.sampleRate,
            taps: 513
        )

        // AFC filters: ±250 Hz in 25 Hz steps for finer tracking
        var offsets: [Double] = []
        var filters: [GoertzelFilter] = []
        var off = -250.0
        while off <= 250.0 {
            if off != 0 {
                offsets.append(off)
                filters.append(GoertzelFilter(
                    frequency: configuration.toneFrequency + off,
                    sampleRate: configuration.sampleRate,
                    blockSize: blockSize
                ))
            }
            off += 25.0
        }
        self.afcOffsets = offsets
        self.afcFilters = filters
        self.afcAccumulators = [Double](repeating: 0, count: filters.count)
        self.afcCenterFilter = GoertzelFilter(
            frequency: configuration.toneFrequency,
            sampleRate: configuration.sampleRate,
            blockSize: blockSize
        )
    }

    // MARK: - Processing

    /// Raw (unfiltered) sample buffer for AFC
    private var rawSampleBuffer: [Float] = []

    // MARK: - Noise Blanker

    /// Running mean-absolute level for the impulse blanker.
    private var blankerLevel: Float = 0
    /// Clip threshold as a multiple of the running level. QRN static
    /// crashes are broadband and 5–20× the running level; unclipped they
    /// ring through the narrow FIR for its whole impulse response. A CW
    /// tone peaks well under 2× its own mean-absolute level, so 4× never
    /// touches the signal. Set very large to disable.
    public var blankerThreshold: Float = 4.0

    /// Clip impulsive spikes before they reach the narrow filter.
    private func blankImpulses(_ samples: [Float]) -> [Float] {
        var out = samples
        for i in 0..<out.count {
            let magnitude = abs(out[i])
            // Fast attack (~5 ms) so a keyed tone raises the level before
            // much of its onset clips; slow decay holds through gaps.
            if blankerLevel <= 0 {
                blankerLevel = magnitude
            } else if magnitude > blankerLevel {
                blankerLevel += (magnitude - blankerLevel) * 0.004
            } else {
                blankerLevel += (magnitude - blankerLevel) * 0.0005
            }
            let limit = blankerLevel * blankerThreshold
            if magnitude > limit, limit > 0 {
                out[i] = out[i] > 0 ? limit : -limit
            }
        }
        return out
    }

    public func process(samples: [Float]) {
        let samples = blankImpulses(samples)

        // Apply narrow FFT bandpass to entire batch for superior noise rejection.
        // The filter handles internal buffering and may output fewer samples than input
        // during the initial fill, which is fine since the first 200ms is noise estimation.
        let filtered = fftBandpassFilter.process(samples)

        // Buffer raw samples for AFC (unfiltered, so AFC can detect off-frequency signals)
        rawSampleBuffer.append(contentsOf: samples)

        // Buffer filtered samples for the main Goertzel detector
        sampleBuffer.append(contentsOf: filtered)

        // Process blocks when we have enough filtered samples
        while sampleBuffer.count >= blockSize {
            let filteredBlock = Array(sampleBuffer.prefix(blockSize))
            sampleBuffer.removeFirst(blockSize)

            let rawBlock: [Float]
            if rawSampleBuffer.count >= blockSize {
                rawBlock = Array(rawSampleBuffer.prefix(blockSize))
                rawSampleBuffer.removeFirst(blockSize)
            } else {
                rawBlock = filteredBlock
            }

            processBlock(filteredBlock, rawBlock: rawBlock)
        }
    }

    private func processBlock(_ block: [Float], rawBlock: [Float]) {
        // Main Goertzel uses bandpass-filtered signal for better SNR.
        // Complex output: |X|² is identical to the power formula, and the
        // phase drives the fine AFC.
        var filter = toneFilter
        let complexOut = filter.processBlockComplex(block)
        toneFilter = filter
        let goertzelPower = Double(complexOut.real) * Double(complexOut.real)
            + Double(complexOut.imag) * Double(complexOut.imag)

        let rawPower = goertzelPower

        // AFC bins only pay for themselves during acquisition and
        // re-acquisition; while locked-and-healthy or with no signal at
        // all, updateAFC discards them unread. At 21 Goertzels per block
        // per decoder they were the app's single largest CPU cost — iOS's
        // watchdog was killing backgrounded listens (cpu_resource_fatal,
        // 98% of a core sustained).
        let afcAcquiring = signalBootstrapped
            && (!afcInitialScanDone
                || (_signalDetected && signalLevel <= noiseLevel * 25))
        if afcAcquiring {
            // AFC uses unfiltered signal to detect off-frequency signals
            for i in 0..<afcFilters.count {
                var f = afcFilters[i]
                let p = Double(f.processBlock(rawBlock))
                afcFilters[i] = f
                afcAccumulators[i] += p
            }
            // Center accumulator uses unfiltered signal for fair comparison
            var centerFilter = afcCenterFilter
            afcCenterAccum += Double(centerFilter.processBlock(rawBlock))
            afcCenterFilter = centerFilter
        }
        afcBlockCount += 1

        // Track signal bootstrap transition for AFC reset
        let wasBootstrapped = signalBootstrapped

        // (signalBootstrapped may change below in the signal/noise tracking section)
        // For now, use the pre-existing value for AFC triggering

        let shouldRunAFC = afcBlockCount >= afcUpdateInterval ||
            (wasBootstrapped && !afcInitialScanDone && afcBlockCount >= 3)

        if shouldRunAFC {
            // Run the scan BEFORE marking it done: updateAFC() must see
            // `afcInitialScanDone == false` during the initial acquisition
            // pass so it uses the eager margin and skips the locked-signal
            // health veto (an attenuated off-frequency tone still reads
            // "healthy", which would block acquisition entirely).
            updateAFC()
            if !afcInitialScanDone && wasBootstrapped {
                afcInitialScanDone = true
            }
            afcBlockCount = 0
            afcCenterAccum = 0
            for i in 0..<afcAccumulators.count { afcAccumulators[i] = 0 }
        }

        blockCount += 1
        updateMinStats(power: rawPower)

        // Phase 1: Noise floor estimation from preamble (first 20 blocks = 200ms)
        // Longer estimation gives a more stable initial noise reference
        if blockCount <= 20 {
            noiseEstimateAccum += rawPower
            if blockCount == 20 {
                noiseLevel = max(noiseEstimateAccum / 20.0, 1e-10)
            }
            return
        }

        // Update fast-tracking recent signal estimate (follows fading quickly)
        // Use toneDetectMultiplier × noise threshold to prevent noise spikes from contaminating
        if rawPower > noiseLevel * toneDetectMultiplier {
            // This power level is clearly a tone — track it fast
            if rawPower > recentSignal {
                recentSignal = rawPower  // Instant attack
            } else {
                recentSignal = recentSignal * 0.8 + rawPower * 0.2  // Fast decay
            }
        } else {
            // Slowly decay recentSignal when no tone present
            recentSignal = recentSignal * 0.98 + rawPower * 0.02
        }

        // Determine tone presence using adaptive threshold with hysteresis
        let thresholdOn: Double
        let thresholdOff: Double
        if signalBootstrapped {
            // Use geometric mean of signal and recent signal for fading resilience
            let effectiveSignal = sqrt(signalLevel * max(recentSignal, noiseLevel * 2))
            // Adaptive threshold position: closer to noise when clean, higher when noisy
            // SNR determines how aggressive the threshold can be
            let snr = effectiveSignal / max(noiseLevel, 1e-10)
            let thresholdFraction: Double
            if snr > 100 {
                thresholdFraction = thresholdFractionClean
            } else if snr > 10 {
                thresholdFraction = thresholdFractionModerate
            } else {
                thresholdFraction = thresholdFractionNoisy
            }
            let range = effectiveSignal - noiseLevel
            thresholdOn = noiseLevel + thresholdFraction * range
            // OFF floor at 3× noise so the hysteresis gap can never sit
            // inside the noise distribution (see BayesianCWDecoder).
            thresholdOff = max(noiseLevel + thresholdFraction * hysteresisOffRatio * range,
                               noiseLevel * 3.0)
        } else {
            // Before first signal: detect anything significantly above noise
            thresholdOn = noiseLevel * bootstrapMultiplier
            thresholdOff = noiseLevel * max(bootstrapMultiplier * hysteresisOffRatio, 3.0)
        }

        let gateWasOpen = toneGateOpen
        if toneGateOpen {
            toneGateOpen = rawPower > thresholdOff
        } else {
            toneGateOpen = rawPower > thresholdOn
        }
        let toneOn = toneGateOpen
        let toneOff = !toneGateOpen
        let threshold = thresholdOn   // for debug output and level tracking

        // Refine the edge position inside the transition block.
        if toneOn && !gateWasOpen {
            toneStartFraction = measureEdgeFraction(block: block, fullBlockThreshold: thresholdOn, rising: true)
        } else if toneOff && gateWasOpen {
            toneEndFraction = measureEdgeFraction(block: block, fullBlockThreshold: thresholdOff, rising: false)
        }

        if debugEnabled && (blockCount <= 80 || (toneOn && state != .inTone) || (toneOff && state == .inTone)) {
            let stateStr: String
            switch state {
            case .idle: stateStr = "IDLE"
            case .inTone: stateStr = "TONE"
            case .afterTone: stateStr = "GAP "
            }
            print("  blk=\(blockCount) pwr=\(String(format:"%.1f", rawPower)) thr=\(String(format:"%.1f", threshold)) \(toneOn ? "ON" : "  ") \(toneOff ? "OFF" : "   ") st=\(stateStr) dur=\(stateDurationBlocks) sig=\(String(format:"%.1f", signalLevel)) noi=\(String(format:"%.2e", noiseLevel)) boot=\(signalBootstrapped) elms=\(currentElements.count)")
        }

        // Update signal/noise tracking based on current detection state
        if toneOn {
            if !signalBootstrapped {
                // Require two consecutive qualifying blocks: a lone noise
                // spike exceeds 8× the floor a few times a minute, and a
                // real element can't be shorter than two blocks anyway.
                // (One spike bootstrapping the tracker was the source of
                // endless E/T strings on an idle frequency.)
                bootstrapRun += 1
                if bootstrapRun >= 2 {
                    signalLevel = rawPower
                    signalBootstrapped = true
                    // Reset AFC accumulators for clean initial frequency measurement
                    afcBlockCount = 0
                    afcCenterAccum = 0
                    for i in 0..<afcAccumulators.count { afcAccumulators[i] = 0 }
                }
            } else {
                // Faster tracking for signal level to handle fading (QSB)
                // Fast attack (signal rising), faster decay for multipath resilience.
                // Multipath can cancel the tone rapidly (0.5ms delay at 700 Hz = 60% drop).
                // Decay of 0.85/0.15 (7 block = ~70ms) tracks these dips within one dit.
                if rawPower > signalLevel {
                    signalLevel = signalLevel * 0.7 + rawPower * 0.3
                } else {
                    signalLevel = signalLevel * signalDecayRate + rawPower * (1.0 - signalDecayRate)
                }
            }
        } else if toneOff {
            bootstrapRun = 0
            // Track noise floor only during sustained silence (inter-char or word gaps)
            // Brief intra-element gaps don't represent the true noise floor and
            // can contain residual energy from envelope shaping, which would
            // artificially raise the threshold and hurt fading performance
            if state == .idle || (state == .afterTone && stateDurationBlocks > Int(ditBlocks * 1.5)) {
                noiseLevel = noiseLevel * 0.95 + rawPower * 0.05
                noiseLevel = max(noiseLevel, 1e-10)
            }
        }

        // Run state machine with raw power vs threshold
        processStateMachine(toneOn: toneOn, toneOff: toneOff)

        // Fine AFC from phase advance (needs the post-transition state)
        updateFineAFC(real: complexOut.real, imag: complexOut.imag)

        // Signal detection
        updateSignalDetection()
    }

    // MARK: - Fine AFC

    private func updateFineAFC(real: Float, imag: Float) {
        guard state == .inTone, stateDurationBlocks >= 2, signalBootstrapped,
              signalLevel > noiseLevel * 25 else {
            lastTonePhase = nil
            return
        }
        // Impulse guard: a QRN burst on top of the tone scrambles the
        // phase; skip blocks whose power is far outside the tracked level.
        let blockPower = Double(real) * Double(real) + Double(imag) * Double(imag)
        guard blockPower < signalLevel * 4 else {
            lastTonePhase = nil
            return
        }
        let phase = Double(atan2(imag, real))
        guard let last = lastTonePhase else {
            lastTonePhase = phase
            return
        }
        let blockDuration = Double(blockSize) / configuration.sampleRate
        // The per-block phase advance of a tone at exactly the filter
        // frequency; deviation from it measures the frequency error.
        let expected = 2.0 * .pi * currentToneFrequency * blockDuration
        var dphi = (phase - last - expected).truncatingRemainder(dividingBy: 2.0 * .pi)
        if dphi > .pi { dphi -= 2.0 * .pi }
        if dphi < -.pi { dphi += 2.0 * .pi }
        let hzError = dphi / (2.0 * .pi * blockDuration)

        // Reject single-block outliers (flutter, phase noise) — real
        // drift shows up as a consistent small error, not a 20+ Hz jump.
        guard abs(hzError) < 20 else {
            lastTonePhase = phase
            return
        }

        fineFreqError = fineFreqError * 0.85 + hzError * 0.15
        if abs(fineFreqError) > 1.5 {
            // Small bounded steps: genuine drift is a few Hz/s, and a
            // bounded step turns a biased estimate from a runaway into
            // a contained wobble.
            let step = min(max(fineFreqError * 0.8, -3.0), 3.0)
            currentToneFrequency += step
            clampToneFrequency()
            fineFreqError = 0
            lastTonePhase = nil
            retuneGoertzelBank()
        } else {
            lastTonePhase = phase
        }
    }

    /// Retune the Goertzel bank to the current frequency. The FIR bandpass
    /// (±100 Hz wide) is only rebuilt when cumulative drift nears its edge —
    /// a rebuild costs a transient the debounce must absorb, so it's rare.
    /// Never let AFC — coarse or fine — walk out of the plausible CW
    /// band. On real air, beats between two stations or sample slips can
    /// bias the phase tracker into a monotonic walk (observed on-device:
    /// 600 Hz drifting to 74 Hz, after which everything decodes as junk).
    private func clampToneFrequency() {
        let center = configuration.toneFrequency
        currentToneFrequency = min(max(currentToneFrequency, center - 300), center + 300)
    }

    private func retuneGoertzelBank() {
        toneFilter = GoertzelFilter(
            frequency: currentToneFrequency,
            sampleRate: configuration.sampleRate,
            blockSize: blockSize
        )
        for i in 0..<afcFilters.count {
            afcFilters[i] = GoertzelFilter(
                frequency: currentToneFrequency + afcOffsets[i],
                sampleRate: configuration.sampleRate,
                blockSize: blockSize
            )
        }
        afcCenterFilter = GoertzelFilter(
            frequency: currentToneFrequency,
            sampleRate: configuration.sampleRate,
            blockSize: blockSize
        )
        if abs(currentToneFrequency - firCenterFrequency) > 50 {
            fftBandpassFilter = OverlapAddFilter.bandpass(
                lowCutoff: currentToneFrequency - 100,
                highCutoff: currentToneFrequency + 100,
                sampleRate: configuration.sampleRate,
                taps: 513
            )
            firCenterFrequency = currentToneFrequency
        }
    }

    // MARK: - Min-Statistics Update

    private func updateMinStats(power: Double) {
        minStatsSmoothed = minStatsSmoothed == 0 ? power : minStatsSmoothed * 0.8 + power * 0.2
        minStatsSubMin = min(minStatsSubMin, minStatsSmoothed)
        minStatsBlockCount += 1
        guard minStatsBlockCount >= 10 else { return }
        minStatsRing.append(minStatsSubMin)
        if minStatsRing.count > 10 { minStatsRing.removeFirst() }
        minStatsSubMin = .greatestFiniteMagnitude
        minStatsBlockCount = 0
        guard minStatsRing.count >= 5, let rollingMin = minStatsRing.min() else { return }
        let cap = max(rollingMin, 1e-10) * minStatsFactor
        if noiseLevel > cap {
            noiseLevel = cap
        }
    }

    // MARK: - Signal Detection

    private func updateSignalDetection() {
        let hasSignal = signalBootstrapped && signalLevel > noiseLevel * 5

        if hasSignal {
            toneBlocksSeen = min(toneBlocksSeen + 1, 10)
        } else {
            toneBlocksSeen = max(toneBlocksSeen - 1, 0)
        }

        let newDetected = toneBlocksSeen >= 3
        if newDetected != _signalDetected {
            _signalDetected = newDetected
            delegate?.demodulator(self, signalDetected: newDetected, atFrequency: currentToneFrequency)
            if !newDetected {
                flushCharacter()
            }
        }
    }

    // MARK: - State Machine

    private func processStateMachine(toneOn: Bool, toneOff: Bool) {
        switch state {
        case .idle:
            stateDurationBlocks += 1
            if blocksSinceToneEnd >= 0 { blocksSinceToneEnd += 1 }
            if toneOn {
                // A gap that crossed into idle still teaches the clusters.
                if blocksSinceToneEnd > 0 {
                    updateGapClusters(gapDits: Double(blocksSinceToneEnd) / max(ditBlocks, 0.5))
                    recordProbationGap(Double(blocksSinceToneEnd))
                }
                // Emit pending word space before starting new word
                // (gated like characters: junk spaces on an idle band
                // otherwise dribble out of the noise)
                if wordSpaceEmitted {
                    if signalLevel > noiseLevel * 5 {
                        emitOrHold(" ")
                    }
                    wordSpaceEmitted = false
                }
                state = .inTone
                stateDurationBlocks = 1
                characterFlushed = false
            } else {
                // Extended idle — reset signal detection after very long silence
                let idleTimeout = Int(ditBlocks * 30)
                if stateDurationBlocks > idleTimeout {
                    if _signalDetected {
                        _signalDetected = false
                        toneBlocksSeen = 0
                        delegate?.demodulator(self, signalDetected: false, atFrequency: currentToneFrequency)
                    }
                    if signalBootstrapped {
                        // A short transmission that ended before the sustain
                        // window filled gets its last-chance structural check;
                        // anything still held after that was noise.
                        flushPending()
                        // Long dead air: back to acquisition, so decayed level
                        // tracking can't sag the threshold into the noise and
                        // read band noise as endless E/T strings.
                        signalBootstrapped = false
                        signalLevel = 0
                        recentSignal = 0
                        bootstrapRun = 0
                        resetProbation()
                    }
                }
            }

        case .inTone:
            stateDurationBlocks += 1
            if toneOff {
                let keyDownBlocks = stateDurationBlocks
                lastToneDuration = keyDownBlocks
                blocksSinceToneEnd = 0

                // Reject noise spikes shorter than 1/3 of a dit
                let minBlocks = max(2, Int(ditBlocks / 3))
                if keyDownBlocks >= minBlocks {
                    // Sub-block edge corrections (0 when fractions neutral)
                    let duration = Double(keyDownBlocks)
                        + (0.5 - toneStartFraction)
                        + (toneEndFraction - 0.5)
                    classifyElement(duration: duration)
                }

                state = .afterTone
                stateDurationBlocks = 0
                characterFlushed = false
                wordSpaceEmitted = false
            }

        case .afterTone:
            stateDurationBlocks += 1
            if blocksSinceToneEnd >= 0 { blocksSinceToneEnd += 1 }

            if toneOn {
                let gapBlocks = stateDurationBlocks
                // Sub-block edge corrections: gap runs from the previous
                // tone's end fraction to this tone's start fraction.
                let gapDuration = Double(gapBlocks)
                    + (toneStartFraction - 0.5)
                    + (0.5 - toneEndFraction)

                // Debounce: gaps shorter than ~40% of a dit are noise artifacts
                let debounceThreshold = max(2, Int(ditBlocks * 0.4))
                if gapBlocks < debounceThreshold {
                    // Undo the element that was classified when we entered afterTone
                    if !currentElements.isEmpty {
                        currentElements.removeLast()
                    }
                    // Go back to inTone with merged duration
                    state = .inTone
                    stateDurationBlocks = lastToneDuration + gapBlocks + 1
                    break
                }

                let gapDit = ditBlocks  // Use adaptive estimate for gap classification
                let interCharThreshold = gapDit * interCharThresholdDits
                let wordThreshold = gapDit * wordThresholdDits

                // Flush pending character if gap exceeds inter-char threshold
                if gapDuration >= interCharThreshold && !currentElements.isEmpty && !characterFlushed {
                    flushCharacter()
                    characterFlushed = true
                }

                // Emit word space if gap exceeds word threshold
                if gapDuration >= wordThreshold && !wordSpaceEmitted {
                    wordSpaceEmitted = true
                }

                // Emit pending word space before starting next word's elements
                if wordSpaceEmitted {
                    if signalLevel > noiseLevel * 5 {
                        emitOrHold(" ")
                    }
                    wordSpaceEmitted = false
                }

                // A completed tone-to-tone gap is a labeled sample for the
                // sender's gap clusters.
                updateGapClusters(gapDits: gapDuration / max(gapDit, 0.5))
                recordProbationGap(gapDuration)

                state = .inTone
                stateDurationBlocks = 1
            } else {
                let gapBlocks = stateDurationBlocks
                let gapDit = ditBlocks  // Use adaptive estimate for gap classification
                let interCharThreshold = gapDit * interCharThresholdDits
                let wordThreshold = gapDit * wordThresholdDits

                // Inter-character gap: flush pending character
                if Double(gapBlocks) >= interCharThreshold && !currentElements.isEmpty && !characterFlushed {
                    flushCharacter()
                    characterFlushed = true
                }

                // Word gap: emit space and transition to idle
                // (Don't emit trailing space — only emit when followed by more text.
                //  The space is emitted when the NEXT tone arrives in afterTone/idle.)
                if Double(gapBlocks) >= wordThreshold && !wordSpaceEmitted {
                    // Flush any remaining character first
                    if !currentElements.isEmpty && !characterFlushed {
                        flushCharacter()
                        characterFlushed = true
                    }
                    // Mark that a word space is pending — emit it when next tone arrives
                    wordSpaceEmitted = true
                    state = .idle
                    stateDurationBlocks = 0
                }

                // Return to idle after very long silence. Must sit beyond
                // the (possibly Farnsworth-stretched) word threshold or
                // the word branch above could never fire.
                if Double(gapBlocks) >= ditBlocks * max(15.0, wordThresholdDits + 3.0) {
                    state = .idle
                    stateDurationBlocks = 0
                }
            }
        }
    }

    // MARK: - Element Classification

    private func classifyElement(duration: Double) {
        let twoDits = ditBlocks * 2.0

        let element: MorseElement = duration <= twoDits ? .dit : .dah
        currentElements.append(element)
        characterFlushed = false

        if !emissionConfirmed {
            probationElementCount += 1
            probationDurations.append(duration)
            if probationDurations.count > probationWindow {
                probationDurations.removeFirst(probationDurations.count - probationWindow)
            }
        } else {
            // Rhythm watchdog: element error against the 1/3-dit grid.
            // A confirmed channel that degenerates into random durations
            // (noise after the signal ended, or a confirmation that
            // squeaked through) is revoked within a few characters. A
            // genuine speed change spikes this too, but the speed tracker
            // re-fits within ~5 elements — faster than the EMA can cross
            // the revoke bar.
            let r = duration / max(ditBlocks, 0.5)
            let error = min(abs(r - 1.0), abs(r - 3.0) / 3.0)
            rhythmEMA = rhythmEMA * 0.85 + error * 0.15
            if probationDebug {
                print("  WATCHDOG: r=\(String(format: "%.2f", r)) err=\(String(format: "%.2f", error)) ema=\(String(format: "%.3f", rhythmEMA))")
            }
            if rhythmEMA > probationRevokeEMA {
                if probationDebug { print("  WATCHDOG: REVOKED") }
                resetProbation()
            }
        }

        if debugEnabled {
            print("  ELEMENT: \(element) dur=\(String(format:"%.2f", duration)) ditBlocks=\(String(format:"%.1f", ditBlocks)) 2dit=\(String(format:"%.1f", twoDits))")
        }

        updateSpeedTracking(duration: duration, element: element)
        lastKeyDownBlocks = duration
        lastElementWasDit = (element == .dit)
    }

    // MARK: - Speed Tracking

    private func updateSpeedTracking(duration: Double, element: MorseElement) {
        guard lastKeyDownBlocks > 0 else { return }

        let current = duration
        let last = lastKeyDownBlocks

        var newDitEstimate: Double?

        // Dit-dah pair: dah ≈ 3× dit (primary, most reliable)
        if lastElementWasDit && element == .dah {
            let ratio = current / last
            if ratio > 1.5 && ratio < 6.0 {
                newDitEstimate = (last + current) / 4.0
            }
        }
        // Dah-dit pair
        else if !lastElementWasDit && element == .dit {
            let ratio = last / current
            if ratio > 1.5 && ratio < 6.0 {
                newDitEstimate = (current + last) / 4.0
            }
        }
        // Same-type consecutive elements (secondary, for speed changes)
        else if lastElementWasDit && element == .dit {
            newDitEstimate = (last + current) / 2.0
        } else if !lastElementWasDit && element == .dah {
            newDitEstimate = (last + current) / 6.0
        }

        guard let estimate = newDitEstimate else { return }

        // Sanity check
        let blockDuration = Double(blockSize) / configuration.sampleRate
        let wpm = 1.2 / (estimate * blockDuration)
        guard wpm >= minWPM && wpm <= maxWPM else { return }

        // Detect large speed jumps (>30% change) and reset the tracker
        // for faster adaptation to sudden speed changes
        let ratio = estimate / ditBlocks
        if ratio > 1.5 || ratio < 0.67 {
            speedTracker.removeAll()
        }

        speedTracker.append(estimate)
        if speedTracker.count > speedTrackerSize {
            speedTracker.removeFirst()
        }
        let newDitBlocks = speedTracker.reduce(0, +) / Double(speedTracker.count)

        ditBlocks = newDitBlocks
    }

    // MARK: - Character Output

    private func flushCharacter() {
        guard !currentElements.isEmpty else { return }
        // Emission gate: only emit while the tracked signal clears the
        // same 5× bar signal detection uses. Post-bootstrap noise chatter
        // reaches a 2–4× equilibrium and would otherwise trickle out as
        // E/T strings on an idle frequency for as long as the app listens.
        guard signalLevel > noiseLevel * 5 else {
            currentElements.removeAll()
            return
        }
        let elemStr = currentElements.map { $0 == .dit ? "." : "-" }.joined()
        let char = MorseCodec.decode(currentElements)
        if debugEnabled {
            print("  FLUSH: \(elemStr) → \(char.map { String($0) } ?? "nil")")
        }
        if let char = char {
            if let expansion = MorseCodec.prosignText(for: char) {
                // Prosign sentinel (SK, CT, …) — emit its readable form.
                for c in expansion {
                    emitOrHold(c)
                }
            } else {
                emitOrHold(char)
            }
        }
        currentElements.removeAll()
    }

    /// Emission with post-bootstrap probation: once confirmed, characters
    /// flow straight to the delegate; before that they queue while the
    /// element rhythm is judged. The queue is released in order on
    /// confirmation and silently dropped at un-bootstrap, so an idle
    /// noisy channel produces nothing while a real signal loses nothing
    /// but a moment of latency on its opening characters.
    private func emitOrHold(_ char: Character) {
        if emissionConfirmed {
            delegate?.demodulator(self, didDecode: char, atFrequency: currentToneFrequency)
            return
        }
        probationChars.append(char)
        if probationChars.count > probationWindow {
            probationChars.removeFirst(probationChars.count - probationWindow)
        }
        guard probationPasses() else {
            provisionalSince = nil
            return
        }
        guard let since = provisionalSince else {
            provisionalSince = probationElementCount
            return
        }
        guard probationElementCount - since >= probationSustain else { return }
        emissionConfirmed = true
        provisionalSince = nil
        rhythmEMA = 0.1
        // Leading space is meaningless on a fresh channel.
        while probationChars.first == " " { probationChars.removeFirst() }
        for held in probationChars {
            delegate?.demodulator(self, didDecode: held, atFrequency: currentToneFrequency)
        }
        probationChars.removeAll()
    }

    /// Does the recent element/gap timing look like keying rather than
    /// noise? Real CW — even a rough fist — has two tight duration
    /// clusters ~3× apart and gaps on the 1/3/7-dit grid. Acoustic
    /// noise "elements" are a continuum: a threshold split of one can
    /// produce plausible means, but not tight clusters.
    private func probationPasses(relaxed: Bool = false) -> Bool {
        let dit = max(ditBlocks, 0.5)
        // Near the block floor, quantization masquerades as rhythm: every
        // short burst clips to ~2 blocks, so a continuum of noise reads
        // as tight 40+ WPM dits. Timing evidence is worthless there —
        // demand a full window AND the strong signal that copying real
        // CW that fast requires anyway.
        if dit < 2.75 {
            guard signalLevel > noiseLevel * 12 else { return false }
        }
        // Relaxed: the channel is closing (un-bootstrap / end of stream)
        // and this is the held copy's last chance — a short transmission
        // like a lone "CQ" never accumulates the full evidence window.
        let needed = relaxed ? 4 : (dit < 2.75 ? probationWindow : probationMinElements)
        let window = Array(probationDurations.suffix(probationWindow))
        guard window.count >= needed else { return false }

        var dits: [Double] = []
        var dahs: [Double] = []
        for duration in window {
            if duration / dit < 1.8 { dits.append(duration) } else { dahs.append(duration) }
        }
        let gaps = probationGaps.suffix(probationWindow).map { $0 / dit }.filter { $0 <= 9.0 }
        var gapError = 0.0
        if gaps.count >= 3 {
            gapError = gaps.map { min(abs($0 - 1.0), abs($0 - 3.0) / 3.0, abs($0 - 7.0) / 7.0) }
                .reduce(0, +) / Double(gaps.count)
        }
        func cv(_ values: [Double]) -> Double {
            let mean = values.reduce(0, +) / Double(values.count)
            guard mean > 0 else { return .infinity }
            let variance = values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)
            return variance.squareRoot() / mean
        }
        let ratio = dits.isEmpty || dahs.isEmpty ? 0
            : (dahs.reduce(0, +) / Double(dahs.count)) / (dits.reduce(0, +) / Double(dits.count))

        if probationDebug {
            let durs = window.map { String(format: "%.1f", $0) }.joined(separator: ",")
            print("  PROBATION: dit=\(String(format: "%.2f", dit)) nDit=\(dits.count) nDah=\(dahs.count) ratio=\(String(format: "%.2f", ratio)) cvDit=\(dits.count >= 2 ? String(format: "%.2f", cv(dits)) : "-") cvDah=\(dahs.count >= 2 ? String(format: "%.2f", cv(dahs)) : "-") gapErr=\(String(format: "%.2f", gapError)) durs=[\(durs)]")
        }

        guard dits.count >= 2, dahs.count >= 2 else { return false }
        guard ratio >= 2.0, ratio <= 4.6 else { return false }
        guard cv(dits) <= probationMaxClassCV, cv(dahs) <= probationMaxClassCV else { return false }
        guard gaps.count < 3 || gapError <= probationMaxGapError else { return false }
        return true
    }

    /// Release held probation copy if it withstands the structural check
    /// with relaxed evidence requirements. Called when the channel is
    /// closing — long dead air (un-bootstrap) or end of stream — so a
    /// short clean transmission ("CQ", a lone callsign) isn't swallowed
    /// just because it ended before the sustain window filled.
    public func flushPending() {
        guard !emissionConfirmed, !probationChars.isEmpty, probationPasses(relaxed: true) else { return }
        while probationChars.first == " " { probationChars.removeFirst() }
        while probationChars.last == " " { probationChars.removeLast() }
        for held in probationChars {
            delegate?.demodulator(self, didDecode: held, atFrequency: currentToneFrequency)
        }
        probationChars.removeAll()
    }

    private func recordProbationGap(_ blocks: Double) {
        guard !emissionConfirmed else { return }
        probationGaps.append(blocks)
        if probationGaps.count > probationWindow {
            probationGaps.removeFirst(probationGaps.count - probationWindow)
        }
    }

    private func resetProbation() {
        emissionConfirmed = false
        probationChars.removeAll()
        probationDurations.removeAll()
        probationGaps.removeAll()
        rhythmEMA = 0.0
        provisionalSince = nil
        probationElementCount = 0
    }

    // MARK: - AFC

    private func updateAFC() {
        guard _signalDetected else { return }

        // Once locked, never abandon a healthy signal. The AFC bins integrate
        // unfiltered audio over the whole window (including key-up gaps), so in
        // noise a neighboring bin can beat the center by chance, and a strong
        // off-frequency interferer (QRM) beats it consistently — neither is a
        // reason to retune while the tone we're copying is still strong at the
        // current frequency. Retuning here rebuilt filters mid-element and
        // corrupted decode (dropped dahs) at every SNR.
        let signalHealthy = signalLevel > noiseLevel * 25
        if afcInitialScanDone && signalHealthy { return }

        var maxPower = afcCenterAccum
        var bestOffset: Double = 0

        for i in 0..<afcAccumulators.count {
            if afcAccumulators[i] > maxPower {
                maxPower = afcAccumulators[i]
                bestOffset = afcOffsets[i]
            }
        }

        // Acquisition can be eager (1.2×); once locked, demand a decisive
        // winner so window-to-window noise variance can't trigger a retune.
        let margin = afcInitialScanDone ? 2.0 : 1.2

        if bestOffset != 0 && maxPower > afcCenterAccum * margin {
            let aggressiveness = abs(bestOffset) > 75 ? 0.8 : 0.5
            let shift = bestOffset * aggressiveness
            currentToneFrequency += shift
            clampToneFrequency()
            rebuildFilters()

            if !afcInitialScanDone {
                // Initial scan: elements accumulated at the wrong frequency
                // are garbage — discard them.
                if !currentElements.isEmpty {
                    currentElements.removeAll()
                    characterFlushed = false
                }
            } else if abs(shift) > 30 {
                // Locked retune (signal genuinely moved or faded): pending
                // elements were decoded at the old frequency and are valid
                // Morse — emit them rather than silently dropping the
                // character in progress.
                flushCharacter()
                characterFlushed = true
            }
        }
    }

    private func rebuildFilters() {
        toneFilter = GoertzelFilter(
            frequency: currentToneFrequency,
            sampleRate: configuration.sampleRate,
            blockSize: blockSize
        )
        fftBandpassFilter = OverlapAddFilter.bandpass(
            lowCutoff: currentToneFrequency - 100,
            highCutoff: currentToneFrequency + 100,
            sampleRate: configuration.sampleRate,
            taps: 513
        )
        for i in 0..<afcFilters.count {
            afcFilters[i] = GoertzelFilter(
                frequency: currentToneFrequency + afcOffsets[i],
                sampleRate: configuration.sampleRate,
                blockSize: blockSize
            )
        }
        afcCenterFilter = GoertzelFilter(
            frequency: currentToneFrequency,
            sampleRate: configuration.sampleRate,
            blockSize: blockSize
        )
        firCenterFrequency = currentToneFrequency
    }

    // MARK: - Control

    /// Clear transient decode state while preserving calibration — noise
    /// floor, signal level, tracked speed, and AFC lock. For resuming
    /// after our own transmission (half-duplex un-mute) or a brief
    /// interruption: the channel hasn't changed, but any partially
    /// tracked element has. A full reset() here would force a 200 ms
    /// noise re-estimate exactly when the counterparty starts replying.
    public func resynchronize() {
        sampleBuffer.removeAll()
        rawSampleBuffer.removeAll()
        fftBandpassFilter.reset()
        state = .idle
        stateDurationBlocks = 0
        currentElements.removeAll()
        characterFlushed = false
        wordSpaceEmitted = false
        lastToneDuration = 0
        toneGateOpen = false
        afcBlockCount = 0
        afcCenterAccum = 0
        for i in 0..<afcAccumulators.count { afcAccumulators[i] = 0 }
        minStatsSubMin = .greatestFiniteMagnitude
        minStatsRing.removeAll()
        minStatsBlockCount = 0
        minStatsSmoothed = 0
        lastTonePhase = nil
        fineFreqError = 0
        blocksSinceToneEnd = -1
        bootstrapRun = 0
        toneStartFraction = 0.5
        toneEndFraction = 0.5
        // Confirmation survives (the channel and sender haven't changed);
        // any unconfirmed queue is stale noise from before the mute.
        probationChars.removeAll()
        probationDurations.removeAll()
        probationGaps.removeAll()
    }

    public func reset() {
        sampleBuffer.removeAll()
        rawSampleBuffer.removeAll()
        blankerLevel = 0
        signalLevel = 0
        recentSignal = 0
        noiseLevel = 1e-10
        signalBootstrapped = false
        blockCount = 0
        noiseEstimateAccum = 0
        afcInitialScanDone = false
        toneGateOpen = false
        minStatsSubMin = .greatestFiniteMagnitude
        minStatsRing.removeAll()
        minStatsBlockCount = 0
        minStatsSmoothed = 0
        intraGapDits = 1.0
        charGapDits = 3.0
        recentCharGaps.removeAll()
        lastTonePhase = nil
        fineFreqError = 0
        blocksSinceToneEnd = -1
        bootstrapRun = 0
        toneStartFraction = 0.5
        toneEndFraction = 0.5
        state = .idle
        stateDurationBlocks = 0
        currentElements.removeAll()
        characterFlushed = false
        wordSpaceEmitted = false
        lastToneDuration = 0
        lastKeyDownBlocks = 0
        lastElementWasDit = true
        speedTracker.removeAll()
        resetProbation()
        _signalDetected = false
        toneBlocksSeen = 0
        fftBandpassFilter.reset()
        afcBlockCount = 0
        afcCenterAccum = 0
        for i in 0..<afcAccumulators.count { afcAccumulators[i] = 0 }

        let ditSeconds = MorseCodec.ditDuration(forWPM: configuration.wpm)
        let blockDuration = Double(blockSize) / configuration.sampleRate
        ditBlocks = ditSeconds / blockDuration
        initialDitBlocks = ditSeconds / blockDuration

        currentToneFrequency = configuration.toneFrequency
        rebuildFilters()
    }

    public func tune(to frequency: Double) {
        configuration = configuration.withToneFrequency(frequency)
        currentToneFrequency = frequency
        rebuildFilters()
    }
}
