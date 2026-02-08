//
//  FSKDemodulator.swift
//  DigiModesCore
//
//  FSK demodulator for RTTY: converts audio samples to Baudot codes
//

import Foundation

/// Delegate protocol for receiving demodulated characters
public protocol FSKDemodulatorDelegate: AnyObject {
    /// Called when a character has been decoded
    /// - Parameters:
    ///   - demodulator: The demodulator that decoded the character
    ///   - character: The decoded ASCII character
    ///   - frequency: The center frequency of the demodulator
    func demodulator(
        _ demodulator: FSKDemodulator,
        didDecode character: Character,
        atFrequency frequency: Double
    )

    /// Called when signal detection state changes
    /// - Parameters:
    ///   - demodulator: The demodulator
    ///   - detected: Whether a valid FSK signal is detected
    ///   - frequency: The center frequency of the demodulator
    func demodulator(
        _ demodulator: FSKDemodulator,
        signalDetected detected: Bool,
        atFrequency frequency: Double
    )
}

/// Represents a bit decision with confidence level
public struct BitDecision {
    /// The decoded bit value
    public let value: Bool

    /// Confidence level from 0.0 (uncertain) to 1.0 (certain)
    public let confidence: Float

    public init(value: Bool, confidence: Float) {
        self.value = value
        self.confidence = min(1.0, max(0.0, confidence))
    }
}

/// FSK Demodulator state machine states
public enum DemodulatorState: Equatable {
    case waitingForStart
    case inStartBit(samplesProcessed: Int)
    case receivingData(bit: Int, samplesProcessed: Int, accumulator: UInt8, confidence: Float)
    case inStopBits(samplesProcessed: Int, markAccumulator: Float, sampleCount: Int)
}

/// FSK Demodulator for RTTY reception
///
/// Converts FSK audio samples to Baudot codes using Goertzel filters
/// for mark/space frequency detection and a state machine for bit timing.
///
/// Character framing expected:
/// - 1 start bit (space frequency)
/// - 5 data bits (LSB first, mark=1, space=0)
/// - 1.5 stop bits (mark frequency)
///
/// Improvements for noisy HF channels:
/// - Bandpass pre-filtering to reject out-of-band noise
/// - AGC to handle fading signals
/// - Adaptive squelch that tracks noise floor
/// - Extended correlation averaging with weighting
/// - Soft decisions with confidence tracking
/// - Stop bit validation
public final class FSKDemodulator {

    // MARK: - Properties

    private var configuration: RTTYConfiguration
    private var markFilter: GoertzelFilter
    private var spaceFilter: GoertzelFilter
    private let baudotCodec: BaudotCodec

    /// Bandpass filter for out-of-band noise rejection
    private var bandpassFilter: BandpassFilter

    /// Current state machine state
    public private(set) var state: DemodulatorState = .waitingForStart

    /// Delegate for receiving decoded characters
    public weak var delegate: FSKDemodulatorDelegate?

    /// Step size for state machine updates (samplesPerBit / 4).
    /// 4 steps per bit gives fine timing resolution for accurate bit sampling.
    private let stateStepSize: Int

    /// Window size for Goertzel analysis (samplesPerBit / 2).
    /// This larger window provides frequency resolution of 2*baudRate Hz, which gives good
    /// discrimination for the standard 170 Hz shift at all baud rates.
    /// At 45.45 baud / 170 Hz shift / 48 kHz: window=528 → resolution 91 Hz.
    private let goertzelWindowSize: Int

    /// Samples accumulated since last state machine step
    private var sampleBuffer: [Float] = []

    /// Sliding analysis window for Goertzel computation (last goertzelWindowSize samples)
    private var analysisWindow: [Float] = []

    /// Correlation history for signal detection (smoothing)
    private var correlationHistory: [Float] = []

