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

    // -- Tone probability model --

    /// Smoothing alpha for the exponential moving average of tone probability.
    /// Higher = more responsive to rapid changes, lower = more stable.
    /// Range: 0.1 - 0.9. Default: 0.4
    public var toneSmoothing: Double = 0.4

    /// Prior weight for tone-on probability before signal is detected.
    /// Higher = more likely to detect a tone in ambiguous situations.
    /// Range: 0.1 - 0.9. Default: 0.3
    public var tonePriorWeight: Double = 0.3

    /// Tracking rate for signal (tone-on) power estimation.
    /// Higher = faster adaptation to signal level changes (fading).
    /// Range: 0.05 - 0.5. Default: 0.15
    public var signalTrackingRate: Double = 0.15

    /// Tracking rate for noise (tone-off) power estimation.
    /// Lower = more stable noise floor, but slower to adapt to changing conditions.
    /// Range: 0.01 - 0.2. Default: 0.05
    public var noiseTrackingRate: Double = 0.05

    /// Minimum SNR (linear ratio) required to declare tone present.
    /// Higher = fewer false detections but may miss weak signals.
    /// Range: 1.5 - 10.0. Default: 3.0
    public var toneDetectionSNR: Double = 3.0

    /// Number of preamble blocks for initial noise estimation.
    /// Range: 5 - 40. Default: 20
    public var preambleBlocks: Int = 20

    // -- Element classification (Gaussian model) --

    /// Sigma for element duration classification, as a fraction of the dit duration.
    /// Controls timing jitter tolerance. Smaller = stricter timing requirements.
    /// Range: 0.15 - 0.60. Default: 0.35
    public var elementSigmaFraction: Double = 0.35

    /// Dit/dah boundary as a multiple of estimated dit duration.
    /// Elements shorter than this are classified as dit, longer as dah.
    /// Range: 1.5 - 2.5. Default: 2.0
    public var ditDahBoundary: Double = 2.0

    /// Minimum element duration as fraction of dit blocks (noise rejection).
    /// Elements shorter than this are discarded as noise spikes.
    /// Range: 0.15 - 0.5. Default: 0.33
    public var minElementFraction: Double = 0.33

    // -- Gap classification --

    /// Inter-character gap threshold as multiple of dit duration.
    /// Gaps longer than this flush the current character.
    /// Range: 1.5 - 3.5. Default: 2.0
    public var interCharGapMultiple: Double = 2.0

    /// Word gap threshold as multiple of dit duration.
    /// Gaps longer than this insert a word space.
    /// Range: 4.0 - 8.0. Default: 5.0
    public var wordGapMultiple: Double = 5.0

    // -- Beam search character hypotheses --

    /// Maximum number of active hypotheses (beam width).
    /// Higher = more thorough search but slower.
    /// Range: 4 - 32. Default: 8
    public var beamWidth: Int = 8

    /// Pruning threshold: hypotheses with probability below
    /// bestProb * pruneThreshold are discarded.
    /// Range: 0.001 - 0.1. Default: 0.01
    public var pruneThreshold: Double = 0.01

    // -- Speed tracking --

    /// Size of the speed tracker window (number of element pairs).
    /// Range: 4 - 32. Default: 16
    public var speedTrackerSize: Int = 16

    /// Speed jump detection ratio. If new estimate differs from current
    /// by more than this factor, reset the tracker for fast adaptation.
    /// Range: 1.2 - 2.0. Default: 1.5
    public var speedJumpRatio: Double = 1.5

    // -- AFC --

    /// AFC update interval in blocks.
    /// Range: 10 - 60. Default: 30
    public var afcUpdateInterval: Int = 30

    /// AFC aggressiveness for large offsets (>75 Hz).
    /// Range: 0.3 - 1.0. Default: 0.8
    public var afcLargeOffsetGain: Double = 0.8

    /// AFC aggressiveness for small offsets (<=75 Hz).
    /// Range: 0.2 - 0.8. Default: 0.5
    public var afcSmallOffsetGain: Double = 0.5

    /// AFC minimum power ratio to trigger correction.
    /// Best AFC bin must exceed center bin by this factor.
    /// Range: 1.05 - 2.0. Default: 1.2
    public var afcMinPowerRatio: Double = 1.2

    // -- Debounce --

    /// Debounce threshold as fraction of dit blocks.
    /// Gaps shorter than this are merged with the preceding tone.
    /// Range: 0.2 - 0.6. Default: 0.4
    public var debounceFraction: Double = 0.4

    // -- Threshold adaptation --

    /// Threshold fraction for very clean signals (high SNR).
    /// Range: 0.1 - 0.4. Default: 0.20
    public var thresholdFractionClean: Double = 0.20

    /// Threshold fraction for moderate noise.
    /// Range: 0.15 - 0.5. Default: 0.30
    public var thresholdFractionModerate: Double = 0.30

    /// Threshold fraction for heavy noise.
    /// Range: 0.25 - 0.6. Default: 0.40
    public var thresholdFractionNoisy: Double = 0.40

    /// Signal tracking attack rate (rising signal).
    /// Range: 0.1 - 0.6. Default: 0.3
    public var signalAttackRate: Double = 0.3

    /// Signal tracking decay rate (falling signal).
    /// Range: 0.05 - 0.3. Default: 0.15
    public var signalDecayRate: Double = 0.15

    /// Recent signal fast decay rate during tone-on.
    /// Range: 0.1 - 0.5. Default: 0.2
    public var recentSignalDecay: Double = 0.2

    /// Noise floor tracking rate during silence.
    /// Range: 0.01 - 0.15. Default: 0.05
    public var noiseFloorTrackingRate: Double = 0.05

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
    private var smoothedToneProb: Double = 0
    private var toneActive: Bool = false

    // State machine
    private var state: RxState = .idle
    private var stateDurationBlocks: Int = 0
    private var lastToneDuration: Int = 0

    // Speed tracking
    private var ditBlocks: Double
    private var initialDitBlocks: Double
    private var speedTracker: [Double] = []
    private var lastKeyDownBlocks: Int = 0
    private var lastElementWasDit: Bool = true

    // Morse decoder
    private var morseCodec: MorseCodec
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
    private var afcOffsets: [Double] = []
    private var afcBlockCount: Int = 0
    private var afcAccumulators: [Double] = []
    private var afcCenterAccum: Double = 0
    private var currentToneFrequency: Double
    private var afcInitialScanDone: Bool = false

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
    }

    // MARK: - Processing

    private var rawSampleBuffer: [Float] = []

    public func process(samples: [Float]) {
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
        let goertzelPower = Double(filter.processBlock(block))
        toneFilter = filter

        let rawPower = goertzelPower

        // AFC using unfiltered signal
        for i in 0..<afcFilters.count {
            var f = afcFilters[i]
            let p = Double(f.processBlock(rawBlock))
            afcFilters[i] = f
            afcAccumulators[i] += p
        }
        var centerFilter = GoertzelFilter(
            frequency: currentToneFrequency,
            sampleRate: configuration.sampleRate,
            blockSize: blockSize
        )
        afcCenterAccum += Double(centerFilter.processBlock(rawBlock))
        afcBlockCount += 1

        let wasBootstrapped = signalBootstrapped

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

        // Bayesian tone probability computation
        let toneProb = computeToneProbability(power: rawPower)
        smoothedToneProb = smoothedToneProb * (1.0 - toneSmoothing) + toneProb * toneSmoothing

        // Determine tone presence using adaptive threshold
        let threshold: Double
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
            threshold = noisePower + thresholdFraction * range
        } else {
            threshold = noisePower * 8.0
        }

        let toneOn = rawPower > threshold
        let toneOff = rawPower < threshold

        // Update signal/noise tracking
        if toneOn {
            if !signalBootstrapped {
                signalPower = rawPower
                signalBootstrapped = true
                afcBlockCount = 0
                afcCenterAccum = 0
                for i in 0..<afcAccumulators.count { afcAccumulators[i] = 0 }
            } else {
                if rawPower > signalPower {
                    signalPower = signalPower * (1.0 - signalAttackRate) + rawPower * signalAttackRate
                } else {
                    signalPower = signalPower * (1.0 - signalDecayRate) + rawPower * signalDecayRate
                }
            }
            toneActive = true
        } else if toneOff {
            if state == .idle || (state == .afterTone && stateDurationBlocks > Int(ditBlocks * 1.5)) {
                noisePower = noisePower * (1.0 - noiseFloorTrackingRate) + rawPower * noiseFloorTrackingRate
                noisePower = max(noisePower, 1e-10)
            }
            toneActive = false
        }

        processStateMachine(toneOn: toneOn, toneOff: toneOff)
        updateSignalDetection()
    }

    // MARK: - Bayesian Tone Probability

    private func computeToneProbability(power: Double) -> Double {
        guard signalBootstrapped else { return tonePriorWeight }

        let sigVar = max(signalPower * 0.5, 1e-10)
        let noiVar = max(noisePower * 2.0, 1e-10)

        // Likelihood under signal model (power expected near signalPower)
        let sigLL = gaussianLogLikelihood(x: power, mean: signalPower, variance: sigVar)
        // Likelihood under noise model (power expected near noisePower)
        let noiLL = gaussianLogLikelihood(x: power, mean: noisePower, variance: noiVar)

        // Bayesian posterior with prior
        let logPrior = log(tonePriorWeight)
        let logPriorNot = log(1.0 - tonePriorWeight)

        let logPostSignal = sigLL + logPrior
        let logPostNoise = noiLL + logPriorNot

        // Log-sum-exp for numerical stability
        let maxLog = max(logPostSignal, logPostNoise)
        let prob = exp(logPostSignal - maxLog) /
            (exp(logPostSignal - maxLog) + exp(logPostNoise - maxLog))

        return min(max(prob, 0.001), 0.999)
    }

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
            if toneOn {
                if wordSpaceEmitted {
                    onCharacterDecoded?(" ", currentToneFrequency)
                    wordSpaceEmitted = false
                }
                state = .inTone
                stateDurationBlocks = 1
                characterFlushed = false
            } else {
                let idleTimeout = Int(ditBlocks * 30)
                if stateDurationBlocks > idleTimeout && _signalDetected {
                    _signalDetected = false
                    toneBlocksSeen = 0
                    onSignalDetected?(false, currentToneFrequency)
                }
            }

        case .inTone:
            stateDurationBlocks += 1
            if toneOff {
                let keyDownBlocks = stateDurationBlocks
                lastToneDuration = keyDownBlocks

                let minBlocks = max(2, Int(ditBlocks * minElementFraction))
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
                let interCharThreshold = gapDit * interCharGapMultiple
                let wordThreshold = gapDit * wordGapMultiple

                if Double(gapBlocks) >= interCharThreshold && !currentElements.isEmpty && !characterFlushed {
                    flushCharacter()
                    characterFlushed = true
                }

                if Double(gapBlocks) >= wordThreshold && !wordSpaceEmitted {
                    wordSpaceEmitted = true
                }

                if wordSpaceEmitted {
                    onCharacterDecoded?(" ", currentToneFrequency)
                    wordSpaceEmitted = false
                }

                state = .inTone
                stateDurationBlocks = 1
            } else {
                let gapBlocks = stateDurationBlocks
                let gapDit = ditBlocks
                let interCharThreshold = gapDit * interCharGapMultiple
                let wordThreshold = gapDit * wordGapMultiple

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

                if Double(gapBlocks) >= ditBlocks * 15 {
                    state = .idle
                    stateDurationBlocks = 0
                }
            }
        }
    }

    // MARK: - Element Classification (Gaussian Model)

    private func classifyElement(durationBlocks: Int) {
        let duration = Double(durationBlocks)
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

        updateSpeedTracking(durationBlocks: durationBlocks, element: element)
        lastKeyDownBlocks = durationBlocks
        lastElementWasDit = (element == .dit)

        // Beam search: maintain alternative hypotheses
        updateBeam(element: element, ditLL: ditLL, dahLL: dahLL)
    }

    // MARK: - Beam Search

    private func updateBeam(element: MorseElement, ditLL: Double, dahLL: Double) {
        if beamHypotheses.isEmpty {
            // Initialize with both possibilities
            beamHypotheses = [
                Hypothesis(elements: [.dit], logProb: ditLL),
                Hypothesis(elements: [.dah], logProb: dahLL),
            ]
        } else {
            // Expand each hypothesis with both possibilities
            var newHypotheses: [Hypothesis] = []
            for hyp in beamHypotheses {
                newHypotheses.append(Hypothesis(
                    elements: hyp.elements + [.dit],
                    logProb: hyp.logProb + ditLL
                ))
                newHypotheses.append(Hypothesis(
                    elements: hyp.elements + [.dah],
                    logProb: hyp.logProb + dahLL
                ))
            }

            // Sort by probability (descending)
            newHypotheses.sort { $0.logProb > $1.logProb }

            // Prune: keep top beamWidth and remove low-probability hypotheses
            let bestLogProb = newHypotheses.first?.logProb ?? 0
            let threshold = bestLogProb + log(pruneThreshold)
            newHypotheses = newHypotheses.filter { $0.logProb >= threshold }
            beamHypotheses = Array(newHypotheses.prefix(beamWidth))
        }
    }

    // MARK: - Speed Tracking

    private func updateSpeedTracking(durationBlocks: Int, element: MorseElement) {
        guard lastKeyDownBlocks > 0 else { return }

        let current = Double(durationBlocks)
        let last = Double(lastKeyDownBlocks)

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

        // Use beam search best hypothesis if available and different from greedy
        if let best = beamHypotheses.first,
           best.elements.count == currentElements.count {
            // Use the beam search result
            let char = MorseCodec.decode(best.elements)
            if let char = char {
                onCharacterDecoded?(char, currentToneFrequency)
            } else {
                // Fall back to greedy path if beam result is invalid
                if let greedyChar = MorseCodec.decode(currentElements) {
                    onCharacterDecoded?(greedyChar, currentToneFrequency)
                }
            }
        } else {
            // Greedy path
            let char = MorseCodec.decode(currentElements)
            if let char = char {
                onCharacterDecoded?(char, currentToneFrequency)
            }
        }

        currentElements.removeAll()
        beamHypotheses.removeAll()
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

        if bestOffset != 0 && maxPower > afcCenterAccum * afcMinPowerRatio {
            let aggressiveness = abs(bestOffset) > 75 ? afcLargeOffsetGain : afcSmallOffsetGain
            let shift = bestOffset * aggressiveness
            currentToneFrequency += shift
            rebuildFilters()

            if !afcInitialScanDone || abs(shift) > 30 {
                if !currentElements.isEmpty {
                    currentElements.removeAll()
                    beamHypotheses.removeAll()
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
    }

    // MARK: - Control

    public func reset() {
        sampleBuffer.removeAll()
        rawSampleBuffer.removeAll()
        signalPower = 0
        recentSignal = 0
        noisePower = 1e-10
        signalBootstrapped = false
        blockCount = 0
        noiseEstimateAccum = 0
        smoothedToneProb = 0
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
        fftBandpassFilter.reset()
        afcBlockCount = 0
        afcCenterAccum = 0
        beamHypotheses.removeAll()
        for i in 0..<afcAccumulators.count { afcAccumulators[i] = 0 }
    }
}

// MARK: - Codable Parameters

/// All tunable Bayesian CW decoder parameters, for JSON serialization.
/// Used by the CWBenchmark --bayesian-params flag for Optuna optimization.
public struct BayesianCWParams: Codable {
    // Tone probability
    public var toneSmoothing: Double?
    public var tonePriorWeight: Double?
    public var signalTrackingRate: Double?
    public var noiseTrackingRate: Double?
    public var toneDetectionSNR: Double?
    public var preambleBlocks: Int?

    // Element classification
    public var elementSigmaFraction: Double?
    public var ditDahBoundary: Double?
    public var minElementFraction: Double?

    // Gap classification
    public var interCharGapMultiple: Double?
    public var wordGapMultiple: Double?

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
    public var signalAttackRate: Double?
    public var signalDecayRate: Double?
    public var recentSignalDecay: Double?
    public var noiseFloorTrackingRate: Double?

    /// Apply non-nil values to a BayesianCWDecoder instance.
    public func apply(to decoder: BayesianCWDecoder) {
        if let v = toneSmoothing { decoder.toneSmoothing = v }
        if let v = tonePriorWeight { decoder.tonePriorWeight = v }
        if let v = signalTrackingRate { decoder.signalTrackingRate = v }
        if let v = noiseTrackingRate { decoder.noiseTrackingRate = v }
        if let v = toneDetectionSNR { decoder.toneDetectionSNR = v }
        if let v = preambleBlocks { decoder.preambleBlocks = v }
        if let v = elementSigmaFraction { decoder.elementSigmaFraction = v }
        if let v = ditDahBoundary { decoder.ditDahBoundary = v }
        if let v = minElementFraction { decoder.minElementFraction = v }
        if let v = interCharGapMultiple { decoder.interCharGapMultiple = v }
        if let v = wordGapMultiple { decoder.wordGapMultiple = v }
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
        if let v = signalAttackRate { decoder.signalAttackRate = v }
        if let v = signalDecayRate { decoder.signalDecayRate = v }
        if let v = recentSignalDecay { decoder.recentSignalDecay = v }
        if let v = noiseFloorTrackingRate { decoder.noiseFloorTrackingRate = v }
    }
}
