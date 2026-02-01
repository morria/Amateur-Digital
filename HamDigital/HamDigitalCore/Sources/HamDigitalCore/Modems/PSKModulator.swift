//
//  PSKModulator.swift
//  HamDigitalCore
//
//  PSK modulator: converts text to PSK audio samples (BPSK/QPSK)
//

import Foundation

/// PSK Modulator for transmission
///
/// Converts text to PSK (Phase Shift Keying) audio samples.
/// Supports both BPSK (2-phase) and QPSK (4-phase) modulation.
///
/// BPSK modulation:
/// - Bit 0: No phase change (same phase as previous symbol)
/// - Bit 1: 180-degree phase reversal
///
/// QPSK modulation (Gray code mapping):
/// - 00: No phase change (0°)
/// - 01: 90-degree phase shift
/// - 11: 180-degree phase shift
/// - 10: 270-degree phase shift
///
/// Example usage:
/// ```swift
/// var modulator = PSKModulator(configuration: .psk31)
/// let samples = modulator.modulateText("CQ CQ DE W1AW")
/// // Play samples through audio output
/// ```
public struct PSKModulator {

    // MARK: - Properties

    private let configuration: PSKConfiguration
    private var sineGenerator: SineGenerator
    private let varicodeCodec: VaricodeCodec

    /// Current carrier phase
    private var currentPhase: Double = 0

    /// Number of samples per symbol
    public var samplesPerSymbol: Int {
        configuration.samplesPerSymbol
    }

    /// Current configuration
    public var currentConfiguration: PSKConfiguration {
        configuration
    }

    // MARK: - Initialization

    /// Create a PSK modulator
    /// - Parameter configuration: PSK configuration (frequency, sample rate, modulation type)
    public init(configuration: PSKConfiguration = .standard) {
        self.configuration = configuration
        self.sineGenerator = SineGenerator(
            frequency: configuration.centerFrequency,
            sampleRate: configuration.sampleRate
        )
        self.varicodeCodec = VaricodeCodec()
    }

    // MARK: - BPSK Modulation

    /// Generate a single BPSK symbol
    ///
    /// - Parameter bit: The bit to transmit (true = phase reversal, false = no change)
    /// - Returns: Audio samples for one symbol period
    public mutating func modulateBPSKSymbol(bit: Bool) -> [Float] {
        var samples = [Float]()
        samples.reserveCapacity(samplesPerSymbol)

        let phaseIncrement = configuration.phaseIncrementPerSample

        if bit {
            // Bit 1: Phase reversal with raised cosine envelope
            let transitionSamples = samplesPerSymbol

            for i in 0..<transitionSamples {
                // Raised cosine envelope for smooth transition
                let t = Double(i) / Double(transitionSamples)
                let envelope = 0.5 * (1.0 - cos(.pi * t))

                // Blend between current phase and reversed phase
                let oldPhaseContribution = (1.0 - envelope) * sin(currentPhase)
                let newPhaseContribution = envelope * sin(currentPhase + .pi)
                let sample = Float(oldPhaseContribution + newPhaseContribution)

                samples.append(sample)
                currentPhase += phaseIncrement

                // Keep phase in [0, 2*pi)
                if currentPhase >= 2.0 * .pi {
                    currentPhase -= 2.0 * .pi
                }
            }

            // Complete the phase reversal
            currentPhase += .pi
            if currentPhase >= 2.0 * .pi {
                currentPhase -= 2.0 * .pi
            }
        } else {
            // Bit 0: No phase change - continuous carrier
            for _ in 0..<samplesPerSymbol {
                let sample = Float(sin(currentPhase))
                samples.append(sample)
                currentPhase += phaseIncrement

                if currentPhase >= 2.0 * .pi {
                    currentPhase -= 2.0 * .pi
                }
            }
        }

        return samples
    }

    // MARK: - QPSK Modulation

    /// Convert dibit to phase shift using Gray code mapping
    ///
    /// Gray code ensures adjacent symbols differ by only one bit,
    /// minimizing bit errors when phase detection is off by one quadrant.
    ///
    /// - Parameters:
    ///   - b1: First bit (MSB)
    ///   - b0: Second bit (LSB)
    /// - Returns: Phase shift in radians
    private func dibitToPhaseShift(_ b1: Bool, _ b0: Bool) -> Double {
        switch (b1, b0) {
        case (false, false): return 0              // 00 → 0° (no change)
        case (false, true):  return .pi / 2        // 01 → 90°
        case (true, true):   return .pi            // 11 → 180°
        case (true, false):  return 3 * .pi / 2    // 10 → 270°
        }
    }

