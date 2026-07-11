//
//  BayesianCWDecoder.swift
//  AmateurDigitalCore
//
//  Bayesian CW decoder: probabilistic tone detection, Gaussian element
//  classification, and beam search character hypothesis tracking.
//
//  Algorithm overview:
//  1. Goertzel tone detection with probabilistic signal/noise model
//  2. Tone probability computed via Bayesian update (signal vs noise variance)
//  3. Element durations classified as dit/dah using Gaussian likelihood
//     with adaptive sigma (timing jitter tolerance)
//  4. Beam search over character hypotheses — maintains top-K partial
//     Morse sequences ranked by cumulative log-likelihood
//  5. AFC via multi-bin Goertzel scanning (same as classic decoder)
//
//  All tunable parameters are exposed as public var for optimization.
//

import Foundation

/// Bayesian CW Decoder with probabilistic tone detection and beam search.
///
/// Uses callback closures (`onCharacterDecoded`, `onSignalDetected`) instead of the
/// delegate protocol, making it easy to use from benchmarks and optimization harnesses.
public final class BayesianCWDecoder {

    // MARK: - Tunable Parameters (public var for Optuna optimization)

    /// Minimum SNR (linear ratio) required to declare tone present.
    /// Higher = fewer false detections but may miss weak signals.
    /// Range: 1.5 - 10.0. Default: 3.947 (Optuna trial 17)
    public var toneDetectionSNR: Double = 3.947

    /// Number of preamble blocks for initial noise estimation. 20 (200 ms)
    /// matches CWDemodulator; a 14-block estimate ran hot-or-cold enough
    /// that noise occasionally bootstrapped the signal tracker.
    /// Range: 5 - 40. Default: 20
    public var preambleBlocks: Int = 20

    // -- Element classification (Gaussian model) --

    /// Sigma for element duration classification, as a fraction of the dit duration.
    /// Controls timing jitter tolerance. Smaller = stricter timing requirements.
    /// Range: 0.15 - 0.60. Default: 0.279 (Optuna trial 17)
    public var elementSigmaFraction: Double = 0.279

    /// Dit/dah boundary as a multiple of estimated dit duration.
    /// Elements shorter than this are classified as dit, longer as dah.
    /// 2.0 is the midpoint of the 1:3 dit:dah ratio and matches the Gaussian
    /// crossover used by the beam scorer; the lower thresholdFractionClean
    /// stretches measured elements slightly, which a tighter boundary
    /// misclassified (speed/jitter regression at 1.787).
    /// Range: 1.5 - 2.5. Default: 2.0
    public var ditDahBoundary: Double = 2.0

    /// Minimum element duration as fraction of dit blocks (noise rejection).
    /// Elements shorter than this are discarded as noise spikes.
    /// Range: 0.15 - 0.5. Default: 0.323 (Optuna trial 17)
    public var minElementFraction: Double = 0.323

    // -- Gap classification --
    // Gap boundaries are learned from the sender's own gap clusters
    // (see interCharThresholdDits / wordThresholdDits), replacing the
    // fixed interCharGapMultiple / wordGapMultiple of earlier versions:
    // fixed multiples split Farnsworth senders and merged compressed fists.

    // -- Beam search character hypotheses --

    /// Maximum number of active hypotheses (beam width).
    /// Higher = more thorough search but slower.
    /// Range: 4 - 32. Default: 18 (Optuna trial 17)
    public var beamWidth: Int = 18

    /// Pruning threshold: hypotheses with probability below
    /// bestProb * pruneThreshold are discarded.
    /// Range: 0.001 - 0.1. Default: 0.00191 (Optuna trial 17)
    public var pruneThreshold: Double = 0.00191

    // -- Speed tracking --

    /// Size of the speed tracker window (number of element pairs).
    /// Range: 4 - 32. Default: 27 (Optuna trial 17)
    public var speedTrackerSize: Int = 27

    /// Speed jump detection ratio. If new estimate differs from current
    /// by more than this factor, reset the tracker for fast adaptation.
    /// Range: 1.2 - 2.0. Default: 1.518 (Optuna trial 17)
    public var speedJumpRatio: Double = 1.518

    // -- AFC --

    /// AFC update interval in blocks.
    /// Range: 10 - 60. Default: 53 (Optuna trial 17)
    public var afcUpdateInterval: Int = 53

    /// AFC aggressiveness for large offsets (>75 Hz).
    /// Range: 0.3 - 1.0. Default: 0.738 (Optuna trial 17)
    public var afcLargeOffsetGain: Double = 0.738

    /// AFC aggressiveness for small offsets (<=75 Hz).
    /// Range: 0.2 - 0.8. Default: 0.617 (Optuna trial 17)
    public var afcSmallOffsetGain: Double = 0.617

    /// AFC minimum power ratio to trigger correction once locked.
    /// Best AFC bin must exceed center bin decisively — window-to-window
    /// noise variance must not trigger a retune. Acquisition uses an eager
    /// fixed 1.2 margin instead (ported from CWDemodulator).
    /// Range: 1.5 - 3.0. Default: 2.0
    public var afcMinPowerRatio: Double = 2.0

