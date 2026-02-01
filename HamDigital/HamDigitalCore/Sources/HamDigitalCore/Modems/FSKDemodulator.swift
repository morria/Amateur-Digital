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

/// FSK Demodulator state machine states
public enum DemodulatorState: Equatable {
    case waitingForStart
    case inStartBit(samplesProcessed: Int)
    case receivingData(bit: Int, samplesProcessed: Int, accumulator: UInt8)
    case inStopBits(samplesProcessed: Int)
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
public final class FSKDemodulator {

    // MARK: - Properties

    private var configuration: RTTYConfiguration
    private var markFilter: GoertzelFilter
    private var spaceFilter: GoertzelFilter
    private let baudotCodec: BaudotCodec

    /// Current state machine state
    public private(set) var state: DemodulatorState = .waitingForStart

    /// Delegate for receiving decoded characters
    public weak var delegate: FSKDemodulatorDelegate?

    /// Block size for Goertzel analysis (samples per bit / 4 for 4 measurements per bit)
    private let analysisBlockSize: Int

    /// Samples accumulated for current analysis block
    private var sampleBuffer: [Float] = []

    /// Correlation history for signal detection (smoothing)
    private var correlationHistory: [Float] = []
    private let correlationHistorySize = 8

    /// Threshold for mark/space decision
    private let correlationThreshold: Float = 0.2

    /// Signal detection state
    private var _signalDetected: Bool = false
    public var signalDetected: Bool {
        _signalDetected
    }

    /// Squelch level (0.0-1.0). Characters below this signal strength are suppressed.
    public var squelchLevel: Float = 0.3

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

        // Block size = 1/4 of samples per bit for 4 measurements per bit
        self.analysisBlockSize = max(64, configuration.samplesPerBit / 4)

        self.markFilter = GoertzelFilter(
            frequency: configuration.markFrequency,
            sampleRate: configuration.sampleRate,
            blockSize: analysisBlockSize
        )

        self.spaceFilter = GoertzelFilter(
            frequency: configuration.spaceFrequency,
            sampleRate: configuration.sampleRate,
            blockSize: analysisBlockSize
        )
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
        sampleBuffer.append(sample)

        // When we have enough samples for analysis
        if sampleBuffer.count >= analysisBlockSize {
            let correlation = analyzeBlock()
            updateCorrelationHistory(correlation)
            updateSignalDetection()
            processStateMachine(correlation: correlation)
            sampleBuffer.removeAll(keepingCapacity: true)
        }
    }

    /// Analyze the current sample buffer and return mark/space correlation
    /// - Returns: Correlation value: positive = mark, negative = space
    private func analyzeBlock() -> Float {
        let markPower = markFilter.processBlock(sampleBuffer)
        let spacePower = spaceFilter.processBlock(sampleBuffer)

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
        if correlationHistory.count > correlationHistorySize {
            correlationHistory.removeFirst()
        }
    }

    /// Update signal detection state
    private func updateSignalDetection() {
        let avgStrength = signalStrength
        let newDetected = avgStrength > 0.3

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
        let samplesPerBlock = analysisBlockSize
        let samplesPerBit = configuration.samplesPerBit
        let samplesPerHalfBit = samplesPerBit / 2

        switch state {
        case .waitingForStart:
            // Looking for transition from mark to space (start of start bit)
            if correlation < -correlationThreshold {
                // Detected space - could be start bit
                state = .inStartBit(samplesProcessed: samplesPerBlock)
            }

        case .inStartBit(let samplesProcessed):
            let newSamples = samplesProcessed + samplesPerBlock

            // Verify we're still in space for the start bit
            if correlation > correlationThreshold {
                // False start - go back to waiting
                state = .waitingForStart
            } else if newSamples >= samplesPerBit {
                // Start bit complete, move to data bits
                state = .receivingData(bit: 0, samplesProcessed: 0, accumulator: 0)
            } else {
                state = .inStartBit(samplesProcessed: newSamples)
            }

        case .receivingData(let bit, let samplesProcessed, var accumulator):
            let newSamples = samplesProcessed + samplesPerBlock

            // Sample at center of bit
            if samplesProcessed < samplesPerHalfBit && newSamples >= samplesPerHalfBit {
                // This is the center sample - make decision
                if correlation > correlationThreshold {
                    // Mark = 1
                    accumulator |= (1 << bit)
                }
                // Space = 0 (already 0 in accumulator)
            }

            if newSamples >= samplesPerBit {
                // Bit complete
                if bit >= 4 {
                    // All 5 data bits received, move to stop bits
                    state = .inStopBits(samplesProcessed: 0)
                    // Decode and emit the character
                    decodeAndEmit(accumulator)
                } else {
                    // Move to next bit
                    state = .receivingData(
                        bit: bit + 1,
                        samplesProcessed: 0,
                        accumulator: accumulator
                    )
                }
            } else {
                state = .receivingData(
                    bit: bit,
                    samplesProcessed: newSamples,
                    accumulator: accumulator
                )
            }

        case .inStopBits(let samplesProcessed):
            let newSamples = samplesProcessed + samplesPerBlock
            let stopBitSamples = Int(1.5 * Double(samplesPerBit))

            if newSamples >= stopBitSamples {
                // Stop bits complete, ready for next character
                state = .waitingForStart
            } else {
                state = .inStopBits(samplesProcessed: newSamples)
            }
        }
    }

    /// Decode a Baudot code and emit the character via delegate
    private func decodeAndEmit(_ code: UInt8) {
        // Apply squelch - suppress output if signal strength is below threshold
        guard signalStrength >= squelchLevel else { return }

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
        correlationHistory.removeAll(keepingCapacity: true)
        markFilter.reset()
        spaceFilter.reset()
        baudotCodec.reset()
        _signalDetected = false
    }

    /// Tune to a different center frequency
    /// - Parameter frequency: New mark frequency in Hz
    public func tune(to frequency: Double) {
        configuration = configuration.withCenterFrequency(frequency)

        markFilter = GoertzelFilter(
            frequency: configuration.markFrequency,
            sampleRate: configuration.sampleRate,
            blockSize: analysisBlockSize
        )

        spaceFilter = GoertzelFilter(
            frequency: configuration.spaceFrequency,
            sampleRate: configuration.sampleRate,
            blockSize: analysisBlockSize
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