    /// Dynamic correlation history size (~1 bit period worth of steps)
    private var correlationHistorySize: Int {
        max(16, configuration.samplesPerBit / stateStepSize)
    }

    /// Threshold for mark/space decision
    private let correlationThreshold: Float = 0.2

    // MARK: - AGC Properties

    /// AGC gain factor
    private var agcGain: Float = 1.0

    /// Target signal level for AGC
    private let agcTarget: Float = 0.5

    /// AGC attack rate (fast response to strong signals)
    private let agcAttack: Float = 0.01

    /// AGC decay rate (slow recovery from weak signals)
    private let agcDecay: Float = 0.0001

    /// Minimum AGC gain
    private let agcMinGain: Float = 0.1

    /// Maximum AGC gain
    private let agcMaxGain: Float = 10.0

    // MARK: - Adaptive Squelch Properties

    /// Tracked noise floor level
    private var noiseFloor: Float = 0.1

    /// Noise floor tracking rate for signals below current floor
    private let noiseTrackingFast: Float = 0.01

    /// Noise floor tracking rate for signals near current floor
    private let noiseTrackingSlow: Float = 0.001

    /// Multiplier for noise floor to get squelch level
    private let squelchMultiplier: Float = 3.0

    /// Adaptive squelch level (computed from noise floor)
    public var adaptiveSquelchLevel: Float {
        noiseFloor * squelchMultiplier
    }

    /// Signal detection state
    private var _signalDetected: Bool = false
    public var signalDetected: Bool {
        _signalDetected
    }

    /// Manual squelch level override (0.0-1.0). Set to 0 to use adaptive squelch.
    public var squelchLevel: Float = 0

    /// Effective squelch level (uses manual if set, otherwise adaptive)
    private var effectiveSquelchLevel: Float {
        squelchLevel > 0 ? squelchLevel : adaptiveSquelchLevel
    }

    // MARK: - Confidence Tracking

    /// Minimum confidence threshold for character output
    public var minCharacterConfidence: Float = 0.0

    /// Last character's confidence level
    public private(set) var lastCharacterConfidence: Float = 0

    // MARK: - AFC Properties

    /// Whether AFC (Automatic Frequency Control) is enabled
    public var afcEnabled: Bool = true

    /// Current frequency correction in Hz (read-only)
    public private(set) var frequencyCorrection: Float = 0

    /// AFC tracking range in Hz (searches ±this value)
    public var afcRange: Float = 50.0

    /// AFC update interval in state steps (~2 bits at 4 steps/bit)
    private let afcUpdateInterval: Int = 8

    /// Counter for AFC update timing
    private var afcBlockCounter: Int = 0

    /// AFC filter coefficient (0-1, lower = slower tracking)
    private let afcAlpha: Float = 0.1

    /// Offset Goertzel filters for AFC correlation detection
    private var markOffsetFilters: [Float: GoertzelFilter] = [:]
    private var spaceOffsetFilters: [Float: GoertzelFilter] = [:]

    /// Average signal strength
    public var signalStrength: Float {
        guard !correlationHistory.isEmpty else { return 0 }
        let avgMagnitude = correlationHistory.map { abs($0) }.reduce(0, +) / Float(correlationHistory.count)
        return avgMagnitude
    }

    /// Center (mark) frequency
    public var centerFrequency: Double {
        configuration.markFrequency
    }

    // MARK: - Initialization