    // -- Debounce --

    /// Debounce threshold as fraction of dit blocks.
    /// Gaps shorter than this are merged with the preceding tone.
    /// Range: 0.2 - 0.6. Default: 0.407 (Optuna trial 17)
    public var debounceFraction: Double = 0.407

    // -- Threshold adaptation --

    /// Threshold fraction for very clean signals (high SNR).
    /// Low enough that elements *starting* inside an AGC-pumping trough
    /// (~0.18× tracked peak) still open the gate; not so low that
    /// partial-block edge capture stretches elements (a single 0.08
    /// threshold broke dit/dah boundaries at 30+ WPM — benchmark sweep
    /// 2026-07: {0.15, off 0.4, recentDecay 0.45} composite 96.2 vs 91.6).
    /// Range: 0.1 - 0.4. Default: 0.15
    public var thresholdFractionClean: Double = 0.15

    /// Hysteresis: tone-off threshold as a fraction of the tone-on
    /// threshold (above noise). The gate opens at the full threshold
    /// (crisp edges) and only closes when power falls well below it, so
    /// mid-element dips from AGC pumping or flutter don't chop elements.
    /// Range: 0.2 - 1.0. Default: 0.4
    public var hysteresisOffRatio: Double = 0.4

    /// Threshold fraction for moderate noise.
    /// Range: 0.15 - 0.5. Default: 0.363 (Optuna trial 17)
    public var thresholdFractionModerate: Double = 0.363

    /// Threshold fraction for heavy noise.
    /// Range: 0.25 - 0.6. Default: 0.550 (Optuna trial 17)
    public var thresholdFractionNoisy: Double = 0.550

    /// Signal tracking attack rate (rising signal).
    /// Range: 0.1 - 0.6. Default: 0.360 (Optuna trial 17)
    public var signalAttackRate: Double = 0.360

    /// Signal tracking decay rate (falling signal).
    /// Range: 0.05 - 0.3. Default: 0.201 (Optuna trial 17)
    public var signalDecayRate: Double = 0.201

    /// Recent signal fast decay rate during tone-on. Fast enough that the
    /// effective threshold follows a 3–5 Hz AGC-pumping envelope down.
    /// Range: 0.1 - 0.6. Default: 0.45
    public var recentSignalDecay: Double = 0.45

    /// Noise floor tracking rate during silence.
    /// Range: 0.01 - 0.15. Default: 0.124 (Optuna trial 17)
    public var noiseFloorTrackingRate: Double = 0.124

    // MARK: - Internal State

    private enum RxState {
        case idle
        case inTone
        case afterTone
    }

    private var configuration: CWConfiguration

    /// Callback when a character is decoded. Parameters: (character, frequency)
    public var onCharacterDecoded: ((Character, Double) -> Void)?

    /// Callback when signal detection state changes. Parameters: (detected, frequency)
    public var onSignalDetected: ((Bool, Double) -> Void)?

    // Tone detection
    private var toneFilter: GoertzelFilter
    private let blockSize: Int
    private var sampleBuffer: [Float] = []
    private var fftBandpassFilter: OverlapAddFilter

    // Bayesian signal/noise model
    private var signalPower: Double = 0
    private var noisePower: Double = 1e-10
    private var recentSignal: Double = 0
    private var signalBootstrapped: Bool = false
    private var blockCount: Int = 0
    private var noiseEstimateAccum: Double = 0
    private var toneGateOpen: Bool = false

    // Sub-block edge timing (see CWDemodulator for rationale)
    private var toneStartFraction: Double = 0.5
    private var toneEndFraction: Double = 0.5

    private func measureEdgeFraction(block: [Float], fullBlockThreshold: Double, rising: Bool) -> Double {
        guard signalBootstrapped, signalPower > noisePower * 10 else { return 0.5 }
        let sub = blockSize / 4
        guard sub >= 32 else { return 0.5 }
        let subThreshold = Float(fullBlockThreshold / 16.0)
        for i in 0..<4 {
            var filter = GoertzelFilter(
                frequency: currentToneFrequency,
                sampleRate: configuration.sampleRate,
                blockSize: sub
            )
            let power = filter.processBlock(Array(block[(i * sub)..<((i + 1) * sub)]))
            if rising, power > subThreshold {
                return Double(i) / 4.0
            }
            if !rising, power < subThreshold {
                return Double(i) / 4.0
            }
        }
        return 0.5
    }

    // Min-statistics noise tracking (see CWDemodulator for rationale:
    // rescues a tone-contaminated startup noise estimate within ~1 s).
    private var minStatsSubMin: Double = .greatestFiniteMagnitude
    private var minStatsRing: [Double] = []
    private var minStatsBlockCount: Int = 0
    private var minStatsSmoothed: Double = 0
    public var minStatsFactor: Double = 6.0

