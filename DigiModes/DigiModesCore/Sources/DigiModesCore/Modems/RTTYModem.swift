//
//  RTTYModem.swift
//  DigiModesCore
//
//  High-level RTTY modem combining encoding and decoding
//

import Foundation

/// Delegate protocol for receiving RTTY modem events
public protocol RTTYModemDelegate: AnyObject {
    /// Called when a character has been decoded
    /// - Parameters:
    ///   - modem: The modem that decoded the character
    ///   - character: The decoded ASCII character
    ///   - frequency: The center frequency where the character was decoded
    func modem(
        _ modem: RTTYModem,
        didDecode character: Character,
        atFrequency frequency: Double
    )

    /// Called when signal detection state changes
    /// - Parameters:
    ///   - modem: The modem
    ///   - detected: Whether a valid RTTY signal is detected
    ///   - frequency: The center frequency of detection
    func modem(
        _ modem: RTTYModem,
        signalDetected detected: Bool,
        atFrequency frequency: Double
    )
}

/// High-level RTTY modem combining FSK modulation and demodulation
///
/// Provides a unified interface for RTTY transmission and reception:
/// - TX: `encode(text:)` converts text to audio samples
/// - RX: `process(samples:)` decodes audio to characters via delegate
///
/// Example usage:
/// ```swift
/// let modem = RTTYModem()
/// modem.delegate = self
///
/// // Transmit
/// let audioSamples = modem.encode(text: "CQ CQ CQ DE W1AW K")
/// audioEngine.play(audioSamples)
///
/// // Receive
/// modem.process(samples: incomingAudio)
/// // Characters arrive via delegate callbacks
/// ```
public final class RTTYModem {

    // MARK: - Properties

    private var modulator: FSKModulator
    private let demodulator: FSKDemodulator
    private let configuration: RTTYConfiguration

    /// Delegate for receiving decoded characters and signal events
    public weak var delegate: RTTYModemDelegate?

    /// Current signal strength (0.0 to 1.0)
    public var signalStrength: Float {
        demodulator.signalStrength
    }

    /// Whether a valid RTTY signal is currently detected
    public var isSignalDetected: Bool {
        demodulator.signalDetected
    }

    /// Current center (mark) frequency
    public var centerFrequency: Double {
        demodulator.centerFrequency
    }

    /// Current Baudot shift state (letters or figures)
    public var shiftState: BaudotCodec.ShiftState {
        demodulator.currentShiftState
    }

    /// The RTTY configuration
    public var currentConfiguration: RTTYConfiguration {
        configuration
    }

    // MARK: - Initialization

    /// Create an RTTY modem
    /// - Parameter configuration: RTTY configuration (default: standard 45.45 baud, 170 Hz shift)
    public init(configuration: RTTYConfiguration = .standard) {
        self.configuration = configuration
        self.modulator = FSKModulator(configuration: configuration)
        self.demodulator = FSKDemodulator(configuration: configuration)

        // Forward demodulator delegate events
        demodulator.delegate = self
    }

    // MARK: - Transmission (TX)

    /// Encode text to RTTY audio samples
    ///
    /// Converts the text to Baudot codes and generates FSK audio.
    /// The output can be played through an audio device for transmission.
    ///
    /// - Parameter text: Text to encode (will be uppercased)
    /// - Returns: Audio samples in the range [-1.0, 1.0]
    public func encode(text: String) -> [Float] {
        return modulator.modulateText(text)
    }

    /// Encode text with idle periods for synchronization
    ///
    /// Adds mark tone (idle) before and after the message to help
    /// receivers synchronize and detect the transmission.
    ///
    /// - Parameters:
    ///   - text: Text to encode
    ///   - preambleMs: Idle time before message in milliseconds (default: 100)
    ///   - postambleMs: Idle time after message in milliseconds (default: 50)
    /// - Returns: Audio samples
    public func encodeWithIdle(
        text: String,
        preambleMs: Double = 100,
        postambleMs: Double = 50
    ) -> [Float] {
        return modulator.modulateTextWithIdle(
            text,
            preambleMs: preambleMs,
            postambleMs: postambleMs
        )
    }

    /// Generate idle tone (continuous mark)
    ///
    /// Useful for keeping the carrier active between messages.
    ///
    /// - Parameter duration: Duration in seconds
    /// - Returns: Audio samples
    public func generateIdle(duration: Double) -> [Float] {
        return modulator.generateIdle(duration: duration)
    }

    // MARK: - Reception (RX)

    /// Process incoming audio samples
    ///
    /// Decodes FSK audio to characters. Decoded characters are
    /// delivered via the delegate's `modem(_:didDecode:atFrequency:)` method.
    ///
    /// - Parameter samples: Audio samples to process
    public func process(samples: [Float]) {
        demodulator.process(samples: samples)
    }

    // MARK: - Control

    /// Reset the modem state
    ///
    /// Resets both modulator and demodulator, clearing any partial
    /// character state and signal detection history.
    public func reset() {
        modulator.reset()
        demodulator.reset()
    }

    /// Tune to a different center frequency
    ///
    /// Changes the mark/space frequencies for both TX and RX.
    /// The shift (distance between mark and space) remains the same.
    ///
    /// - Parameter frequency: New mark frequency in Hz
    public func tune(to frequency: Double) {
        let newConfig = configuration.withCenterFrequency(frequency)
        modulator = FSKModulator(configuration: newConfig)
        demodulator.tune(to: frequency)
    }
}

// MARK: - FSKDemodulatorDelegate

extension RTTYModem: FSKDemodulatorDelegate {
    public func demodulator(
        _ demodulator: FSKDemodulator,
        didDecode character: Character,
        atFrequency frequency: Double
    ) {
        delegate?.modem(self, didDecode: character, atFrequency: frequency)
    }

    public func demodulator(
        _ demodulator: FSKDemodulator,
        signalDetected detected: Bool,
        atFrequency frequency: Double
    ) {
        delegate?.modem(self, signalDetected: detected, atFrequency: frequency)
    }
}

// MARK: - Convenience Extensions

extension RTTYModem {

    /// Create a modem with a specific center frequency
    /// - Parameters:
    ///   - centerFrequency: Mark frequency in Hz
    ///   - baseConfiguration: Base configuration to modify
    /// - Returns: New modem configured for the specified frequency
    public static func withCenterFrequency(
        _ centerFrequency: Double,
        baseConfiguration: RTTYConfiguration = .standard
    ) -> RTTYModem {
        let config = baseConfiguration.withCenterFrequency(centerFrequency)
        return RTTYModem(configuration: config)
    }

    /// Create a modem with wider shift for poor conditions
    /// - Parameter shift: Shift in Hz (425 or 850 common)
    /// - Returns: New modem with wider shift
    public static func withWideShift(_ shift: Double = 425) -> RTTYModem {
        let config = RTTYConfiguration.standard.withShift(shift)
        return RTTYModem(configuration: config)
    }
}