    /// Create an FSK demodulator
    /// - Parameter configuration: RTTY configuration (frequencies, baud rate, etc.)
    public init(configuration: RTTYConfiguration = .standard) {
        self.configuration = configuration
        self.baudotCodec = BaudotCodec()

        // State machine steps at samplesPerBit/4 for fine timing (4 steps per bit).
        self.stateStepSize = max(16, configuration.samplesPerBit / 4)

        // Goertzel window is samplesPerBit/2 for good frequency resolution.
        // At 45.45 baud: 528 samples → 91 Hz resolution (good for 170 Hz shift).
        // The window slides with 75% overlap, giving both fine timing AND good resolution.
        self.goertzelWindowSize = max(64, configuration.samplesPerBit / 2)

        self.markFilter = GoertzelFilter(
            frequency: configuration.markFrequency,
            sampleRate: configuration.sampleRate,
            blockSize: goertzelWindowSize
        )

        self.spaceFilter = GoertzelFilter(
            frequency: configuration.spaceFrequency,
            sampleRate: configuration.sampleRate,
            blockSize: goertzelWindowSize
        )

        // Initialize bandpass filter for mark/space frequencies with 75 Hz margin
        self.bandpassFilter = BandpassFilter(
            markFrequency: configuration.markFrequency,
            spaceFrequency: configuration.spaceFrequency,
            margin: 75.0,
            sampleRate: configuration.sampleRate
        )

        // Initialize AFC offset filters
        initializeAFCFilters()
    }

    // MARK: - AFC Methods

    /// Initialize Goertzel filters at various frequency offsets for AFC
    private func initializeAFCFilters() {
        let offsets: [Float] = [-50, -25, 0, 25, 50]

        markOffsetFilters.removeAll()
        spaceOffsetFilters.removeAll()

        for offset in offsets {
            markOffsetFilters[offset] = GoertzelFilter(
                frequency: configuration.markFrequency + Double(offset),
                sampleRate: configuration.sampleRate,
                blockSize: goertzelWindowSize
            )
            spaceOffsetFilters[offset] = GoertzelFilter(
                frequency: configuration.spaceFrequency + Double(offset),
                sampleRate: configuration.sampleRate,
                blockSize: goertzelWindowSize
            )
        }
    }

    /// Compute the best frequency offset by finding the peak correlation
    /// - Parameter samples: Audio samples to analyze
    /// - Returns: Best frequency offset in Hz
    private func computeAFCCorrection(samples: [Float]) -> Float {
        var bestOffset: Float = 0
        var bestCorrelation: Float = -2.0

        for (offset, var markFilter) in markOffsetFilters {
            guard var spaceFilter = spaceOffsetFilters[offset] else { continue }

            let markPower = markFilter.processBlock(samples)
            let spacePower = spaceFilter.processBlock(samples)

            markFilter.reset()
            spaceFilter.reset()

            // Update filters in dictionaries
            markOffsetFilters[offset] = markFilter
            spaceOffsetFilters[offset] = spaceFilter

            let total = markPower + spacePower
            guard total > 0.001 else { continue }

            // Use absolute correlation (signal strength at this offset)
            let correlation = abs(markPower - spacePower) / total

            if correlation > bestCorrelation {
                bestCorrelation = correlation
                bestOffset = offset
            }
        }

        return bestOffset
    }

    /// Apply frequency correction to the demodulator filters
    /// - Parameter correction: Frequency correction in Hz
    private func applyFrequencyCorrection(_ correction: Float) {
        let newMarkFreq = configuration.markFrequency + Double(correction)

        // Update main Goertzel filters
        markFilter = GoertzelFilter(
            frequency: newMarkFreq,
            sampleRate: configuration.sampleRate,
            blockSize: goertzelWindowSize
        )
        spaceFilter = GoertzelFilter(
            frequency: newMarkFreq - configuration.shift,
            sampleRate: configuration.sampleRate,
            blockSize: goertzelWindowSize
        )

        // Update bandpass filter center
        bandpassFilter = BandpassFilter(
            markFrequency: newMarkFreq,
            spaceFrequency: newMarkFreq - configuration.shift,
            margin: 75.0,
            sampleRate: configuration.sampleRate
        )

        // Rebuild offset filters around new center
        initializeAFCFilters()
    }

    // MARK: - Processing

    /// Process a buffer of audio samples
    /// - Parameter samples: Audio samples to process
    public func process(samples: [Float]) {
        for sample in samples {
            processSample(sample)
        }
    }

