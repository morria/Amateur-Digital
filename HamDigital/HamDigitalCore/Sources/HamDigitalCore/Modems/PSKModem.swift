//
//  PSKModem.swift
//  HamDigitalCore
//
//  High-level PSK modem combining encoding and decoding
//

import Foundation

/// Delegate protocol for receiving PSK modem events
public protocol PSKModemDelegate: AnyObject {
    /// Called when a character has been decoded
    /// - Parameters:
    ///   - modem: The modem that decoded the character
    ///   - character: The decoded ASCII character
    ///   - frequency: The center frequency where the character was decoded
    func modem(
        _ modem: PSKModem,
        didDecode character: Character,
        atFrequency frequency: Double
    )

    /// Called when signal detection state changes
    /// - Parameters:
    ///   - modem: The modem
    ///   - detected: Whether a valid PSK signal is detected
    ///   - frequency: The center frequency of detection
    func modem(
        _ modem: PSKModem,
        signalDetected detected: Bool,
        atFrequency frequency: Double
    )
}

/// High-level PSK modem combining modulation and demodulation
///
/// Provides a unified interface for PSK transmission and reception:
/// - TX: `encode(text:)` converts text to audio samples
/// - RX: `process(samples:)` decodes audio to characters via delegate
///
/// Supports PSK31, BPSK63, QPSK31, and QPSK63 modes.
///
/// Example usage:
/// ```swift
/// let modem = PSKModem(configuration: .psk31)
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
public final class PSKModem {

    // MARK: - Properties

    private var modulator: PSKModulator
    private let demodulator: PSKDemodulator
    private let configuration: PSKConfiguration

    /// Delegate for receiving decoded characters and signal events
    public weak var delegate: PSKModemDelegate?

    /// Current signal strength (0.0 to 1.0)
    public var signalStrength: Float {
        demodulator.signalStrength
    }

    /// Whether a valid PSK signal is currently detected
    public var isSignalDetected: Bool {
        demodulator.signalDetected
    }

    /// Current center frequency
    public var centerFrequency: Double {
        demodulator.centerFrequency
    }

    /// The PSK configuration
    public var currentConfiguration: PSKConfiguration {
        configuration
    }

    /// Human-readable mode name
    public var modeName: String {
        configuration.modeName
    }

    // MARK: - Initialization

    /// Create a PSK modem
    /// - Parameter configuration: PSK configuration (default: PSK31)
    public init(configuration: PSKConfiguration = .standard) {
        self.configuration = configuration
        self.modulator = PSKModulator(configuration: configuration)
        self.demodulator = PSKDemodulator(configuration: configuration)

        // Forward demodulator delegate events
        demodulator.delegate = self
    }

    // MARK: - Transmission (TX)

    /// Encode text to PSK audio samples
    ///
    /// Converts the text to Varicode and generates PSK audio.
    /// The output can be played through an audio device for transmission.
    ///
    /// - Parameter text: Text to encode (case-sensitive)
    /// - Returns: Audio samples in the range [-1.0, 1.0]
    public func encode(text: String) -> [Float] {
        return modulator.modulateText(text)
    }

    /// Encode text with envelope shaping for clean transmission
    ///
    /// Adds smooth ramp-up and ramp-down to prevent splatter,
    /// plus idle periods for receiver synchronization.
    ///
    /// - Parameters:
    ///   - text: Text to encode
    ///   - preambleMs: Idle time before message in milliseconds (default: 100)
    ///   - postambleMs: Idle time after message in milliseconds (default: 50)
    /// - Returns: Audio samples with smooth envelope
    public func encodeWithEnvelope(
        text: String,
        preambleMs: Double = 100,
        postambleMs: Double = 50
    ) -> [Float] {
        return modulator.modulateTextWithEnvelope(
            text,
            preambleMs: preambleMs,
            postambleMs: postambleMs
        )
    }

    /// Generate idle tone (continuous carrier)
    ///
    /// PSK idle is a continuous unmodulated carrier.
    /// Useful for keeping the transmitter keyed between messages.
    ///
    /// - Parameter duration: Duration in seconds
    /// - Returns: Audio samples
    public func generateIdle(duration: Double) -> [Float] {
        return modulator.generateIdle(duration: duration)
    }

    // MARK: - Reception (RX)

    /// Process incoming audio samples
    ///
    /// Decodes PSK audio to characters. Decoded characters are
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
    /// Changes the center frequency for both TX and RX.
    ///
    /// - Parameter frequency: New center frequency in Hz
    public func tune(to frequency: Double) {
        let newConfig = configuration.withCenterFrequency(frequency)
        modulator = PSKModulator(configuration: newConfig)
        demodulator.tune(to: frequency)
    }
}

// MARK: - PSKDemodulatorDelegate

extension PSKModem: PSKDemodulatorDelegate {
    public func demodulator(
        _ demodulator: PSKDemodulator,
        didDecode character: Character,
        atFrequency frequency: Double
    ) {
        delegate?.modem(self, didDecode: character, atFrequency: frequency)
    }

    public func demodulator(
        _ demodulator: PSKDemodulator,
        signalDetected detected: Bool,
        atFrequency frequency: Double
    ) {
        delegate?.modem(self, signalDetected: detected, atFrequency: frequency)
    }
}

// MARK: - Convenience Extensions

extension PSKModem {

    /// Create a modem with a specific center frequency
    /// - Parameters:
    ///   - centerFrequency: Center frequency in Hz
    ///   - baseConfiguration: Base configuration to modify
    /// - Returns: New modem configured for the specified frequency
    public static func withCenterFrequency(
        _ centerFrequency: Double,
        baseConfiguration: PSKConfiguration = .standard
    ) -> PSKModem {
        let config = baseConfiguration.withCenterFrequency(centerFrequency)
        return PSKModem(configuration: config)
    }

    /// Create PSK31 modem (BPSK, 31.25 baud)
    public static func psk31(centerFrequency: Double = 1000.0) -> PSKModem {
        PSKModem(configuration: PSKConfiguration.psk31.withCenterFrequency(centerFrequency))
    }

    /// Create BPSK63 modem (BPSK, 62.5 baud)
    public static func bpsk63(centerFrequency: Double = 1000.0) -> PSKModem {
        PSKModem(configuration: PSKConfiguration.bpsk63.withCenterFrequency(centerFrequency))
    }

    /// Create QPSK31 modem (QPSK, 31.25 baud)
    public static func qpsk31(centerFrequency: Double = 1000.0) -> PSKModem {
        PSKModem(configuration: PSKConfiguration.qpsk31.withCenterFrequency(centerFrequency))
    }

    /// Create QPSK63 modem (QPSK, 62.5 baud)
    public static func qpsk63(centerFrequency: Double = 1000.0) -> PSKModem {
        PSKModem(configuration: PSKConfiguration.qpsk63.withCenterFrequency(centerFrequency))
    }
}

// MARK: - Backward Compatibility

/// Type alias for backward compatibility with PSK31-specific code
public typealias PSK31Modem = PSKModem

/// Backward compatible delegate protocol
public typealias PSK31ModemDelegate = PSKModemDelegate