    /// Generate a single QPSK symbol
    ///
    /// - Parameters:
    ///   - b1: First bit (MSB)
    ///   - b0: Second bit (LSB)
    /// - Returns: Audio samples for one symbol period
    public mutating func modulateQPSKSymbol(b1: Bool, b0: Bool) -> [Float] {
        var samples = [Float]()
        samples.reserveCapacity(samplesPerSymbol)

        let phaseIncrement = configuration.phaseIncrementPerSample
        let phaseShift = dibitToPhaseShift(b1, b0)

        if phaseShift != 0 {
            // Phase transition with raised cosine envelope
            let transitionSamples = samplesPerSymbol
            let targetPhase = currentPhase + phaseShift

            for i in 0..<transitionSamples {
                // Raised cosine envelope for smooth transition
                let t = Double(i) / Double(transitionSamples)
                let envelope = 0.5 * (1.0 - cos(.pi * t))

                // Blend between current phase and new phase
                let oldPhaseContribution = (1.0 - envelope) * sin(currentPhase)
                let newPhaseContribution = envelope * sin(targetPhase)
                let sample = Float(oldPhaseContribution + newPhaseContribution)

                samples.append(sample)
                currentPhase += phaseIncrement

                // Keep phase in [0, 2*pi)
                while currentPhase >= 2.0 * .pi {
                    currentPhase -= 2.0 * .pi
                }
            }

            // Complete the phase shift
            currentPhase += phaseShift
            while currentPhase >= 2.0 * .pi {
                currentPhase -= 2.0 * .pi
            }
        } else {
            // No phase change - continuous carrier
            for _ in 0..<samplesPerSymbol {
                let sample = Float(sin(currentPhase))
                samples.append(sample)
                currentPhase += phaseIncrement

                if currentPhase >= 2.0 * .pi {
                    currentPhase -= 2.0 * .pi
                }
            }
        }

        return samples
    }

    // MARK: - Generic Symbol Modulation

    /// Modulate a single symbol (BPSK or QPSK based on configuration)
    ///
    /// For BPSK, only the first bit is used.
    /// For QPSK, both bits are used.
    ///
    /// - Parameter bit: For BPSK: the bit to transmit
    /// - Returns: Audio samples for one symbol period
    public mutating func modulateSymbol(bit: Bool) -> [Float] {
        if configuration.modulationType == .bpsk {
            return modulateBPSKSymbol(bit: bit)
        } else {
            // For QPSK, this method treats a single bit as 00 or 11
            // Use modulateBits for proper QPSK encoding
            return modulateQPSKSymbol(b1: bit, b0: bit)
        }
    }

    // MARK: - Bit Array Modulation

    /// Modulate an array of bits to PSK audio
    /// - Parameter bits: Array of bits to modulate
    /// - Returns: Audio samples
    public mutating func modulateBits(_ bits: [Bool]) -> [Float] {
        var samples = [Float]()

        if configuration.modulationType == .bpsk {
            samples.reserveCapacity(bits.count * samplesPerSymbol)
            for bit in bits {
                samples.append(contentsOf: modulateBPSKSymbol(bit: bit))
            }
        } else {
            // QPSK: process bits in pairs (dibits)
            let symbolCount = (bits.count + 1) / 2  // Round up
            samples.reserveCapacity(symbolCount * samplesPerSymbol)

            var index = 0
            while index < bits.count {
                let b1 = bits[index]
                let b0 = (index + 1 < bits.count) ? bits[index + 1] : false
                samples.append(contentsOf: modulateQPSKSymbol(b1: b1, b0: b0))
                index += 2
            }
        }

        return samples
    }

    // MARK: - Text Modulation

    /// Encode and modulate text to PSK audio
    ///
    /// Converts text to Varicode, then modulates to PSK audio samples.
    ///
    /// - Parameter text: Text to encode and modulate
    /// - Returns: Audio samples
    public mutating func modulateText(_ text: String) -> [Float] {
        let bits = varicodeCodec.encode(text)
        return modulateBits(bits)
    }

    /// Generate idle (continuous carrier with no data)
    ///
    /// Idle in PSK is a series of zero bits (no phase changes).
    ///
    /// - Parameter duration: Duration in seconds
    /// - Returns: Audio samples
    public mutating func generateIdle(duration: Double) -> [Float] {
        let symbolCount = Int(duration * configuration.baudRate)
        let bits = [Bool](repeating: false, count: symbolCount)
        return modulateBits(bits)
    }