    // State machine
    private var state: RxState = .idle
    private var stateDurationBlocks: Int = 0
    private var lastToneDuration: Int = 0
    /// Silent blocks since the last tone ended (-1 = no tone yet);
    /// survives afterTone→idle so long gaps still reach the gap learner.
    private var blocksSinceToneEnd: Int = -1
    /// Consecutive above-threshold blocks before first bootstrap.
    private var bootstrapRun: Int = 0

    // Post-bootstrap emission probation (see CWDemodulator for the full
    // rationale): characters are held until element/gap timing proves
    // CW-like rhythm, sustained across two passing evaluations; a
    // confirmed channel that degenerates is revoked by the rhythm
    // watchdog; held copy is released by a relaxed last-chance check
    // when the channel closes, or dropped as noise.
    public var probationMinElements: Int = 8
    public var probationMaxClassCV: Double = 0.28
    public var probationMaxGapError: Double = 0.40
    public var probationRevokeEMA: Double = 0.25
    private var emissionConfirmed = false
    private var probationDurations: [Double] = []
    private var probationGaps: [Double] = []
    private var probationChars: [Character] = []
    private var rhythmEMA = 0.0
    private var provisionalSince: Int?
    private var probationElementCount = 0
    private let probationWindow = 16
    private let probationSustain = 4

    // Adaptive gap clustering (see CWDemodulator for rationale)
    private var intraGapDits: Double = 1.0
    private var charGapDits: Double = 3.0
    private var recentCharGaps: [Double] = []

    private var interCharThresholdDits: Double {
        min(max((intraGapDits * charGapDits).squareRoot() * 1.08, 1.35), 3.6)
    }

    private var wordThresholdDits: Double {
        guard recentCharGaps.count >= 2 else {
            return min(max(charGapDits * 1.8, 2.6), 40.0)
        }
        let sorted = recentCharGaps.sorted()
        return min(max(sorted[1] * 1.6, 2.6), 40.0)
    }