    /// Process a single audio sample
    /// - Parameter sample: Audio sample value
    private func processSample(_ sample: Float) {
        // Apply bandpass filter to reject out-of-band noise
        let filteredSample = bandpassFilter.process(sample)

        // Apply AGC to normalize signal level
        let agcSample = applyAGC(filteredSample)

        sampleBuffer.append(agcSample)
        analysisWindow.append(agcSample)

        // Trim sliding analysis window to goertzelWindowSize
        if analysisWindow.count > goertzelWindowSize {
            analysisWindow.removeFirst(analysisWindow.count - goertzelWindowSize)
        }

        // State machine step every stateStepSize samples
        if sampleBuffer.count >= stateStepSize {
            let correlation = analyzeBlock()
            updateCorrelationHistory(correlation)
            updateNoiseFloor(correlation)
            updateSignalDetection()

            // AFC update: periodically check for frequency drift
            if afcEnabled {
                afcBlockCounter += 1
                if afcBlockCounter >= afcUpdateInterval {
                    let correction = computeAFCCorrection(samples: analysisWindow)
                    // Low-pass filter the correction for smooth tracking
                    frequencyCorrection = frequencyCorrection * (1 - afcAlpha) + correction * afcAlpha

                    // Apply correction if significant (> 5 Hz)
                    if abs(frequencyCorrection) > 5.0 {
                        applyFrequencyCorrection(frequencyCorrection)
                    }
                    afcBlockCounter = 0
                }
            }

            processStateMachine(correlation: correlation)
            sampleBuffer.removeAll(keepingCapacity: true)
        }
    }

    /// Apply AGC to normalize signal level
    /// - Parameter sample: Input sample
    /// - Returns: Gain-adjusted sample
    private func applyAGC(_ sample: Float) -> Float {
        let output = sample * agcGain
        let level = abs(output)

        if level > agcTarget {
            // Fast attack - reduce gain quickly for strong signals
            agcGain *= (1.0 - agcAttack)
        } else {
            // Slow decay - increase gain slowly for weak signals
            agcGain *= (1.0 + agcDecay)
        }

        // Clamp gain to reasonable range
        agcGain = max(agcMinGain, min(agcMaxGain, agcGain))

        return output
    }

    /// Update noise floor estimate
    /// - Parameter correlation: Current correlation value
    private func updateNoiseFloor(_ correlation: Float) {
        let magnitude = abs(correlation)

        if magnitude < noiseFloor {
            // Signal is below noise floor - track quickly
            noiseFloor = noiseFloor * (1.0 - noiseTrackingFast) + magnitude * noiseTrackingFast
        } else if magnitude < noiseFloor * 2.0 {
            // Signal is near noise floor - track slowly
            noiseFloor = noiseFloor * (1.0 - noiseTrackingSlow) + magnitude * noiseTrackingSlow
        }
        // Signals well above noise floor don't update the floor

        // Keep noise floor in reasonable range
        noiseFloor = max(0.01, min(0.5, noiseFloor))
    }

    /// Analyze the sliding analysis window and return mark/space correlation
    /// - Returns: Correlation value: positive = mark, negative = space
    private func analyzeBlock() -> Float {
        let markPower = markFilter.processBlock(analysisWindow)
        let spacePower = spaceFilter.processBlock(analysisWindow)

        markFilter.reset()
        spaceFilter.reset()

        // Compute correlation: (mark - space) / (mark + space)
        let total = markPower + spacePower
        guard total > 0.001 else { return 0 }  // Silence

        return (markPower - spacePower) / total
    }

    /// Update the correlation history for smoothing
    private func updateCorrelationHistory(_ correlation: Float) {
        correlationHistory.append(correlation)
        while correlationHistory.count > correlationHistorySize {
            correlationHistory.removeFirst()
        }
    }

