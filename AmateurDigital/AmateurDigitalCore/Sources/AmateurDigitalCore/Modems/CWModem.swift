//
//  CWModem.swift
//  AmateurDigitalCore
//
//  High-level CW modem combining encoding and decoding
//

import Foundation

/// Delegate protocol for receiving CW modem events
public protocol CWModemDelegate: AnyObject {
    /// Called when a character has been decoded
    func modem(
        _ modem: CWModem,
        didDecode character: Character,
        atFrequency frequency: Double
    )

    /// Called when signal detection state changes
    func modem(
        _ modem: CWModem,
        signalDetected detected: Bool,
        atFrequency frequency: Double
    )
}

/// High-level CW modem combining modulation and demodulation
///
/// Provides a unified interface for CW transmission and reception:
/// - TX: `encode(text:)` converts text to CW audio samples
/// - RX: `process(samples:)` decodes CW audio to characters via delegate
///
/// Example usage:
/// ```swift
/// let modem = CWModem(configuration: .standard)
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
public final class CWModem {

    // MARK: - Properties

    private var modulator: CWModulator
    private let demodulator: CWDemodulator
    private let configuration: CWConfiguration

    /// Delegate for receiving decoded characters and signal events
    public weak var delegate: CWModemDelegate?

    /// Current estimated receive WPM
    public var estimatedWPM: Double {
        demodulator.estimatedWPM
    }

    /// Current signal strength (0.0 to 1.0)
    public var signalStrength: Float {
        demodulator.signalStrength
    }

    /// Whether a CW signal is currently detected
    public var isSignalDetected: Bool {
        demodulator.signalDetected
    }

    /// Current tone frequency (may differ from config due to AFC)
    public var toneFrequency: Double {
        demodulator.toneFrequency
    }

    /// The CW configuration
    public var currentConfiguration: CWConfiguration {
        configuration
    }

    // MARK: - Initialization

    public init(configuration: CWConfiguration = .standard) {
        self.configuration = configuration
        self.modulator = CWModulator(configuration: configuration)
        self.demodulator = CWDemodulator(configuration: configuration)
        demodulator.delegate = self
    }

    // MARK: - Transmission (TX)

    /// Encode text to CW audio samples
    /// - Parameter text: Text to encode (uppercase by ham convention)
    /// - Returns: Audio samples in [-1.0, 1.0]
    public func encode(text: String) -> [Float] {
        return modulator.modulateText(text)
    }

    /// Encode text with leading/trailing silence
    public func encodeWithEnvelope(
        text: String,
        preambleMs: Double = 200,
        postambleMs: Double = 200
    ) -> [Float] {
        return modulator.modulateTextWithEnvelope(text, preambleMs: preambleMs, postambleMs: postambleMs)
    }

    // MARK: - Reception (RX)

    /// Process incoming audio samples
    /// Decoded characters are delivered via delegate callbacks.
    public func process(samples: [Float]) {
        demodulator.process(samples: samples)
    }

    // MARK: - Control

    /// Reset the modem state
    public func reset() {
        modulator.reset()
        demodulator.reset()
    }

    /// Tune to a different tone frequency
    public func tune(to frequency: Double) {
        let newConfig = configuration.withToneFrequency(frequency)
        modulator = CWModulator(configuration: newConfig)
        demodulator.tune(to: frequency)
    }
}

// MARK: - CWDemodulatorDelegate

extension CWModem: CWDemodulatorDelegate {
    public func demodulator(
        _ demodulator: CWDemodulator,
        didDecode character: Character,
        atFrequency frequency: Double
    ) {
        delegate?.modem(self, didDecode: character, atFrequency: frequency)
    }

    public func demodulator(
        _ demodulator: CWDemodulator,
        signalDetected detected: Bool,
        atFrequency frequency: Double
    ) {
        delegate?.modem(self, signalDetected: detected, atFrequency: frequency)
    }
}

// MARK: - Convenience

extension CWModem {
    /// Create a CW modem at standard 20 WPM
    public static func standard(toneFrequency: Double = 700.0) -> CWModem {
        CWModem(configuration: CWConfiguration.standard.withToneFrequency(toneFrequency))
    }

    /// Create a slow CW modem at 13 WPM
    public static func slow(toneFrequency: Double = 700.0) -> CWModem {
        CWModem(configuration: CWConfiguration.slow.withToneFrequency(toneFrequency))
    }

    /// Create a fast CW modem at 30 WPM
    public static func fast(toneFrequency: Double = 700.0) -> CWModem {
        CWModem(configuration: CWConfiguration.fast.withToneFrequency(toneFrequency))
    }
}
