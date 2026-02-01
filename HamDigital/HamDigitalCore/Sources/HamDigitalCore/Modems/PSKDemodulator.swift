//
//  PSKDemodulator.swift
//  HamDigitalCore
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
/// 2. Low-pass filter to extract baseband
/// 3. Differential phase detection (compare current vs previous symbol)
///    - BPSK: Dot product sign check for 180° detection
///    - QPSK: atan2 phase calculation, quantize to nearest quadrant
/// 4. Symbol timing recovery using early-late gate
/// 5. Varicode decoding to characters
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

    /// Low-pass filter states for I and Q channels
    private var iFiltered: Double = 0
    private var qFiltered: Double = 0

    /// Previous symbol's I and Q values (for differential detection)
    private var prevI: Double = 0
    private var prevQ: Double = 0

    /// Symbol timing recovery
    private var symbolPhase: Double = 0
    private var symbolSamples: Int = 0
    private var earlyAccumI: Double = 0
    private var earlyAccumQ: Double = 0
    private var lateAccumI: Double = 0
    private var lateAccumQ: Double = 0
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
        return Float(min(1.0, snr / 10.0))  // Normalize to 0-1
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

    /// Low-pass filter coefficient (higher = more filtering, slower response)
    private let filterAlpha: Double = 0.1

    /// Symbol timing loop gain
    private let timingGain: Double = 0.01

    // MARK: - Initialization

    /// Create a PSK demodulator
    /// - Parameter configuration: PSK configuration (frequency, sample rate, modulation type)
    public init(configuration: PSKConfiguration = .standard) {
        self.configuration = configuration
        self.varicodeCodec = VaricodeCodec()
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
        let q = sampleD * sin(localPhase)

        // Advance local oscillator phase
        localPhase += configuration.phaseIncrementPerSample
        if localPhase >= 2.0 * .pi {
            localPhase -= 2.0 * .pi
        }

        // Low-pass filter (simple IIR)
        iFiltered = iFiltered * (1.0 - filterAlpha) + i * filterAlpha
        qFiltered = qFiltered * (1.0 - filterAlpha) + q * filterAlpha

        // Update signal power estimate
        let instantPower = iFiltered * iFiltered + qFiltered * qFiltered
        signalPower = signalPower * 0.99 + instantPower * 0.01

        // Accumulate for symbol timing
        symbolSamples += 1

        let samplesPerSymbol = configuration.samplesPerSymbol
        let quarterSymbol = samplesPerSymbol / 4
        let threeQuarterSymbol = (samplesPerSymbol * 3) / 4

        // Early-late gate timing recovery
        if symbolSamples < quarterSymbol {
            earlyAccumI += iFiltered
            earlyAccumQ += qFiltered
        } else if symbolSamples >= quarterSymbol && symbolSamples < threeQuarterSymbol {
            onTimeAccumI += iFiltered
            onTimeAccumQ += qFiltered
        } else {
            lateAccumI += iFiltered
            lateAccumQ += qFiltered
        }

        // Check if we've completed a symbol
        if symbolSamples >= samplesPerSymbol {
            processSymbol()
            symbolSamples = 0
            earlyAccumI = 0
            earlyAccumQ = 0
            onTimeAccumI = 0
            onTimeAccumQ = 0
            lateAccumI = 0
            lateAccumQ = 0
        }
    }

    /// Process a complete symbol
    private func processSymbol() {
        // Symbol timing error (early-late gate)
        let earlyMag = sqrt(earlyAccumI * earlyAccumI + earlyAccumQ * earlyAccumQ)
        let lateMag = sqrt(lateAccumI * lateAccumI + lateAccumQ * lateAccumQ)
        let timingError = earlyMag - lateMag

        // Adjust timing (not implemented for simplicity - would skip/add samples)
        _ = timingError * timingGain

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
        // Simple threshold-based detection
        let threshold = 0.01  // Minimum power for signal detection
        let newDetected = symbolPower > threshold && signalStrength > 0.1

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
        symbolPhase = 0
        symbolSamples = 0
        earlyAccumI = 0
        earlyAccumQ = 0
        lateAccumI = 0
        lateAccumQ = 0
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