    /// Calculate weighted average correlation (recent samples weighted higher)
    private func weightedAverageCorrelation() -> Float {
        guard !correlationHistory.isEmpty else { return 0 }

        var sum: Float = 0
        var weightSum: Float = 0

        for (i, corr) in correlationHistory.enumerated() {
            let weight = Float(i + 1)  // Linear weighting: 1, 2, 3, ...
            sum += corr * weight
            weightSum += weight
        }

        return sum / weightSum
    }

    /// Make a soft decision with confidence
    /// - Parameter correlation: Current correlation value
    /// - Returns: Bit decision with confidence
    private func makeSoftDecision(correlation: Float) -> BitDecision {
        let magnitude = abs(correlation)
        let value = correlation > 0  // Positive = mark = 1

        // Confidence scales with magnitude
        // Full confidence at 0.5 correlation, zero at threshold
        let confidence: Float
        if magnitude < correlationThreshold {
            confidence = 0
        } else {
            confidence = min(1.0, (magnitude - correlationThreshold) / (0.5 - correlationThreshold))
        }

        return BitDecision(value: value, confidence: confidence)
    }

    /// Update signal detection state
    private func updateSignalDetection() {
        let avgStrength = signalStrength
        let newDetected = avgStrength > effectiveSquelchLevel

        if newDetected != _signalDetected {
            _signalDetected = newDetected
            delegate?.demodulator(
                self,
                signalDetected: newDetected,
                atFrequency: centerFrequency
            )
        }
    }

    /// Process the state machine with current correlation value
    private func processStateMachine(correlation: Float) {
        let samplesPerStep = stateStepSize
        let samplesPerBit = configuration.samplesPerBit
        // Sample at 75% of the bit period to ensure we're past transition artifacts.
        // With 4 steps per bit and a Goertzel window of samplesPerBit/2, the window
        // at the 75% sample point covers 25-75% of the bit — entirely within the bit.
        let bitSamplePoint = samplesPerBit * 3 / 4

        switch state {
        case .waitingForStart:
            // Looking for transition from mark to space (start of start bit)
            if correlation < -correlationThreshold {
                // Detected space - could be start bit
                state = .inStartBit(samplesProcessed: samplesPerStep)
            }

        case .inStartBit(let samplesProcessed):
            let newSamples = samplesProcessed + samplesPerStep

            // Verify we're still in space for the start bit
            if correlation > correlationThreshold {
                // False start - go back to waiting
                state = .waitingForStart
            } else if newSamples >= samplesPerBit {
                // Start bit complete, move to data bits
                state = .receivingData(bit: 0, samplesProcessed: 0, accumulator: 0, confidence: 1.0)
            } else {
                state = .inStartBit(samplesProcessed: newSamples)
            }

        case .receivingData(let bit, let samplesProcessed, var accumulator, var confidence):
            let newSamples = samplesProcessed + samplesPerStep

            // Sample at 75% of bit to avoid transition artifacts
            if samplesProcessed < bitSamplePoint && newSamples >= bitSamplePoint {
                // Make decision based on current correlation
                let decision = makeSoftDecision(correlation: correlation)

                if decision.value {
                    // Mark = 1
                    accumulator |= (1 << bit)
                }
                // Space = 0 (already 0 in accumulator)

                // Track minimum confidence across all bits
                confidence = min(confidence, decision.confidence)
            }

            if newSamples >= samplesPerBit {
                // Bit complete
                if bit >= 4 {
                    // All 5 data bits received, move to stop bits
                    state = .inStopBits(samplesProcessed: 0, markAccumulator: 0, sampleCount: 0)
                    // Decode and emit the character with confidence
                    decodeAndEmit(accumulator, confidence: confidence)
                } else {
                    // Move to next bit
                    state = .receivingData(
                        bit: bit + 1,
                        samplesProcessed: 0,
                        accumulator: accumulator,
                        confidence: confidence
                    )
                }
            } else {
                state = .receivingData(
                    bit: bit,
                    samplesProcessed: newSamples,
                    accumulator: accumulator,
                    confidence: confidence
                )
            }

        case .inStopBits(let samplesProcessed, var markAccumulator, var sampleCount):
            let newSamples = samplesProcessed + samplesPerStep
            let stopBitSamples = Int(1.5 * Double(samplesPerBit))

            // Accumulate correlation during stop bits
            markAccumulator += correlation
            sampleCount += 1

            if newSamples >= stopBitSamples {
                // Stop bits complete
                // Validate that stop bits were mark frequency
                let avgStopCorrelation = sampleCount > 0 ? markAccumulator / Float(sampleCount) : 0

                if avgStopCorrelation < 0 {
                    // Stop bits were space - framing error
                    // Character was already emitted but may be unreliable
                    // Future: could flag or resync here
                }

                state = .waitingForStart
            } else {
                state = .inStopBits(
                    samplesProcessed: newSamples,
                    markAccumulator: markAccumulator,
                    sampleCount: sampleCount
                )
            }
        }
    }

