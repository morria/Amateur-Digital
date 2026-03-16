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
/// Signal processing pipeline:
/// 1. Bandpass filter to reject out-of-band noise
/// 2. AGC to normalize signal level for fading HF conditions
/// 3. Mix signal with local oscillator (I and Q channels)
/// 4. IIR lowpass filter (bandwidth matched to symbol rate)
/// 5. Sample filtered I/Q at symbol boundaries
/// 6. Symbol timing recovery using early-late amplitude comparison
/// 7. Differential phase detection (compare current vs previous symbol)
///    - BPSK: Dot product sign check for 180° detection
///    - QPSK: atan2 phase calculation, quantize to nearest quadrant
/// 8. AFC: Two-phase carrier tracking (preamble estimation + decision-directed)
/// 9. Varicode decoding to characters
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
    private var signalPersistCount: Int = 0         // consecutive symbols above detection threshold
    private let signalPersistRequired: Int = 4      // must sustain for this many symbols to open squelch

    /// Phase quality metric (fldigi-style IMD approximation) — measures how close
    /// symbol phases are to expected constellation points. Real BPSK signals cluster
    /// at 0° and 180° → |cos(Δφ)| ≈ 1.0. Noise has uniform random phase → ≈ 0.637.
    private var phaseQualityAccum: Double = 0
    private var phaseQualityCount: Int = 0
    private var phaseQualityTotalSymbols: Int = 0     // total symbols since signal detected
    private let phaseQualityThreshold: Double = 0.70  // quality must exceed this to sustain

    // MARK: - Bandpass Filters

    /// IIR bandpass filter for out-of-band noise rejection (~40 dB)
    private var bandpassFilter: BandpassFilter

    /// FFT-based FIR bandpass for deep rejection (~73 dB)
    private var fftBandpassFilter: OverlapAddFilter

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

    // MARK: - AFC Properties

    /// AFC (Automatic Frequency Control) - carrier tracking
    /// Two-phase approach:
    /// 1. Preamble estimation: measures raw phase rotation during idle carrier for initial offset
    /// 2. Decision-directed tracking: refines offset using decoded symbols
    private var afcPhaseCorrection: Double = 0    // current correction per sample (radians)
    private var afcIntegrator: Double = 0          // integral term of loop filter
    private var afcSymbolCount: Int = 0            // symbols since signal detection
    private var afcErrorAccum: Double = 0          // accumulated error for averaging
    private var afcErrorCount: Int = 0             // number of errors accumulated
    private var afcInitialEstimateDone: Bool = false  // has preamble estimation completed?
    private var afcPreambleI: [Double] = []           // I samples during preamble (sub-symbol rate)
    private var afcPreambleQ: [Double] = []           // Q samples during preamble (sub-symbol rate)
    private var afcPreambleSampleCount: Int = 0       // sample counter within preamble

    // MARK: - Public Properties

    /// Delegate for receiving decoded characters
    public weak var delegate: PSKDemodulatorDelegate?

    /// Manual squelch level override (0.0-1.0). Set to 0 to use adaptive squelch.
    public var squelchLevel: Float = 0

    /// Effective squelch level (uses manual if set, otherwise adaptive)
    private var effectiveSquelchLevel: Float {
        squelchLevel > 0 ? squelchLevel : adaptiveSquelchLevel
    }

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

    /// AFC integral gain — fraction of measured offset corrected per averaging window.
    /// 0.5 = correct half the error each window (converges in ~3 windows).
    private let afcIntegralGain: Double = 0.5

    /// AFC integrator leak factor — prevents drift on clean channel.
    private let afcLeakFactor: Double = 0.999

    /// AFC dead zone — averaged error must exceed this to apply correction (radians).
    /// 0.08 rad ≈ 0.4 Hz at PSK31 — prevents clean-channel noise from drifting.
    private let afcDeadZone: Double = 0.08

    /// Maximum AFC correction in Hz — prevents runaway
    private let afcMaxCorrectionHz: Double = 60.0

    /// Symbols of signal detection before AFC engages
    private let afcWarmupSymbols: Int = 4

    /// Number of symbols to average before applying an AFC correction
    private let afcAveragingWindow: Int = 4

    // MARK: - Initialization

    /// Create a PSK demodulator
    /// - Parameter configuration: PSK configuration (frequency, sample rate, modulation type)
    public init(configuration: PSKConfiguration = .standard) {
        self.configuration = configuration
        self.varicodeCodec = VaricodeCodec()

        // Initialize bandpass filter centered on the carrier frequency
        // Margin: at least 50 Hz or 1.5× baud rate, whichever is larger
        let margin = max(50.0, configuration.baudRate * 1.5)
        self.bandpassFilter = BandpassFilter(
            lowCutoff: configuration.centerFrequency - margin,
            highCutoff: configuration.centerFrequency + margin,
            sampleRate: configuration.sampleRate
        )

        // FFT-based FIR bandpass for deep rejection (-73 dB)
        self.fftBandpassFilter = OverlapAddFilter.bandpass(
            lowCutoff: configuration.centerFrequency - margin,
            highCutoff: configuration.centerFrequency + margin,
            sampleRate: configuration.sampleRate,
            taps: 257
        )
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
        // Apply FFT bandpass filter to entire buffer first (efficient block processing)
        let fftFiltered = fftBandpassFilter.process(samples)
        for sample in fftFiltered {
            processSample(sample)
        }
    }

    /// Process a single audio sample
    private func processSample(_ sample: Float) {
        // Apply bandpass filter to reject out-of-band noise
        let filteredSample = bandpassFilter.process(sample)

        // Apply AGC to normalize signal level
        let agcSample = applyAGC(filteredSample)

        let sampleD = Double(agcSample)

        // Mix with local oscillator (quadrature demodulation)
        let i = sampleD * cos(localPhase)
        let q = sampleD * -sin(localPhase)

        // Advance local oscillator phase (with AFC correction)
        localPhase += configuration.phaseIncrementPerSample + afcPhaseCorrection
        if localPhase >= 2.0 * .pi {
            localPhase -= 2.0 * .pi
        } else if localPhase < 0 {
            localPhase += 2.0 * .pi
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

        // During preamble warmup, collect sub-symbol IQ at quarter-symbol intervals
        // This gives 4× the sampling rate for frequency estimation (Nyquist ~62 Hz at PSK31)
        afcPreambleSampleCount += 1
        if !afcInitialEstimateDone && _signalDetected && afcPreambleSampleCount >= quarterSymbol {
            afcPreambleSampleCount = 0
            afcPreambleI.append(iFiltered)
            afcPreambleQ.append(qFiltered)
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

    // MARK: - AGC

    /// Apply AGC to normalize signal level
    /// Only adjusts gain when a signal is detected — prevents amplifying noise
    /// to signal levels which would cause false detection.
    /// - Parameter sample: Input sample
    /// - Returns: Gain-adjusted sample
    private func applyAGC(_ sample: Float) -> Float {
        let output = sample * agcGain
        let level = abs(output)

        // Only run AGC gain adjustment when signal is detected
        // Otherwise, leave gain at 1.0 to avoid amplifying noise
        if _signalDetected {
            if level > agcTarget {
                agcGain *= (1.0 - agcAttack)
            } else {
                agcGain *= (1.0 + agcDecay)
            }
            agcGain = max(agcMinGain, min(agcMaxGain, agcGain))
        } else {
            // Slowly return gain to 1.0 when no signal (ready for next signal)
            if agcGain > 1.0 {
                agcGain *= (1.0 - agcDecay * 10)
            } else if agcGain < 1.0 {
                agcGain *= (1.0 + agcDecay * 10)
            }
        }

        return output
    }

    // MARK: - Adaptive Noise Floor

    /// Update noise floor estimate from symbol magnitude
    /// - Parameter magnitude: Current symbol magnitude
    private func updateNoiseFloor(_ magnitude: Float) {
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

    // MARK: - Symbol Processing

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

        // Update signal detection with adaptive noise floor
        let symbolPower = currentI * currentI + currentQ * currentQ
        let symbolMag = Float(sqrt(symbolPower))
        updateNoiseFloor(symbolMag)
        updateSignalDetection(symbolPower: symbolPower)

        // Only decode if signal is detected and above squelch
        guard _signalDetected && signalStrength >= effectiveSquelchLevel else {
            prevI = currentI
            prevQ = currentQ
            afcSymbolCount = 0  // Reset warmup counter when signal lost
            afcInitialEstimateDone = false
            afcPreambleI.removeAll()
            afcPreambleQ.removeAll()
            afcPreambleSampleCount = 0
            return
        }

        afcSymbolCount += 1

        // Phase 1: Preamble frequency estimation (during warmup)
        // Sub-symbol IQ samples are collected in processSample at quarter-symbol rate
        if afcSymbolCount <= afcWarmupSymbols {
            // At end of warmup, estimate frequency offset from sub-symbol IQ progression
            if afcSymbolCount == afcWarmupSymbols && afcPreambleI.count >= 4 {
                estimateInitialFrequencyOffset()
            }
            prevI = currentI
            prevQ = currentQ
            return  // Don't decode during warmup — it's preamble
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

    // MARK: - AFC

    /// Estimate frequency offset from preamble IQ measurements.
    /// Uses sub-symbol (quarter-symbol) IQ samples for extended frequency range.
    /// Nyquist limit ≈ 2× baud rate (vs 0.5× with per-symbol measurement).
    private func estimateInitialFrequencyOffset() {
        guard afcPreambleI.count >= 4 else { return }

        // Compute phase at each sub-symbol sample point
        var phases: [Double] = []
        for i in 0..<afcPreambleI.count {
            phases.append(atan2(afcPreambleQ[i], afcPreambleI[i]))
        }

        // Compute phase diffs between consecutive quarter-symbol measurements
        var subSymbolDiffs: [Double] = []
        for i in 1..<phases.count {
            var diff = phases[i] - phases[i - 1]
            while diff > .pi { diff -= 2 * .pi }
            while diff < -.pi { diff += 2 * .pi }
            subSymbolDiffs.append(diff)
        }

        // Skip first 2 diffs (filter transient) and use median for robustness
        let skipCount = min(2, subSymbolDiffs.count / 3)
        let trimmed = Array(subSymbolDiffs.dropFirst(skipCount))
        guard !trimmed.isEmpty else {
            afcPreambleI.removeAll()
            afcPreambleQ.removeAll()
            return
        }
        let sorted = trimmed.sorted()
        let medianDiff = sorted[sorted.count / 2]

        // medianDiff is phase change per quarter-symbol interval
        // Convert to per-sample correction
        let samplesPerInterval = Double(configuration.samplesPerSymbol) / 4.0
        let correctionPerSample = medianDiff / samplesPerInterval

        // Apply if significant
        let deadZonePerSample = afcDeadZone / Double(configuration.samplesPerSymbol)
        if abs(correctionPerSample) > deadZonePerSample {
            afcIntegrator = correctionPerSample
            afcPhaseCorrection = afcIntegrator
            afcInitialEstimateDone = true
        }

        afcPreambleI.removeAll()
        afcPreambleQ.removeAll()
    }

    /// Decision-directed AFC update using averaged phase error with leaky integrator
    private func updateAFC(phaseError: Double) {
        // Don't engage AFC during warmup (filter settling period)
        guard afcSymbolCount > afcWarmupSymbols else { return }

        // Ignore suspiciously large phase errors (likely bit errors or noise spikes)
        guard abs(phaseError) < .pi / 2 else { return }

        // Accumulate phase errors over a window for averaging
        afcErrorAccum += phaseError
        afcErrorCount += 1

        // Only apply correction after averaging over a full window
        guard afcErrorCount >= afcAveragingWindow else { return }

        let avgError = afcErrorAccum / Double(afcErrorCount)
        afcErrorAccum = 0
        afcErrorCount = 0

        // Dead zone: averaged error must be significant (consistent bias = real offset)
        guard abs(avgError) > afcDeadZone else { return }

        // Leaky integrator: slowly decays toward zero when no consistent error
        // avgError is in radians/symbol; divide by samplesPerSymbol to get radians/sample
        let correctionPerSample = avgError / Double(configuration.samplesPerSymbol)
        afcIntegrator = afcIntegrator * afcLeakFactor + afcIntegralGain * correctionPerSample

        // Clamp integrator to prevent windup
        let maxIntegral = 2.0 * .pi * afcMaxCorrectionHz / configuration.sampleRate
        afcIntegrator = max(-maxIntegral, min(maxIntegral, afcIntegrator))

        // Total correction in radians per sample
        afcPhaseCorrection = afcIntegrator
    }

    // MARK: - BPSK/QPSK Decode

    /// Decode BPSK symbol using dot product phase detection
    private func decodeBPSKSymbol(currentI: Double, currentQ: Double) {
        // Cross-product to detect phase reversal
        // If phases are same: prevI*currentI + prevQ*currentQ > 0
        // If phases are opposite: prevI*currentI + prevQ*currentQ < 0
        let dotProduct = prevI * currentI + prevQ * currentQ

        // Decode bit (phase reversal = 1, same phase = 0)
        let bit = dotProduct < 0

        // AFC: Decision-directed frequency error estimation
        // After removing the data modulation, the residual phase rotation
        // between symbols is due to frequency offset.
        // De-rotate: if bit=1, negate current symbol to undo 180° shift
        let derotI = bit ? -currentI : currentI
        let derotQ = bit ? -currentQ : currentQ
        let freqCross = prevI * derotQ - prevQ * derotI
        let freqDot = prevI * derotI + prevQ * derotQ
        let phaseError = atan2(freqCross, freqDot)
        updateAFC(phaseError: phaseError)

        // Phase quality: |cos(residual_phase)| after AFC correction
        // Real signals cluster near 0 residual → cos ≈ 1.0
        // Noise has random residual → average cos ≈ 0.637
        phaseQualityAccum += abs(cos(phaseError))
        phaseQualityCount += 1

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

        // AFC: Decision-directed frequency error for QPSK
        // Remove the decided phase shift to get residual frequency error
        let decidedShift = dibitToPhaseShift(b1, b0)
        var phaseError = phaseDiff - decidedShift
        // Normalize to [-π, π)
        while phaseError > .pi { phaseError -= 2 * .pi }
        while phaseError < -.pi { phaseError += 2 * .pi }
        updateAFC(phaseError: phaseError)

        // Phase quality: residual phase after removing decided quadrant
        // should be near 0 for real signals. Use same metric as BPSK (cos(error))
        // since the residual is already in [-π/4, π/4] for correct decisions.
        phaseQualityAccum += abs(cos(phaseError))
        phaseQualityCount += 1

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

    /// Convert dibit to phase shift (for AFC error calculation)
    private func dibitToPhaseShift(_ b1: Bool, _ b0: Bool) -> Double {
        switch (b1, b0) {
        case (false, false): return 0
        case (false, true):  return .pi / 2
        case (true, true):   return .pi
        case (true, false):  return 3 * .pi / 2
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
    ///
    /// Uses SNR-based detection with hysteresis and persistence.
    /// A signal must sustain above the detection threshold for multiple
    /// consecutive symbols before the squelch opens. This prevents
    /// random noise spikes from triggering false decodes.
    private func updateSignalDetection(symbolPower: Double) {
        // Track signal power (fast attack, slow decay)
        if symbolPower > signalPower {
            signalPower = signalPower * 0.8 + symbolPower * 0.2
        } else {
            signalPower = signalPower * 0.95 + symbolPower * 0.05
        }

        // Track noise floor
        // When no signal detected: track aggressively so noise can't create false SNR
        // When signal detected: track very slowly, only updating if power drops below floor
        if !_signalDetected {
            // Moderate tracking during noise — keeps noisePower near signalPower
            noisePower = noisePower * 0.98 + symbolPower * 0.02
        } else if symbolPower < noisePower {
            noisePower = noisePower * 0.99 + symbolPower * 0.01
        }

        // SNR-based detection with hysteresis
        let snr = noisePower > 0 ? signalPower / noisePower : 0
        let acquireThreshold: Double = 8.0   // SNR to initially detect a signal (~9 dB)
        let sustainThreshold: Double = 3.0   // SNR to sustain detection (hysteresis)
        let instantThreshold = _signalDetected ? sustainThreshold : acquireThreshold

        if snr > instantThreshold {
            signalPersistCount += 1
        } else {
            signalPersistCount = 0
        }

        // Require persistence to acquire, drop if below sustain OR phase quality degrades
        let newDetected: Bool
        if _signalDetected {
            phaseQualityTotalSymbols += 1

            // Grace period: don't check phase quality until AFC has had time to converge
            // After grace period, check quality periodically to drop false detections
            let qualityOK: Bool
            if phaseQualityTotalSymbols < 12 {
                qualityOK = true  // Assume good during AFC convergence
            } else if phaseQualityCount >= 8 {
                let phaseQuality = phaseQualityAccum / Double(phaseQualityCount)
                qualityOK = phaseQuality > phaseQualityThreshold
            } else {
                qualityOK = true  // Not enough samples yet
            }

            newDetected = snr > sustainThreshold && qualityOK

            // Reset phase quality accumulator periodically for fresh measurements
            if phaseQualityCount >= 16 {
                phaseQualityAccum = 0
                phaseQualityCount = 0
            }
        } else {
            newDetected = signalPersistCount >= signalPersistRequired
        }

        if newDetected != _signalDetected {
            _signalDetected = newDetected
            if !newDetected {
                signalPersistCount = 0
                phaseQualityAccum = 0
                phaseQualityCount = 0
                phaseQualityTotalSymbols = 0
            }
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
        signalPersistCount = 0
        phaseQualityAccum = 0
        phaseQualityCount = 0
        phaseQualityTotalSymbols = 0
        afcPhaseCorrection = 0
        afcIntegrator = 0
        afcSymbolCount = 0
        afcErrorAccum = 0
        afcErrorCount = 0
        afcInitialEstimateDone = false
        afcPreambleI.removeAll()
        afcPreambleQ.removeAll()
        afcPreambleSampleCount = 0
        varicodeCodec.reset()
        bandpassFilter.reset()
        fftBandpassFilter.reset()
        agcGain = 1.0
        noiseFloor = 0.1
    }

    /// Tune to a different center frequency
    /// - Parameter frequency: New center frequency in Hz
    public func tune(to frequency: Double) {
        configuration = configuration.withCenterFrequency(frequency)

        // Rebuild bandpass filter for new frequency
        let margin = max(50.0, configuration.baudRate * 1.5)
        bandpassFilter = BandpassFilter(
            lowCutoff: configuration.centerFrequency - margin,
            highCutoff: configuration.centerFrequency + margin,
            sampleRate: configuration.sampleRate
        )

        fftBandpassFilter = OverlapAddFilter.bandpass(
            lowCutoff: configuration.centerFrequency - margin,
            highCutoff: configuration.centerFrequency + margin,
            sampleRate: configuration.sampleRate,
            taps: 257
        )

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
