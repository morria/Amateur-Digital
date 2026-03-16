//
//  JS8CallModem.swift
//  AmateurDigitalCore
//
//  High-level unified JS8Call TX/RX interface, following CWModem/PSKModem pattern.
//

import Foundation

// MARK: - Delegate

public protocol JS8CallModemDelegate: AnyObject {
    func modem(_ modem: JS8CallModem, didDecode frame: JS8CallFrame)
    func modem(_ modem: JS8CallModem, signalDetected detected: Bool, count: Int)
}

// MARK: - Modem

public final class JS8CallModem {

    public weak var delegate: JS8CallModemDelegate?
    public private(set) var currentConfiguration: JS8CallConfiguration

    private var modulator: JS8CallModulator
    private let demodulator: JS8CallDemodulator

    public init(configuration: JS8CallConfiguration = .standard) {
        self.currentConfiguration = configuration
        self.modulator = JS8CallModulator(configuration: configuration)
        self.demodulator = JS8CallDemodulator(configuration: configuration)
        self.demodulator.delegate = self
    }

    // MARK: - TX

    /// Encode text into JS8Call audio samples at the external sample rate.
    public func encode(text: String, frameType: Int = 0) -> [Float] {
        modulator.modulateText(text, frameType: frameType)
    }

    /// Encode with leading/trailing silence.
    public func encodeWithEnvelope(
        text: String,
        frameType: Int = 0,
        preambleMs: Double = 0,
        postambleMs: Double = 200
    ) -> [Float] {
        modulator.modulateTextWithEnvelope(text, frameType: frameType, preambleMs: preambleMs, postambleMs: postambleMs)
    }

    // MARK: - RX

    /// Process incoming audio samples (48 kHz Float).
    public func process(samples: [Float]) {
        demodulator.process(samples: samples)
    }

    // MARK: - State

    public var isSignalDetected: Bool { demodulator.signalDetected }

    // MARK: - Control

    public func reset() {
        modulator.reset()
        demodulator.reset()
    }

    public func tune(to frequency: Double) {
        currentConfiguration = currentConfiguration.withCarrierFrequency(frequency)
        modulator = JS8CallModulator(configuration: currentConfiguration)
        demodulator.tune(to: frequency)
    }

    // MARK: - Factory

    public static func normal(carrierFrequency: Double = 1000.0) -> JS8CallModem {
        JS8CallModem(configuration: .normal.withCarrierFrequency(carrierFrequency))
    }
    public static func fast(carrierFrequency: Double = 1000.0) -> JS8CallModem {
        JS8CallModem(configuration: .fast.withCarrierFrequency(carrierFrequency))
    }
    public static func slow(carrierFrequency: Double = 1000.0) -> JS8CallModem {
        JS8CallModem(configuration: .slow.withCarrierFrequency(carrierFrequency))
    }
}

// MARK: - Demodulator Delegate Bridge

extension JS8CallModem: JS8CallDemodulatorDelegate {
    public func demodulator(_ demodulator: JS8CallDemodulator, didDecode frame: JS8CallFrame) {
        delegate?.modem(self, didDecode: frame)
    }
    public func demodulator(_ demodulator: JS8CallDemodulator, signalDetected detected: Bool, count: Int) {
        delegate?.modem(self, signalDetected: detected, count: count)
    }
}
