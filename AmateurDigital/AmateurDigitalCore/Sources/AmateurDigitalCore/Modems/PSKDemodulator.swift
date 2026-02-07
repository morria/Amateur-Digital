//
//  PSKDemodulator.swift
//  AmateurDigitalCore
//
//  PSK demodulator: converts audio samples to text (BPSK/QPSK)
//

import Foundation

/// Delegate protocol for receiving demodulated PSK characters
public protocol PSKDemodulatorDelegate: AnyObject {
    /// Called when a character has been decoded
    /// - Parameters:
    ///   - demodulator: The demodulator that decoded the character
    ///   - character: The decoded ASCII character
    ///   - frequency: The center frequency of the demodulator
    func demodulator(
        _ demodulator: PSKDemodulator,
        didDecode character: Character,
        atFrequency frequency: Double
    )

    /// Called when signal detection state changes
    /// - Parameters:
    ///   - demodulator: The demodulator
    ///   - detected: Whether a valid PSK signal is detected
    ///   - frequency: The center frequency of the demodulator
    func demodulator(
        _ demodulator: PSKDemodulator,
        signalDetected detected: Bool,
        atFrequency frequency: Double
    )
}

/// PSK Demodulator for reception
///
/// Converts PSK audio samples to text using IQ (quadrature) demodulation.
/// Supports both BPSK (2-phase) and QPSK (4-phase) demodulation.
///
/// Demodulation approach:
/// 1. Mix signal with local oscillator (I and Q channels)
/// 2. IIR lowpass filter (bandwidth matched to symbol rate)
/// 3. Sample filtered I/Q at symbol boundaries
/// 4. Symbol timing recovery using early-late amplitude comparison
/// 5. Differential phase detection (compare current vs previous symbol)
///    - BPSK: Dot product sign check for 180° detection
///    - QPSK: atan2 phase calculation, quantize to nearest quadrant
/// 6. Varicode decoding to characters
///
/// Example usage:
/// ```swift
/// let demodulator = PSKDemodulator(configuration: .psk31)
/// demodulator.delegate = self
/// demodulator.process(samples: audioBuffer)
/// // Characters arrive via delegate
/// ```
public final class PSKDemodulator {

    // MARK: - Properties

    private var configuration: PSKConfiguration
    private let varicodeCodec: VaricodeCodec

    /// I (in-phase) and Q (quadrature) local oscillator phase
    private var localPhase: Double = 0

    /// IIR lowpass filtered I/Q (baseband signal)
    private var iFiltered: Double = 0
    private var qFiltered: Double = 0

    /// Previous symbol's I and Q values (for differential detection)
    private var prevI: Double = 0
    private var prevQ: Double = 0

    /// Symbol timing recovery
    private var symbolSamples: Int = 0
    private var symbolTimingAdjust: Int = 0
    private var earlyMag: Double = 0
    private var lateMag: Double = 0

    /// On-time I/Q accumulator (middle half of symbol for robust phase estimate)
    private var onTimeAccumI: Double = 0
    private var onTimeAccumQ: Double = 0

    /// Signal detection
    private var signalPower: Double = 0
    private var noisePower: Double = 0.001
    private var _signalDetected: Bool = false

    /// Delegate for receiving decoded characters
    public weak var delegate: PSKDemodulatorDelegate?

    /// Squelch level (0.0-1.0). Characters below this SNR are suppressed.
    public var squelchLevel: Float = 0.3

    /// Center frequency
    public var centerFrequency: Double {
        configuration.centerFrequency
    }

    /// Current signal strength (0.0 to 1.0)
    public var signalStrength: Float {
        let snr = signalPower / max(noisePower, 0.001)
        return Float(min(1.0, snr / 10.0))
    }

    /// Whether a valid PSK signal is currently detected
    public var signalDetected: Bool {
        _signalDetected
    }

    /// Current configuration
    public var currentConfiguration: PSKConfiguration {
        configuration
    }

    // MARK: - Constants

    /// Symbol timing loop gain (controls how fast timing tracks)
    private let timingGain: Double = 0.05

    /// Maximum timing adjustment per symbol (fraction of symbol period)
    private let maxTimingAdjustFraction: Double = 0.125

    // MARK: - Initialization

    /// Create a PSK demodulator
    /// - Parameter configuration: PSK configuration (frequency, sample rate, modulation type)
    public init(configuration: PSKConfiguration = .standard) {
        self.configuration = configuration
        self.varicodeCodec = VaricodeCodec()
    }