    /// Generate idle for specified number of symbols
    /// - Parameter symbols: Number of idle symbols
    /// - Returns: Audio samples
    public mutating func generateIdle(symbols: Int) -> [Float] {
        let bits = [Bool](repeating: false, count: symbols)
        return modulateBits(bits)
    }

    /// Encode and modulate text with envelope shaping
    ///
    /// Adds smooth ramp-up and ramp-down to prevent key clicks,
    /// plus idle periods for synchronization.
    ///
    /// - Parameters:
    ///   - text: Text to encode and modulate
    ///   - preambleMs: Idle time before message in milliseconds (default: 100)
    ///   - postambleMs: Idle time after message in milliseconds (default: 50)
    /// - Returns: Audio samples with smooth envelope
    public mutating func modulateTextWithEnvelope(
        _ text: String,
        preambleMs: Double = 100,
        postambleMs: Double = 50
    ) -> [Float] {
        var samples = [Float]()

        // Calculate preamble/postamble in symbols
        let preambleSymbols = max(4, Int(preambleMs / 1000.0 * configuration.baudRate))
        let postambleSymbols = max(2, Int(postambleMs / 1000.0 * configuration.baudRate))

        // Ramp-up envelope (first few symbols)
        let rampSymbols = 4
        let rampSamples = rampSymbols * samplesPerSymbol

        // Generate preamble (idle)
        var preamble = generateIdle(symbols: preambleSymbols)

        // Apply ramp-up to start of preamble
        for i in 0..<min(rampSamples, preamble.count) {
            let t = Double(i) / Double(rampSamples)
            let envelope = Float(0.5 * (1.0 - cos(.pi * t)))
            preamble[i] *= envelope
        }

        samples.append(contentsOf: preamble)

        // Generate message
        let message = modulateText(text)
        samples.append(contentsOf: message)

        // Generate postamble (idle)
        var postamble = generateIdle(symbols: postambleSymbols)

        // Apply ramp-down to end of postamble
        let rampDownStart = max(0, postamble.count - rampSamples)
        for i in rampDownStart..<postamble.count {
            let t = Double(i - rampDownStart) / Double(rampSamples)
            let envelope = Float(0.5 * (1.0 + cos(.pi * t)))
            postamble[i] *= envelope
        }

        samples.append(contentsOf: postamble)

        return samples
    }

    // MARK: - Control

    /// Reset the modulator state
    public mutating func reset() {
        currentPhase = 0
        sineGenerator.reset()
        varicodeCodec.reset()
    }

    /// Get the current carrier phase
    public var phase: Double {
        currentPhase
    }
}

// MARK: - Convenience Extensions

extension PSKModulator {

    /// Create a modulator with a specific center frequency
    /// - Parameters:
    ///   - centerFrequency: Center frequency in Hz
    ///   - baseConfiguration: Base configuration to modify
    /// - Returns: New modulator configured for the specified frequency
    public static func withCenterFrequency(
        _ centerFrequency: Double,
        baseConfiguration: PSKConfiguration = .standard
    ) -> PSKModulator {
        let config = baseConfiguration.withCenterFrequency(centerFrequency)
        return PSKModulator(configuration: config)
    }

    /// Create PSK31 modulator (BPSK, 31.25 baud)
    public static func psk31(centerFrequency: Double = 1000.0) -> PSKModulator {
        PSKModulator(configuration: PSKConfiguration.psk31.withCenterFrequency(centerFrequency))
    }

    /// Create BPSK63 modulator (BPSK, 62.5 baud)
    public static func bpsk63(centerFrequency: Double = 1000.0) -> PSKModulator {
        PSKModulator(configuration: PSKConfiguration.bpsk63.withCenterFrequency(centerFrequency))
    }

    /// Create QPSK31 modulator (QPSK, 31.25 baud)
    public static func qpsk31(centerFrequency: Double = 1000.0) -> PSKModulator {
        PSKModulator(configuration: PSKConfiguration.qpsk31.withCenterFrequency(centerFrequency))
    }

    /// Create QPSK63 modulator (QPSK, 62.5 baud)
    public static func qpsk63(centerFrequency: Double = 1000.0) -> PSKModulator {
        PSKModulator(configuration: PSKConfiguration.qpsk63.withCenterFrequency(centerFrequency))
    }
}

// MARK: - Backward Compatibility

/// Type alias for backward compatibility with PSK31-specific code
public typealias PSK31Modulator = PSKModulator