    /// Decode a Baudot code and emit the character via delegate
    private func decodeAndEmit(_ code: UInt8, confidence: Float) {
        lastCharacterConfidence = confidence

        // Apply squelch - suppress output if signal strength is below threshold
        guard signalStrength >= effectiveSquelchLevel else { return }

        // Apply confidence threshold
        guard confidence >= minCharacterConfidence else { return }

        if let character = baudotCodec.decode(code) {
            delegate?.demodulator(
                self,
                didDecode: character,
                atFrequency: centerFrequency
            )
        }
        // Shift codes (LTRS/FIGS) return nil but update codec state
    }

    // MARK: - Control

    /// Reset the demodulator state
    public func reset() {
        state = .waitingForStart
        sampleBuffer.removeAll(keepingCapacity: true)
        analysisWindow.removeAll(keepingCapacity: true)
        correlationHistory.removeAll(keepingCapacity: true)
        markFilter.reset()
        spaceFilter.reset()
        bandpassFilter.reset()
        baudotCodec.reset()
        _signalDetected = false
        agcGain = 1.0
        noiseFloor = 0.1
        lastCharacterConfidence = 0

        // Reset AFC state
        frequencyCorrection = 0
        afcBlockCounter = 0
    }

    /// Tune to a different center frequency
    /// - Parameter frequency: New mark frequency in Hz
    public func tune(to frequency: Double) {
        configuration = configuration.withCenterFrequency(frequency)

        markFilter = GoertzelFilter(
            frequency: configuration.markFrequency,
            sampleRate: configuration.sampleRate,
            blockSize: goertzelWindowSize
        )

        spaceFilter = GoertzelFilter(
            frequency: configuration.spaceFrequency,
            sampleRate: configuration.sampleRate,
            blockSize: goertzelWindowSize
        )

        bandpassFilter = BandpassFilter(
            markFrequency: configuration.markFrequency,
            spaceFrequency: configuration.spaceFrequency,
            margin: 75.0,
            sampleRate: configuration.sampleRate
        )

        reset()
    }

    /// Get the current Baudot shift state
    public var currentShiftState: BaudotCodec.ShiftState {
        baudotCodec.currentShift
    }
}

// MARK: - Convenience Extensions

extension FSKDemodulator {

    /// Create a demodulator with a specific center frequency
    /// - Parameters:
    ///   - centerFrequency: Mark frequency in Hz
    ///   - baseConfiguration: Base configuration to modify
    /// - Returns: New demodulator configured for the specified frequency
    public static func withCenterFrequency(
        _ centerFrequency: Double,
        baseConfiguration: RTTYConfiguration = .standard
    ) -> FSKDemodulator {
        let config = baseConfiguration.withCenterFrequency(centerFrequency)
        return FSKDemodulator(configuration: config)
    }
}