    private func updateGapClusters(gapDits: Double) {
        guard gapDits > 0.15, gapDits < 60 else { return }
        let dIntra = abs(log(gapDits / max(intraGapDits, 0.1)))
        let dChar = abs(log(gapDits / max(charGapDits, 0.1)))
        if dIntra < dChar {
            intraGapDits = min(max(intraGapDits * 0.8 + gapDits * 0.2, 0.5), 1.9)
        } else {
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

    // Speed tracking
    private var ditBlocks: Double
    private var initialDitBlocks: Double
    private var speedTracker: [Double] = []
    private var lastKeyDownBlocks: Double = 0
    private var lastElementWasDit: Bool = true

    // Morse decoder
    private var currentElements: [MorseElement] = []
    private var characterFlushed: Bool = false
    private var wordSpaceEmitted: Bool = false

    // Beam search
    private struct Hypothesis {
        var elements: [MorseElement]
        var logProb: Double
    }
    private var beamHypotheses: [Hypothesis] = []

    // Signal detection
    private var _signalDetected: Bool = false
    private var toneBlocksSeen: Int = 0

    // AFC
    private var afcFilters: [GoertzelFilter] = []
    private var afcCenterFilter: GoertzelFilter
    private var afcOffsets: [Double] = []
    private var afcBlockCount: Int = 0
    private var afcAccumulators: [Double] = []
    private var afcCenterAccum: Double = 0
    private var currentToneFrequency: Double
    private var afcInitialScanDone: Bool = false

    // Phase-slope fine AFC (see CWDemodulator for rationale)
    private var lastTonePhase: Double?
    private var fineFreqError: Double = 0
    private var firCenterFrequency: Double

    // Debug
    public var debugEnabled: Bool = false

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
        guard signalPower > 0 && noisePower > 0 else { return 0 }
        return Float(min(1.0, (signalPower / noisePower) / 20.0))
    }

    public var currentConfiguration: CWConfiguration { configuration }
    public var minWPM: Double = 4.0
    public var maxWPM: Double = 60.0

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

        self.fftBandpassFilter = OverlapAddFilter.bandpass(
            lowCutoff: configuration.toneFrequency - 100,
            highCutoff: configuration.toneFrequency + 100,
            sampleRate: configuration.sampleRate,
            taps: 513
        )

        // AFC filters: +/-250 Hz in 25 Hz steps
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

    private var rawSampleBuffer: [Float] = []

    // Noise blanker (see CWDemodulator for rationale)
    private var blankerLevel: Float = 0
    public var blankerThreshold: Float = 4.0

    private func blankImpulses(_ samples: [Float]) -> [Float] {
        var out = samples
        for i in 0..<out.count {
            let magnitude = abs(out[i])
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
        let filtered = fftBandpassFilter.process(samples)
        rawSampleBuffer.append(contentsOf: samples)
        sampleBuffer.append(contentsOf: filtered)

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
        var filter = toneFilter
        let complexOut = filter.processBlockComplex(block)
        toneFilter = filter
        let goertzelPower = Double(complexOut.real) * Double(complexOut.real)
            + Double(complexOut.imag) * Double(complexOut.imag)

        let rawPower = goertzelPower

        // AFC bins gated to acquisition windows (see CWDemodulator).
        let afcAcquiring = signalBootstrapped
            && (!afcInitialScanDone
                || (_signalDetected && signalPower <= noisePower * 25))
        if afcAcquiring {
            for i in 0..<afcFilters.count {
                var f = afcFilters[i]
                let p = Double(f.processBlock(rawBlock))
                afcFilters[i] = f
                afcAccumulators[i] += p
            }
            var centerFilter = afcCenterFilter
            afcCenterAccum += Double(centerFilter.processBlock(rawBlock))
            afcCenterFilter = centerFilter
        }
        afcBlockCount += 1

        let wasBootstrapped = signalBootstrapped

        let shouldRunAFC = afcBlockCount >= afcUpdateInterval ||
            (wasBootstrapped && !afcInitialScanDone && afcBlockCount >= 3)

        if shouldRunAFC {
            // Run the scan BEFORE marking it done: updateAFC() must see
            // `afcInitialScanDone == false` during the initial acquisition
            // pass so it uses the eager margin and skips the locked-signal
            // health veto (ported from CWDemodulator).
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

        // Phase 1: Noise floor estimation from preamble
        if blockCount <= preambleBlocks {
            noiseEstimateAccum += rawPower
            if blockCount == preambleBlocks {
                noisePower = max(noiseEstimateAccum / Double(preambleBlocks), 1e-10)
            }
            return
        }

        // Update recent signal estimate (fast-tracking for fading)
        if rawPower > noisePower * 5 {
            if rawPower > recentSignal {
                recentSignal = rawPower  // Instant attack
            } else {
                recentSignal = recentSignal * (1.0 - recentSignalDecay) + rawPower * recentSignalDecay
            }
        } else {
            recentSignal = recentSignal * 0.98 + rawPower * 0.02
        }

        // Determine tone presence using adaptive threshold with hysteresis
        let thresholdOn: Double
        let thresholdOff: Double
        if signalBootstrapped {
            let effectiveSignal = sqrt(signalPower * max(recentSignal, noisePower * 2))
            let snr = effectiveSignal / max(noisePower, 1e-10)
            let thresholdFraction: Double
            if snr > 100 {
                thresholdFraction = thresholdFractionClean
            } else if snr > 10 {
                thresholdFraction = thresholdFractionModerate
            } else {
                thresholdFraction = thresholdFractionNoisy
            }
            let range = effectiveSignal - noisePower
            thresholdOn = noisePower + thresholdFraction * range
            // OFF floor at 3× noise: in low-SNR chatter the hysteresis
            // gap must not sit inside the noise distribution, or the gate
            // never closes and band noise decodes as endless E/T strings.
            thresholdOff = max(noisePower + thresholdFraction * hysteresisOffRatio * range,
                               noisePower * 3.0)
        } else {
            thresholdOn = noisePower * 8.0
            thresholdOff = noisePower * max(8.0 * hysteresisOffRatio, 3.0)
        }

        let gateWasOpen = toneGateOpen
        if toneGateOpen {
            toneGateOpen = rawPower > thresholdOff
        } else {
            toneGateOpen = rawPower > thresholdOn
        }
        let toneOn = toneGateOpen
        let toneOff = !toneGateOpen

        if toneOn && !gateWasOpen {
            toneStartFraction = measureEdgeFraction(block: block, fullBlockThreshold: thresholdOn, rising: true)
        } else if toneOff && gateWasOpen {
            toneEndFraction = measureEdgeFraction(block: block, fullBlockThreshold: thresholdOff, rising: false)
        }

        // Update signal/noise tracking
        if toneOn {
            if !signalBootstrapped {
                // Two consecutive qualifying blocks required — a lone noise
                // spike must not bootstrap the tracker (see CWDemodulator).
                bootstrapRun += 1
                if bootstrapRun >= 2 {
                    signalPower = rawPower
                    signalBootstrapped = true
                    afcBlockCount = 0
                    afcCenterAccum = 0
                    for i in 0..<afcAccumulators.count { afcAccumulators[i] = 0 }
                }
            } else {
                if rawPower > signalPower {
                    signalPower = signalPower * (1.0 - signalAttackRate) + rawPower * signalAttackRate
                } else {
                    signalPower = signalPower * (1.0 - signalDecayRate) + rawPower * signalDecayRate
                }
            }
        } else if toneOff {
            bootstrapRun = 0
            if state == .idle || (state == .afterTone && stateDurationBlocks > Int(ditBlocks * 1.5)) {
                noisePower = noisePower * (1.0 - noiseFloorTrackingRate) + rawPower * noiseFloorTrackingRate
                noisePower = max(noisePower, 1e-10)
            }
        }

        processStateMachine(toneOn: toneOn, toneOff: toneOff)
        updateFineAFC(real: complexOut.real, imag: complexOut.imag)
        updateSignalDetection()
    }

    // MARK: - Fine AFC

    private func updateFineAFC(real: Float, imag: Float) {
        guard state == .inTone, stateDurationBlocks >= 2, signalBootstrapped,
              signalPower > noisePower * 25 else {
            lastTonePhase = nil
            return
        }
        let blockPower = Double(real) * Double(real) + Double(imag) * Double(imag)
        guard blockPower < signalPower * 4 else {
            lastTonePhase = nil
            return
        }
        let phase = Double(atan2(imag, real))
        guard let last = lastTonePhase else {
            lastTonePhase = phase
            return
        }
        let blockDuration = Double(blockSize) / configuration.sampleRate
        let expected = 2.0 * .pi * currentToneFrequency * blockDuration
        var dphi = (phase - last - expected).truncatingRemainder(dividingBy: 2.0 * .pi)
        if dphi > .pi { dphi -= 2.0 * .pi }
        if dphi < -.pi { dphi += 2.0 * .pi }
        let hzError = dphi / (2.0 * .pi * blockDuration)

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
        if noisePower > cap {
            noisePower = cap
        }
    }

    // MARK: - Gaussian Likelihood

    private func gaussianLogLikelihood(x: Double, mean: Double, variance: Double) -> Double {
        let diff = x - mean
        return -0.5 * log(2.0 * .pi * variance) - (diff * diff) / (2.0 * variance)
    }

    // MARK: - Signal Detection

    private func updateSignalDetection() {
        let hasSignal = signalBootstrapped && signalPower > noisePower * toneDetectionSNR
        if hasSignal {
            toneBlocksSeen = min(toneBlocksSeen + 1, 10)
        } else {
            toneBlocksSeen = max(toneBlocksSeen - 1, 0)
        }

        let newDetected = toneBlocksSeen >= 3
        if newDetected != _signalDetected {
            _signalDetected = newDetected
            onSignalDetected?(newDetected, currentToneFrequency)
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
                if blocksSinceToneEnd > 0 {
                    updateGapClusters(gapDits: Double(blocksSinceToneEnd) / max(ditBlocks, 0.5))
                    recordProbationGap(Double(blocksSinceToneEnd))
                }
                if wordSpaceEmitted {
                    if signalPower > noisePower * 5 {
                        emitOrHold(" ")
                    }
                    wordSpaceEmitted = false
                }
                state = .inTone
                stateDurationBlocks = 1
                characterFlushed = false
            } else {
                let idleTimeout = Int(ditBlocks * 30)
                if stateDurationBlocks > idleTimeout {
                    if _signalDetected {
                        _signalDetected = false
                        toneBlocksSeen = 0
                        onSignalDetected?(false, currentToneFrequency)
                    }
                    if signalBootstrapped {
                        flushPending()
                        signalBootstrapped = false
                        signalPower = 0
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

                let minBlocks = max(2, Int(ditBlocks * minElementFraction))
                if keyDownBlocks >= minBlocks {
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
                let gapDuration = Double(gapBlocks)
                    + (toneStartFraction - 0.5)
                    + (0.5 - toneEndFraction)
                let debounceThreshold = max(2, Int(ditBlocks * debounceFraction))
                if gapBlocks < debounceThreshold {
                    if !currentElements.isEmpty {
                        currentElements.removeLast()
                    }
                    state = .inTone
                    stateDurationBlocks = lastToneDuration + gapBlocks + 1
                    break
                }

                let gapDit = ditBlocks
                let interCharThreshold = gapDit * interCharThresholdDits
                let wordThreshold = gapDit * wordThresholdDits

                if gapDuration >= interCharThreshold && !currentElements.isEmpty && !characterFlushed {
                    flushCharacter()
                    characterFlushed = true
                }

                if gapDuration >= wordThreshold && !wordSpaceEmitted {
                    wordSpaceEmitted = true
                }

                if wordSpaceEmitted {
                    if signalPower > noisePower * 5 {
                        emitOrHold(" ")
                    }
                    wordSpaceEmitted = false
                }

                updateGapClusters(gapDits: gapDuration / max(gapDit, 0.5))
                recordProbationGap(gapDuration)

                state = .inTone
                stateDurationBlocks = 1
            } else {
                let gapBlocks = stateDurationBlocks
                let gapDit = ditBlocks
                let interCharThreshold = gapDit * interCharThresholdDits
                let wordThreshold = gapDit * wordThresholdDits

                if Double(gapBlocks) >= interCharThreshold && !currentElements.isEmpty && !characterFlushed {
                    flushCharacter()
                    characterFlushed = true
                }

                if Double(gapBlocks) >= wordThreshold && !wordSpaceEmitted {
                    if !currentElements.isEmpty && !characterFlushed {
                        flushCharacter()
                        characterFlushed = true
                    }
                    wordSpaceEmitted = true
                    state = .idle
                    stateDurationBlocks = 0
                }

                if Double(gapBlocks) >= ditBlocks * max(15.0, wordThresholdDits + 3.0) {
                    state = .idle
                    stateDurationBlocks = 0
                }
            }
        }
    }

    // MARK: - Element Classification (Gaussian Model)

    private func classifyElement(duration: Double) {
        let sigma = ditBlocks * elementSigmaFraction
        let boundary = ditBlocks * ditDahBoundary

        // Gaussian likelihood for dit vs dah
        let ditMean = ditBlocks
        let dahMean = ditBlocks * 3.0

        let ditLL = gaussianLogLikelihood(x: duration, mean: ditMean, variance: sigma * sigma)
        let dahLL = gaussianLogLikelihood(x: duration, mean: dahMean, variance: sigma * sigma)

        // Simple boundary + Gaussian weighting
        let element: MorseElement
        if duration <= boundary {
            element = .dit
        } else {
            element = .dah
        }

        currentElements.append(element)
        characterFlushed = false

        if !emissionConfirmed {
            probationElementCount += 1
            probationDurations.append(duration)
            if probationDurations.count > probationWindow {
                probationDurations.removeFirst(probationDurations.count - probationWindow)
            }
        } else {
            // Rhythm watchdog — see CWDemodulator.classifyElement.
            let r = duration / max(ditBlocks, 0.5)
            let error = min(abs(r - 1.0), abs(r - 3.0) / 3.0)
            rhythmEMA = rhythmEMA * 0.85 + error * 0.15
            if rhythmEMA > probationRevokeEMA {
                resetProbation()
            }
        }

        updateSpeedTracking(duration: duration, element: element)
        lastKeyDownBlocks = duration
        lastElementWasDit = (element == .dit)

        // Beam search: maintain alternative hypotheses
        updateBeam(element: element, ditLL: ditLL, dahLL: dahLL)
    }

    // MARK: - Beam Search

    /// Expand every live hypothesis with both readings of the new element,
    /// pruning readings that are not a prefix of any valid Morse character.
    /// The tree constraint is what makes the beam more than a second
    /// threshold: hypotheses genuinely diverge, and an ambiguous element
    /// can be settled by which continuation forms a real character.
    private func updateBeam(element: MorseElement, ditLL: Double, dahLL: Double) {
        let seeds = beamHypotheses.isEmpty
            ? [Hypothesis(elements: [], logProb: 0)]
            : beamHypotheses

        var expanded: [Hypothesis] = []
        expanded.reserveCapacity(seeds.count * 2)
        for hyp in seeds {
            for (candidate, ll) in [(MorseElement.dit, ditLL), (MorseElement.dah, dahLL)] {
                let elements = hyp.elements + [candidate]
                guard MorseCodec.isValidPrefix(elements) else { continue }
                expanded.append(Hypothesis(elements: elements, logProb: hyp.logProb + ll))
            }
        }

        guard !expanded.isEmpty else {
            // No valid continuation — drop the beam; flush falls back to
            // the greedy reading (which will decode to nil and be skipped,
            // same as the classic decoder's behavior on invalid patterns).
            beamHypotheses.removeAll()
            return
        }

        expanded.sort { $0.logProb > $1.logProb }
        let bestLogProb = expanded[0].logProb
        let cutoff = bestLogProb + log(pruneThreshold)
        beamHypotheses = Array(expanded.filter { $0.logProb >= cutoff }.prefix(beamWidth))
    }

    // MARK: - Ham Character Prior

    /// Log prior over decoded characters, weighted for amateur-radio
    /// traffic (calls, RST reports, Q-codes, 73/599) rather than plain
    /// English. Comparable in magnitude to one element's timing ambiguity,
    /// so it settles near-ties without overriding clear copy.
    static func characterLogPrior(_ character: Character) -> Double {
        charPriors[character] ?? defaultLogPrior
    }

    private static let defaultLogPrior = log(0.0005)

    private static let charPriors: [Character: Double] = {
        var freq: [Character: Double] = [
            "E": 0.10, "T": 0.075, "A": 0.07, "N": 0.06, "O": 0.055, "I": 0.055,
            "S": 0.05, "R": 0.05, "H": 0.04, "D": 0.035, "L": 0.03, "U": 0.028,
            "C": 0.025, "M": 0.024, "W": 0.024, "Q": 0.02, "K": 0.02, "G": 0.018,
            "F": 0.016, "Y": 0.014, "P": 0.014, "B": 0.012, "V": 0.01, "X": 0.004,
            "J": 0.004, "Z": 0.003,
            "5": 0.02, "9": 0.02, "0": 0.012, "7": 0.012, "1": 0.01, "2": 0.008,
            "3": 0.008, "4": 0.006, "6": 0.006, "8": 0.006,
            "/": 0.005, "?": 0.004, "=": 0.004, "+": 0.002, ".": 0.002, ",": 0.001,
        ]
        freq[MorseCodec.prosignSK] = 0.002
        freq[MorseCodec.prosignCT] = 0.001
        return freq.mapValues { log($0) }
    }()

    // MARK: - Speed Tracking

    private func updateSpeedTracking(duration: Double, element: MorseElement) {
        guard lastKeyDownBlocks > 0 else { return }

        let current = duration
        let last = lastKeyDownBlocks

        var newDitEstimate: Double?

        if lastElementWasDit && element == .dah {
            let ratio = current / last
            if ratio > 1.5 && ratio < 6.0 {
                newDitEstimate = (last + current) / 4.0
            }
        } else if !lastElementWasDit && element == .dit {
            let ratio = last / current
            if ratio > 1.5 && ratio < 6.0 {
                newDitEstimate = (current + last) / 4.0
            }
        } else if lastElementWasDit && element == .dit {
            newDitEstimate = (last + current) / 2.0
        } else if !lastElementWasDit && element == .dah {
            newDitEstimate = (last + current) / 6.0
        }

        guard let estimate = newDitEstimate else { return }

        let blockDuration = Double(blockSize) / configuration.sampleRate
        let wpm = 1.2 / (estimate * blockDuration)
        guard wpm >= minWPM && wpm <= maxWPM else { return }

        let ratio = estimate / ditBlocks
        if ratio > speedJumpRatio || ratio < (1.0 / speedJumpRatio) {
            speedTracker.removeAll()
        }

        speedTracker.append(estimate)
        if speedTracker.count > speedTrackerSize {
            speedTracker.removeFirst()
        }
        ditBlocks = speedTracker.reduce(0, +) / Double(speedTracker.count)
    }

    // MARK: - Character Output

    private func flushCharacter() {
        guard !currentElements.isEmpty else { return }
        // Emission gate — see CWDemodulator.flushCharacter. Bar sits
        // higher than classic's: this decoder's spike-following attack
        // rate lets noise chatter reach a ~6x equilibrium.
        guard signalPower > noisePower * 6.5 else {
            currentElements.removeAll()
            beamHypotheses.removeAll()
            return
        }

        // Rank complete-character hypotheses by acoustic log-likelihood
        // plus the ham-text prior; fall back to the greedy reading when
        // the beam died (invalid pattern) or was cleared mid-character.
        var best: (character: Character, score: Double)?
        for hyp in beamHypotheses where hyp.elements.count == currentElements.count {
            guard let character = MorseCodec.decode(hyp.elements) else { continue }
            let score = hyp.logProb + Self.characterLogPrior(character)
            if best == nil || score > best!.score {
                best = (character, score)
            }
        }

        if let character = best?.character ?? MorseCodec.decode(currentElements) {
            emit(character)
        }

        currentElements.removeAll()
        beamHypotheses.removeAll()
    }

    private func emit(_ character: Character) {
        if let expansion = MorseCodec.prosignText(for: character) {
            for c in expansion { emitOrHold(c) }
        } else {
            emitOrHold(character)
        }
    }

    // MARK: - Emission Probation (mirrors CWDemodulator)

    private func emitOrHold(_ char: Character) {
        if emissionConfirmed {
            onCharacterDecoded?(char, currentToneFrequency)
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
        while probationChars.first == " " { probationChars.removeFirst() }
        for held in probationChars {
            onCharacterDecoded?(held, currentToneFrequency)
        }
        probationChars.removeAll()
    }

    private func probationPasses(relaxed: Bool = false) -> Bool {
        let dit = max(ditBlocks, 0.5)
        if dit < 2.75 {
            guard signalPower > noisePower * 12 else { return false }
        }
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
        guard dits.count >= 2, dahs.count >= 2 else { return false }
        let ratio = (dahs.reduce(0, +) / Double(dahs.count)) / (dits.reduce(0, +) / Double(dits.count))
        guard ratio >= 2.0, ratio <= 4.6 else { return false }
        guard cv(dits) <= probationMaxClassCV, cv(dahs) <= probationMaxClassCV else { return false }
        guard gaps.count < 3 || gapError <= probationMaxGapError else { return false }
        return true
    }

    /// Release held probation copy if it withstands the structural check
    /// with relaxed evidence — the channel is closing and this is the
    /// held copy's last chance (a lone "CQ" never fills the window).
    public func flushPending() {
        guard !emissionConfirmed, !probationChars.isEmpty, probationPasses(relaxed: true) else { return }
        while probationChars.first == " " { probationChars.removeFirst() }
        while probationChars.last == " " { probationChars.removeLast() }
        for held in probationChars {
            onCharacterDecoded?(held, currentToneFrequency)
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

        // Once locked, never abandon a healthy signal (ported from
        // CWDemodulator). The AFC bins integrate unfiltered audio over the
        // whole window (including key-up gaps), so in noise a neighboring bin
        // can beat the center by chance, and a strong off-frequency
        // interferer (QRM) beats it consistently — neither is a reason to
        // retune while the tone we're copying is still strong here.
        let signalHealthy = signalPower > noisePower * 25
        if afcInitialScanDone && signalHealthy { return }

        var maxPower = afcCenterAccum
        var bestOffset: Double = 0

        for i in 0..<afcAccumulators.count {
            if afcAccumulators[i] > maxPower {
                maxPower = afcAccumulators[i]
                bestOffset = afcOffsets[i]
            }
        }

        // Acquisition can be eager; once locked, demand a decisive winner.
        let margin = afcInitialScanDone ? afcMinPowerRatio : 1.2

        if bestOffset != 0 && maxPower > afcCenterAccum * margin {
            let aggressiveness = abs(bestOffset) > 75 ? afcLargeOffsetGain : afcSmallOffsetGain
            let shift = bestOffset * aggressiveness
            currentToneFrequency += shift
            clampToneFrequency()
            rebuildFilters()

            if !afcInitialScanDone {
                // Initial scan: elements accumulated at the wrong frequency
                // are garbage — discard them.
                currentElements.removeAll()
                beamHypotheses.removeAll()
                characterFlushed = false
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
    /// floor, signal level, tracked speed, and AFC lock. See
    /// CWDemodulator.resynchronize() for rationale (post-TX resume).
    public func resynchronize() {
        sampleBuffer.removeAll()
        rawSampleBuffer.removeAll()
        fftBandpassFilter.reset()
        state = .idle
        stateDurationBlocks = 0
        currentElements.removeAll()
        beamHypotheses.removeAll()
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
        // Confirmation survives the TX mute; unconfirmed queue is stale.
        probationChars.removeAll()
        probationDurations.removeAll()
        probationGaps.removeAll()
    }

    public func reset() {
        sampleBuffer.removeAll()
        rawSampleBuffer.removeAll()
        blankerLevel = 0
        signalPower = 0
        recentSignal = 0
        noisePower = 1e-10
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
        beamHypotheses.removeAll()
        for i in 0..<afcAccumulators.count { afcAccumulators[i] = 0 }

        let ditSeconds = MorseCodec.ditDuration(forWPM: configuration.wpm)
        let blockDuration = Double(blockSize) / configuration.sampleRate
        ditBlocks = ditSeconds / blockDuration
        initialDitBlocks = ditSeconds / blockDuration

        // Restore the configured frequency (an AFC-shifted filter set must
        // not survive a reset) — mirrors CWDemodulator.reset().
        currentToneFrequency = configuration.toneFrequency
        rebuildFilters()
    }
}

// MARK: - Codable Parameters

/// All tunable Bayesian CW decoder parameters, for JSON serialization.
/// Used by the CWBenchmark --bayesian-params flag for Optuna optimization.
public struct BayesianCWParams: Codable {
    // Tone detection
    public var toneDetectionSNR: Double?
    public var preambleBlocks: Int?

    // Element classification
    public var elementSigmaFraction: Double?
    public var ditDahBoundary: Double?
    public var minElementFraction: Double?

    // Beam search
    public var beamWidth: Int?
    public var pruneThreshold: Double?

    // Speed tracking
    public var speedTrackerSize: Int?
    public var speedJumpRatio: Double?

    // AFC
    public var afcUpdateInterval: Int?
    public var afcLargeOffsetGain: Double?
    public var afcSmallOffsetGain: Double?
    public var afcMinPowerRatio: Double?

    // Debounce
    public var debounceFraction: Double?

    // Threshold adaptation
    public var thresholdFractionClean: Double?
    public var thresholdFractionModerate: Double?
    public var thresholdFractionNoisy: Double?
    public var hysteresisOffRatio: Double?
    public var signalAttackRate: Double?
    public var signalDecayRate: Double?
    public var recentSignalDecay: Double?
    public var noiseFloorTrackingRate: Double?

    /// Apply non-nil values to a BayesianCWDecoder instance.
    public func apply(to decoder: BayesianCWDecoder) {
        if let v = toneDetectionSNR { decoder.toneDetectionSNR = v }
        if let v = preambleBlocks { decoder.preambleBlocks = v }
        if let v = elementSigmaFraction { decoder.elementSigmaFraction = v }
        if let v = ditDahBoundary { decoder.ditDahBoundary = v }
        if let v = minElementFraction { decoder.minElementFraction = v }
        if let v = beamWidth { decoder.beamWidth = v }
        if let v = pruneThreshold { decoder.pruneThreshold = v }
        if let v = speedTrackerSize { decoder.speedTrackerSize = v }
        if let v = speedJumpRatio { decoder.speedJumpRatio = v }
        if let v = afcUpdateInterval { decoder.afcUpdateInterval = v }
        if let v = afcLargeOffsetGain { decoder.afcLargeOffsetGain = v }
        if let v = afcSmallOffsetGain { decoder.afcSmallOffsetGain = v }
        if let v = afcMinPowerRatio { decoder.afcMinPowerRatio = v }
        if let v = debounceFraction { decoder.debounceFraction = v }
        if let v = thresholdFractionClean { decoder.thresholdFractionClean = v }
        if let v = thresholdFractionModerate { decoder.thresholdFractionModerate = v }
        if let v = thresholdFractionNoisy { decoder.thresholdFractionNoisy = v }
        if let v = hysteresisOffRatio { decoder.hysteresisOffRatio = v }
        if let v = signalAttackRate { decoder.signalAttackRate = v }
        if let v = signalDecayRate { decoder.signalDecayRate = v }
        if let v = recentSignalDecay { decoder.recentSignalDecay = v }
        if let v = noiseFloorTrackingRate { decoder.noiseFloorTrackingRate = v }
    }
}
