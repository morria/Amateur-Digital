//
//  FSKModulator.swift
//  DigiModesCore
//
//  FSK modulator for RTTY: converts Baudot codes to audio samples
//

import Foundation

/// FSK Modulator for RTTY transmission
///
/// Converts Baudot codes to FSK audio samples using phase-continuous
/// tone generation. Each character consists of:
/// - 1 start bit (space frequency)
/// - 5 data bits (LSB first, mark=1, space=0)
/// - 1.5 stop bits (mark frequency)
public struct FSKModulator {

    // MARK: - Properties

    private let configuration: RTTYConfiguration
    private var sineGenerator: SineGenerator
    private let baudotCodec: BaudotCodec

    /// Number of samples per bit
    public var samplesPerBit: Int {
        configuration.samplesPerBit
    }

    /// Number of samples for stop bits (1.5 bits)
    public var samplesPerStopBits: Int {
        Int(1.5 * Double(configuration.samplesPerBit))
    }

    // MARK: - Initialization

    /// Create an FSK modulator
    /// - Parameter configuration: RTTY configuration (frequencies, baud rate, etc.)
    public init(configuration: RTTYConfiguration = .standard) {
        self.configuration = configuration
        self.sineGenerator = SineGenerator(
            frequency: configuration.markFrequency,
            sampleRate: configuration.sampleRate
        )
        self.baudotCodec = BaudotCodec()
    }

    // MARK: - Modulation

    /// Generate mark tone (logic 1) samples
    /// - Parameter count: Number of samples
    /// - Returns: Audio samples
    public mutating func generateMark(count: Int) -> [Float] {
        sineGenerator.setFrequency(configuration.markFrequency)
        return sineGenerator.generate(count: count)
    }

    /// Generate space tone (logic 0) samples
    /// - Parameter count: Number of samples
    /// - Returns: Audio samples
    public mutating func generateSpace(count: Int) -> [Float] {
        sineGenerator.setFrequency(configuration.spaceFrequency)
        return sineGenerator.generate(count: count)
    }

    /// Generate idle tone (continuous mark)
    /// - Parameter duration: Duration in seconds
    /// - Returns: Audio samples
    public mutating func generateIdle(duration: Double) -> [Float] {
        let count = Int(duration * configuration.sampleRate)
        return generateMark(count: count)
    }

    /// Generate idle tone for specified number of bit periods
    /// - Parameter bits: Number of bit periods
    /// - Returns: Audio samples
    public mutating func generateIdle(bits: Int) -> [Float] {
        return generateMark(count: bits * samplesPerBit)
    }

    /// Modulate a single Baudot code to FSK audio
    ///
    /// Character framing:
    /// - 1 start bit (space)
    /// - 5 data bits (LSB first)
    /// - 1.5 stop bits (mark)
    ///
    /// - Parameter code: 5-bit Baudot code
    /// - Returns: Audio samples for the complete character
    public mutating func modulateCode(_ code: UInt8) -> [Float] {
        var samples = [Float]()
        samples.reserveCapacity(Int(7.5 * Double(samplesPerBit)))

        // Start bit (1 bit of space)
        samples.append(contentsOf: generateSpace(count: samplesPerBit))

        // 5 data bits, LSB first
        for bitIndex in 0..<5 {
            let bit = (code >> bitIndex) & 0x01
            if bit == 1 {
                samples.append(contentsOf: generateMark(count: samplesPerBit))
            } else {
                samples.append(contentsOf: generateSpace(count: samplesPerBit))
            }
        }

        // Stop bits (1.5 bits of mark)
        samples.append(contentsOf: generateMark(count: samplesPerStopBits))

        return samples
    }

    /// Modulate multiple Baudot codes to FSK audio
    /// - Parameter codes: Array of 5-bit Baudot codes
    /// - Returns: Audio samples for all characters
    public mutating func modulateCodes(_ codes: [UInt8]) -> [Float] {
        var samples = [Float]()
        let samplesPerChar = Int(7.5 * Double(samplesPerBit))
        samples.reserveCapacity(codes.count * samplesPerChar)

        for code in codes {
            samples.append(contentsOf: modulateCode(code))
        }

        return samples
    }

    /// Encode and modulate text to FSK audio
    ///
    /// Converts text to Baudot codes (handling shift states),
    /// then modulates to FSK audio samples.
    ///
    /// - Parameter text: Text to encode and modulate
    /// - Returns: Audio samples
    public mutating func modulateText(_ text: String) -> [Float] {
        let codes = baudotCodec.encodeWithPreamble(text)
        return modulateCodes(codes)
    }

    /// Encode and modulate text with idle periods
    ///
    /// Adds idle (mark) periods before and after the message
    /// for receiver synchronization.
    ///
    /// - Parameters:
    ///   - text: Text to encode and modulate
    ///   - preambleMs: Idle time before message in milliseconds (default: 100ms)
    ///   - postambleMs: Idle time after message in milliseconds (default: 50ms)
    /// - Returns: Audio samples
    public mutating func modulateTextWithIdle(
        _ text: String,
        preambleMs: Double = 100,
        postambleMs: Double = 50
    ) -> [Float] {
        var samples = [Float]()

        // Preamble idle
        let preambleSamples = Int(preambleMs / 1000.0 * configuration.sampleRate)
        samples.append(contentsOf: generateMark(count: preambleSamples))

        // Message
        samples.append(contentsOf: modulateText(text))

        // Postamble idle
        let postambleSamples = Int(postambleMs / 1000.0 * configuration.sampleRate)
        samples.append(contentsOf: generateMark(count: postambleSamples))

        return samples
    }

    // MARK: - Control

    /// Reset the modulator state
    ///
    /// Resets both the sine generator phase and Baudot codec shift state.
    public mutating func reset() {
        sineGenerator.reset()
        baudotCodec.reset()
    }

    /// Get the current Baudot shift state
    public var currentShiftState: BaudotCodec.ShiftState {
        baudotCodec.currentShift
    }
}

// MARK: - Convenience Extensions

extension FSKModulator {

    /// Create a modulator with a specific center frequency
    ///
    /// Useful for multi-channel operation where each channel
    /// transmits at a different audio frequency.
    ///
    /// - Parameters:
    ///   - centerFrequency: Mark frequency in Hz
    ///   - baseConfiguration: Base configuration to modify
    /// - Returns: New modulator configured for the specified frequency
    public static func withCenterFrequency(
        _ centerFrequency: Double,
        baseConfiguration: RTTYConfiguration = .standard
    ) -> FSKModulator {
        let config = baseConfiguration.withCenterFrequency(centerFrequency)
        return FSKModulator(configuration: config)
    }
}
