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

    /// Bandpass filter centered on the CW tone to reject out-of-band noise
    private var bandpassFilter: BandpassFilter

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

    /// Current detection state (used for level tracking feedback)
    private var toneActive: Bool = false

    // MARK: - State Machine

    private var state: RxState = .idle
    private var stateDurationBlocks: Int = 0

    // MARK: - Speed Tracking

    private var ditBlocks: Double
    /// Initial dit estimate from configuration (used as a floor for gap thresholds)
    private var initialDitBlocks: Double
    private var speedTracker: [Double] = []
    private let speedTrackerSize: Int = 16
    private var lastKeyDownBlocks: Int = 0
    private var lastElementWasDit: Bool = true

    // MARK: - Morse Decoder

    /// Duration of the last inTone period (for debounce merging)
    private var lastToneDuration: Int = 0

    private var morseCodec: MorseCodec
    private var currentElements: [MorseElement] = []
    private var characterFlushed: Bool = false
    private var wordSpaceEmitted: Bool = false

    // MARK: - Signal Detection

    private var _signalDetected: Bool = false
    private var toneBlocksSeen: Int = 0

    // MARK: - AFC

    private var afcFilters: [GoertzelFilter] = []
    private var afcOffsets: [Double] = []
    private var afcBlockCount: Int = 0
    private let afcUpdateInterval: Int = 30  // Update every 30 blocks (~300ms) for faster tracking
    private var afcAccumulators: [Double] = []
    private var afcCenterAccum: Double = 0
    private var currentToneFrequency: Double

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

    // MARK: - Initialization

    public init(configuration: CWConfiguration = .standard) {
        self.configuration = configuration
        self.currentToneFrequency = configuration.toneFrequency
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

        self.morseCodec = MorseCodec()

        // Bandpass filter: ±100 Hz around the CW tone to reject out-of-band noise
        self.bandpassFilter = BandpassFilter(
            lowCutoff: configuration.toneFrequency - 100,
            highCutoff: configuration.toneFrequency + 100,
            sampleRate: configuration.sampleRate
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
    }

    // MARK: - Processing

    /// Raw (unfiltered) sample buffer for AFC
    private var rawSampleBuffer: [Float] = []

    public func process(samples: [Float]) {
        for sample in samples {
            // Apply bandpass filter to reject out-of-band noise for main detector
            let filtered = bandpassFilter.process(sample)
            sampleBuffer.append(filtered)
            rawSampleBuffer.append(sample)
            if sampleBuffer.count >= blockSize {
                let filteredBlock = Array(sampleBuffer.prefix(blockSize))
                let rawBlock = Array(rawSampleBuffer.prefix(blockSize))
                sampleBuffer.removeFirst(blockSize)
                rawSampleBuffer.removeFirst(blockSize)
                processBlock(filteredBlock, rawBlock: rawBlock)
            }
        }
    }

    private func processBlock(_ block: [Float], rawBlock: [Float]) {
        // Main Goertzel uses bandpass-filtered signal for better SNR
        var filter = toneFilter
        let rawPower = Double(filter.processBlock(block))
        toneFilter = filter

        // AFC uses unfiltered signal to detect off-frequency signals
        for i in 0..<afcFilters.count {
            var f = afcFilters[i]
            let p = Double(f.processBlock(rawBlock))
            afcFilters[i] = f
            afcAccumulators[i] += p
        }
        // AFC center accumulator also uses unfiltered signal for fair comparison
        var centerFilter = GoertzelFilter(
            frequency: currentToneFrequency,
            sampleRate: configuration.sampleRate,
            blockSize: blockSize
        )
        afcCenterAccum += Double(centerFilter.processBlock(rawBlock))
        afcBlockCount += 1

        // Track signal bootstrap transition for AFC reset
        let wasBootstrapped = signalBootstrapped

        // (signalBootstrapped may change below in the signal/noise tracking section)
        // For now, use the pre-existing value for AFC triggering

        let shouldRunAFC = afcBlockCount >= afcUpdateInterval ||
            (wasBootstrapped && !afcInitialScanDone && afcBlockCount >= 3)

        if shouldRunAFC {
            if !afcInitialScanDone && wasBootstrapped {
                afcInitialScanDone = true
            }
            updateAFC()
            afcBlockCount = 0
            afcCenterAccum = 0
            for i in 0..<afcAccumulators.count { afcAccumulators[i] = 0 }
        }

        blockCount += 1

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
        // Use 5× noise threshold to prevent noise spikes from contaminating the estimate
        if rawPower > noiseLevel * 5 {
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

        // Determine tone presence using adaptive threshold
        let threshold: Double
        if signalBootstrapped {
            // Use geometric mean of signal and recent signal for fading resilience
            let effectiveSignal = sqrt(signalLevel * max(recentSignal, noiseLevel * 2))
            // Adaptive threshold position: closer to noise when clean, higher when noisy
            // SNR determines how aggressive the threshold can be
            let snr = effectiveSignal / max(noiseLevel, 1e-10)
            let thresholdFraction: Double
            if snr > 100 {
                thresholdFraction = 0.20  // Very clean: low threshold for fading sensitivity
            } else if snr > 10 {
                thresholdFraction = 0.30  // Moderate noise: balance sensitivity and rejection
            } else {
                thresholdFraction = 0.40  // Heavy noise: higher threshold to reject noise
            }
            let range = effectiveSignal - noiseLevel
            threshold = noiseLevel + thresholdFraction * range
        } else {
            // Before first signal: detect anything significantly above noise
            threshold = noiseLevel * 8.0
        }

        let toneOn = rawPower > threshold
        let toneOff = rawPower < threshold

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
                signalLevel = rawPower
                signalBootstrapped = true
                // Reset AFC accumulators for clean initial frequency measurement
                afcBlockCount = 0
                afcCenterAccum = 0
                for i in 0..<afcAccumulators.count { afcAccumulators[i] = 0 }
            } else {
                // Faster tracking for signal level to handle fading (QSB)
                // Fast attack (signal rising), moderate decay (signal fading)
                if rawPower > signalLevel {
                    signalLevel = signalLevel * 0.7 + rawPower * 0.3
                } else {
                    signalLevel = signalLevel * 0.9 + rawPower * 0.1
                }
            }
            toneActive = true
        } else if toneOff {
            // Track noise floor only during sustained silence (inter-char or word gaps)
            // Brief intra-element gaps don't represent the true noise floor and
            // can contain residual energy from envelope shaping, which would
            // artificially raise the threshold and hurt fading performance
            if state == .idle || (state == .afterTone && stateDurationBlocks > Int(ditBlocks * 1.5)) {
                noiseLevel = noiseLevel * 0.95 + rawPower * 0.05
                noiseLevel = max(noiseLevel, 1e-10)
            }
            toneActive = false
        }

        // Run state machine with raw power vs threshold
        processStateMachine(toneOn: toneOn, toneOff: toneOff)

        // Signal detection
        updateSignalDetection()
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
            if toneOn {
                // Emit pending word space before starting new word
                if wordSpaceEmitted {
                    delegate?.demodulator(self, didDecode: " ", atFrequency: currentToneFrequency)
                    wordSpaceEmitted = false
                }
                state = .inTone
                stateDurationBlocks = 1
                characterFlushed = false
            } else {
                // Extended idle — reset signal detection after very long silence
                let idleTimeout = Int(ditBlocks * 30)
                if stateDurationBlocks > idleTimeout && _signalDetected {
                    _signalDetected = false
                    toneBlocksSeen = 0
                    delegate?.demodulator(self, signalDetected: false, atFrequency: currentToneFrequency)
                }
            }

        case .inTone:
            stateDurationBlocks += 1
            if toneOff {
                let keyDownBlocks = stateDurationBlocks
                lastToneDuration = keyDownBlocks

                // Reject noise spikes shorter than 1/3 of a dit
                let minBlocks = max(2, Int(ditBlocks / 3))
                if keyDownBlocks >= minBlocks {
                    classifyElement(durationBlocks: keyDownBlocks)
                }

                state = .afterTone
                stateDurationBlocks = 0
                characterFlushed = false
                wordSpaceEmitted = false
            }

        case .afterTone:
            stateDurationBlocks += 1

            if toneOn {
                let gapBlocks = stateDurationBlocks

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
                let interCharThreshold = gapDit * 2.0
                let wordThreshold = gapDit * 5.0

                // Flush pending character if gap exceeds inter-char threshold
                if Double(gapBlocks) >= interCharThreshold && !currentElements.isEmpty && !characterFlushed {
                    flushCharacter()
                    characterFlushed = true
                }

                // Emit word space if gap exceeds word threshold
                if Double(gapBlocks) >= wordThreshold && !wordSpaceEmitted {
                    wordSpaceEmitted = true
                }

                // Emit pending word space before starting next word's elements
                if wordSpaceEmitted {
                    delegate?.demodulator(self, didDecode: " ", atFrequency: currentToneFrequency)
                    wordSpaceEmitted = false
                }

                state = .inTone
                stateDurationBlocks = 1
            } else {
                let gapBlocks = stateDurationBlocks
                let gapDit = ditBlocks  // Use adaptive estimate for gap classification
                let interCharThreshold = gapDit * 2.0
                let wordThreshold = gapDit * 5.0

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

                // Return to idle after very long silence
                if Double(gapBlocks) >= ditBlocks * 15 {
                    state = .idle
                    stateDurationBlocks = 0
                }
            }
        }
    }

    // MARK: - Element Classification

    private func classifyElement(durationBlocks: Int) {
        let duration = Double(durationBlocks)
        let twoDits = ditBlocks * 2.0

        let element: MorseElement = duration <= twoDits ? .dit : .dah
        currentElements.append(element)
        characterFlushed = false

        if debugEnabled {
            print("  ELEMENT: \(element) dur=\(durationBlocks) ditBlocks=\(String(format:"%.1f", ditBlocks)) 2dit=\(String(format:"%.1f", twoDits))")
        }

        updateSpeedTracking(durationBlocks: durationBlocks, element: element)
        lastKeyDownBlocks = durationBlocks
        lastElementWasDit = (element == .dit)
    }

    // MARK: - Speed Tracking

    private func updateSpeedTracking(durationBlocks: Int, element: MorseElement) {
        guard lastKeyDownBlocks > 0 else { return }

        let current = Double(durationBlocks)
        let last = Double(lastKeyDownBlocks)

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
        let elemStr = currentElements.map { $0 == .dit ? "." : "-" }.joined()
        let char = MorseCodec.decode(currentElements)
        if debugEnabled {
            print("  FLUSH: \(elemStr) → \(char.map { String($0) } ?? "nil")")
        }
        if let char = char {
            delegate?.demodulator(self, didDecode: char, atFrequency: currentToneFrequency)
        }
        currentElements.removeAll()
    }

    // MARK: - AFC

    private func updateAFC() {
        guard _signalDetected else { return }

        var maxPower = afcCenterAccum
        var bestOffset: Double = 0

        for i in 0..<afcAccumulators.count {
            if afcAccumulators[i] > maxPower {
                maxPower = afcAccumulators[i]
                bestOffset = afcOffsets[i]
            }
        }

        if bestOffset != 0 && maxPower > afcCenterAccum * 1.2 {
            let aggressiveness = abs(bestOffset) > 75 ? 0.8 : 0.5
            let shift = bestOffset * aggressiveness
            currentToneFrequency += shift
            rebuildFilters()

            // If this is the initial scan and the shift is large (>30 Hz),
            // discard any elements accumulated at the wrong frequency
            if !afcInitialScanDone || abs(shift) > 30 {
                if !currentElements.isEmpty {
                    currentElements.removeAll()
                    characterFlushed = false
                }
            }
        }
    }

    private func rebuildFilters() {
        toneFilter = GoertzelFilter(
            frequency: currentToneFrequency,
            sampleRate: configuration.sampleRate,
            blockSize: blockSize
        )
        bandpassFilter = BandpassFilter(
            lowCutoff: currentToneFrequency - 100,
            highCutoff: currentToneFrequency + 100,
            sampleRate: configuration.sampleRate
        )
        for i in 0..<afcFilters.count {
            afcFilters[i] = GoertzelFilter(
                frequency: currentToneFrequency + afcOffsets[i],
                sampleRate: configuration.sampleRate,
                blockSize: blockSize
            )
        }
    }

    // MARK: - Control

    public func reset() {
        sampleBuffer.removeAll()
        rawSampleBuffer.removeAll()
        signalLevel = 0
        recentSignal = 0
        noiseLevel = 1e-10
        signalBootstrapped = false
        blockCount = 0
        noiseEstimateAccum = 0
        afcInitialScanDone = false
        toneActive = false
        state = .idle
        stateDurationBlocks = 0
        currentElements.removeAll()
        characterFlushed = false
        wordSpaceEmitted = false
        lastToneDuration = 0
        lastKeyDownBlocks = 0
        lastElementWasDit = true
        speedTracker.removeAll()
        _signalDetected = false
        toneBlocksSeen = 0
        morseCodec.reset()
        bandpassFilter.reset()
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