    /// IIR filter coefficient, computed from baud rate and sample rate.
    /// Bandwidth is ~3x the baud rate so the filter settles well within
    /// one symbol period even after raised-cosine phase transitions.
    private var filterAlpha: Double {
        2.0 * .pi * (configuration.baudRate * 3.0) / configuration.sampleRate
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
    private func processSample(_ sample: Float) {
        let sampleD = Double(sample)

        // Mix with local oscillator (quadrature demodulation)
        let i = sampleD * cos(localPhase)
        let q = sampleD * -sin(localPhase)

        // Advance local oscillator phase
        localPhase += configuration.phaseIncrementPerSample
        if localPhase >= 2.0 * .pi {
            localPhase -= 2.0 * .pi
        }

        // IIR lowpass filter — bandwidth matched to ~1.5× symbol rate
        let alpha = filterAlpha
        iFiltered += alpha * (i - iFiltered)
        qFiltered += alpha * (q - qFiltered)

        symbolSamples += 1

        let samplesPerSymbol = configuration.samplesPerSymbol
        let quarterSymbol = samplesPerSymbol / 4

        // Record filtered amplitude at 25% and 75% of symbol for timing recovery
        if symbolSamples == quarterSymbol {
            earlyMag = iFiltered * iFiltered + qFiltered * qFiltered
        } else if symbolSamples == 3 * quarterSymbol {
            lateMag = iFiltered * iFiltered + qFiltered * qFiltered
        }

        // Accumulate filtered I/Q over middle half of symbol for robust phase estimate
        if symbolSamples >= quarterSymbol && symbolSamples < 3 * quarterSymbol {
            onTimeAccumI += iFiltered
            onTimeAccumQ += qFiltered
        }

        // Check if we've completed a symbol (with timing adjustment)
        let targetLength = samplesPerSymbol + symbolTimingAdjust
        if symbolSamples >= targetLength {
            processSymbol()
            symbolSamples = 0
            onTimeAccumI = 0
            onTimeAccumQ = 0
        }
    }

    /// Process a complete symbol
    private func processSymbol() {
        // Symbol timing recovery: compare amplitude at 25% vs 75% of symbol.
        // For raised-cosine shaped PSK, amplitude is highest at mid-symbol.
        // If we're sampling late, the late measurement catches a transition dip.
        let timingError = earlyMag - lateMag
        let normalizedError = (earlyMag + lateMag) > 0
            ? timingError / (earlyMag + lateMag)
            : 0

        let maxAdjust = Int(maxTimingAdjustFraction * Double(configuration.samplesPerSymbol))
        let rawAdjust = Int(normalizedError * timingGain * Double(configuration.samplesPerSymbol))
        symbolTimingAdjust = max(-maxAdjust, min(maxAdjust, -rawAdjust))

        // Use accumulated I/Q from middle half of symbol for robust phase estimate
        let currentI = onTimeAccumI
        let currentQ = onTimeAccumQ

        // Update signal detection
        let symbolPower = currentI * currentI + currentQ * currentQ
        updateSignalDetection(symbolPower: symbolPower)

        // Only decode if signal is detected and above squelch
        guard _signalDetected && signalStrength >= squelchLevel else {
            prevI = currentI
            prevQ = currentQ
            return
        }

        if configuration.modulationType == .bpsk {
            decodeBPSKSymbol(currentI: currentI, currentQ: currentQ)
        } else {
            decodeQPSKSymbol(currentI: currentI, currentQ: currentQ)
        }

        // Update previous symbol
        prevI = currentI
        prevQ = currentQ
    }

    /// Decode BPSK symbol using dot product phase detection
    private func decodeBPSKSymbol(currentI: Double, currentQ: Double) {
        // Cross-product to detect phase reversal
        // If phases are same: prevI*currentI + prevQ*currentQ > 0
        // If phases are opposite: prevI*currentI + prevQ*currentQ < 0
        let dotProduct = prevI * currentI + prevQ * currentQ

        // Decode bit (phase reversal = 1, same phase = 0)
        let bit = dotProduct < 0

        // Feed bit to Varicode decoder
        if let char = varicodeCodec.decode(bit: bit) {
            delegate?.demodulator(
                self,
                didDecode: char,
                atFrequency: centerFrequency
            )
        }
    }

    /// Decode QPSK symbol using atan2 phase detection
    private func decodeQPSKSymbol(currentI: Double, currentQ: Double) {
        // Calculate current and previous phases
        let currentPhase = atan2(currentQ, currentI)
        let prevPhase = atan2(prevQ, prevI)

        // Calculate phase difference
        var phaseDiff = currentPhase - prevPhase

        // Normalize to [0, 2π)
        while phaseDiff < 0 {
            phaseDiff += 2 * .pi
        }
        while phaseDiff >= 2 * .pi {
            phaseDiff -= 2 * .pi
        }

        // Quantize to quadrant using Gray code mapping
        // Decision boundaries at π/4, 3π/4, 5π/4, 7π/4
        let (b1, b0) = phaseToDibit(phaseDiff)

        // Feed both bits to Varicode decoder
        if let char1 = varicodeCodec.decode(bit: b1) {
            delegate?.demodulator(
                self,
                didDecode: char1,
                atFrequency: centerFrequency
            )
        }
        if let char2 = varicodeCodec.decode(bit: b0) {
            delegate?.demodulator(
                self,
                didDecode: char2,
                atFrequency: centerFrequency
            )
        }
    }

    /// Convert phase difference to dibit using Gray code
    ///
    /// Phase regions (Gray code for error resilience):
    /// - [-π/4, π/4) → 00 (0°)
    /// - [π/4, 3π/4) → 01 (90°)
    /// - [3π/4, 5π/4) → 11 (180°)
    /// - [5π/4, 7π/4) → 10 (270°)
    private func phaseToDibit(_ phase: Double) -> (Bool, Bool) {
        // Normalize phase to [0, 2π)
        var p = phase
        while p < 0 { p += 2 * .pi }
        while p >= 2 * .pi { p -= 2 * .pi }

        // Shift by π/4 so boundaries are at 0, π/2, π, 3π/2
        let shifted = p + .pi / 4
        let normalized = shifted >= 2 * .pi ? shifted - 2 * .pi : shifted

        // Determine quadrant
        if normalized < .pi / 2 {
            return (false, false)  // 00 → 0°
        } else if normalized < .pi {
            return (false, true)   // 01 → 90°
        } else if normalized < 3 * .pi / 2 {
            return (true, true)    // 11 → 180°
        } else {
            return (true, false)   // 10 → 270°
        }
    }

    /// Update signal detection state
    private func updateSignalDetection(symbolPower: Double) {
        // IIR filter output is already per-sample scale; no normalization needed

        // Track signal power (fast attack, slow decay)
        if symbolPower > signalPower {
            signalPower = signalPower * 0.8 + symbolPower * 0.2
        } else {
            signalPower = signalPower * 0.95 + symbolPower * 0.05
        }

        // Track noise floor (slow adaptation, only updates when no signal)
        if !_signalDetected {
            noisePower = noisePower * 0.99 + symbolPower * 0.01
        } else if symbolPower < noisePower {
            noisePower = noisePower * 0.99 + symbolPower * 0.01
        }

        // SNR-based detection with hysteresis
        let snr = noisePower > 0 ? signalPower / noisePower : 0
        let detectThreshold: Double = _signalDetected ? 2.0 : 4.0  // Hysteresis
        let newDetected = snr > detectThreshold

        if newDetected != _signalDetected {
            _signalDetected = newDetected
            delegate?.demodulator(
                self,
                signalDetected: newDetected,
                atFrequency: centerFrequency
            )
        }
    }

    // MARK: - Control

    /// Reset the demodulator state
    public func reset() {
        localPhase = 0
        iFiltered = 0
        qFiltered = 0
        prevI = 0
        prevQ = 0
        symbolSamples = 0
        symbolTimingAdjust = 0
        earlyMag = 0
        lateMag = 0
        onTimeAccumI = 0
        onTimeAccumQ = 0
        signalPower = 0
        noisePower = 0.001
        _signalDetected = false
        varicodeCodec.reset()
    }

    /// Tune to a different center frequency
    /// - Parameter frequency: New center frequency in Hz
    public func tune(to frequency: Double) {
        configuration = configuration.withCenterFrequency(frequency)
        reset()
    }
}

// MARK: - Convenience Extensions

extension PSKDemodulator {

    /// Create a demodulator with a specific center frequency
    /// - Parameters:
    ///   - centerFrequency: Center frequency in Hz
    ///   - baseConfiguration: Base configuration to modify
    /// - Returns: New demodulator configured for the specified frequency
    public static func withCenterFrequency(
        _ centerFrequency: Double,
        baseConfiguration: PSKConfiguration = .standard
    ) -> PSKDemodulator {
        let config = baseConfiguration.withCenterFrequency(centerFrequency)
        return PSKDemodulator(configuration: config)
    }

    /// Create PSK31 demodulator (BPSK, 31.25 baud)
    public static func psk31(centerFrequency: Double = 1000.0) -> PSKDemodulator {
        PSKDemodulator(configuration: PSKConfiguration.psk31.withCenterFrequency(centerFrequency))
    }

    /// Create BPSK63 demodulator (BPSK, 62.5 baud)
    public static func bpsk63(centerFrequency: Double = 1000.0) -> PSKDemodulator {
        PSKDemodulator(configuration: PSKConfiguration.bpsk63.withCenterFrequency(centerFrequency))
    }

    /// Create QPSK31 demodulator (QPSK, 31.25 baud)
    public static func qpsk31(centerFrequency: Double = 1000.0) -> PSKDemodulator {
        PSKDemodulator(configuration: PSKConfiguration.qpsk31.withCenterFrequency(centerFrequency))
    }

    /// Create QPSK63 demodulator (QPSK, 62.5 baud)
    public static func qpsk63(centerFrequency: Double = 1000.0) -> PSKDemodulator {
        PSKDemodulator(configuration: PSKConfiguration.qpsk63.withCenterFrequency(centerFrequency))
    }
}

// MARK: - Backward Compatibility

/// Type alias for backward compatibility with PSK31-specific code
public typealias PSK31Demodulator = PSKDemodulator

/// Backward compatible delegate protocol
public typealias PSK31DemodulatorDelegate = PSKDemodulatorDelegate
