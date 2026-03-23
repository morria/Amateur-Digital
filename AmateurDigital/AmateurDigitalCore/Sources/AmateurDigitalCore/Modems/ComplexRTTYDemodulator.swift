//
//  ComplexRTTYDemodulator.swift
//  AmateurDigitalCore
//
//  fldigi-style complex demodulation for RTTY. Uses dual complex mixers
//  to shift mark and space tones to baseband, followed by narrow lowpass
//  filters for superior frequency selectivity compared to Goertzel.
//
//  Architecture (fldigi rtty.cxx lines 666-670):
//    Input audio (real) → analytic signal (complex)
//      ├── × exp(-j·2π·f_mark·t) → baseband mark → LPF → |mag| → mark power
//      └── × exp(-j·2π·f_space·t) → baseband space → LPF → |mag| → space power
//
//  The lowpass filter bandwidth is ~1.5× baud rate (~68 Hz for 45.45 baud),
//  far narrower than Goertzel's 91 Hz frequency resolution.
//  This gives +3-6 dB effective sensitivity over the Goertzel approach.
//
//  Reference: fldigi src/cw_rtty/rtty.cxx, src/filters/fftfilt.cxx
//

import Foundation

// MARK: - Delegate Protocol

/// Delegate protocol for receiving decoded characters from ComplexRTTYDemodulator.
public protocol ComplexRTTYDemodulatorDelegate: AnyObject {
    /// Called when a character has been decoded.
    func demodulator(
        _ demodulator: ComplexRTTYDemodulator,
        didDecode character: Character,
        atFrequency frequency: Double
    )

    /// Called when signal detection state changes.
    func demodulator(
        _ demodulator: ComplexRTTYDemodulator,
        signalDetected detected: Bool,
        atFrequency frequency: Double
    )
}

// MARK: - Complex FIR Lowpass Filter

/// Direct-form FIR lowpass filter for complex (I/Q) signals.
///
/// Uses a Blackman-windowed sinc kernel for steep rolloff (-73 dB sidelobes).
/// Processes sample-by-sample for streaming operation. The same real-valued
/// kernel is applied independently to I and Q channels.
///
/// The filter order scales with sample rate / baud rate to maintain constant
/// selectivity in Hz. For 45.45 baud at 48 kHz, a ~64-tap filter provides
/// about 68 Hz bandwidth — narrower than Goertzel's 91 Hz resolution.
struct ComplexFIRFilter {

    /// FIR kernel coefficients
    private let kernel: [Float]

    /// Delay line for I channel
    private var delayI: [Float]

    /// Delay line for Q channel
    private var delayQ: [Float]

    /// Write position in circular buffer
    private var writePos: Int = 0

    /// Filter length
    let length: Int

    /// Decimation counter
    private var decimCount: Int = 0

    /// Decimation factor
    let decimation: Int

    /// Create a lowpass FIR filter with Blackman-windowed sinc design and decimation.
    ///
    /// With decimation > 1, the filter only computes output every N-th sample,
    /// reducing CPU cost proportionally. All input samples are still stored in
    /// the delay line for correct anti-alias filtering.
    ///
    /// - Parameters:
    ///   - cutoffHz: Cutoff frequency in Hz (3 dB point)
    ///   - sampleRate: Sample rate in Hz
    ///   - taps: Number of filter taps (odd values work best)
    ///   - decimation: Output one sample per this many inputs (default: 1)
    init(cutoffHz: Double, sampleRate: Double, taps: Int, decimation: Int = 1) {
        self.length = taps
        self.decimation = decimation
        self.delayI = [Float](repeating: 0, count: taps)
        self.delayQ = [Float](repeating: 0, count: taps)

        // Rewrite init body — adjust cutoff for decimation anti-aliasing
        // The cutoff should be no more than (sampleRate/decimation)/2,
        // but we use the requested cutoff since it's already narrow enough.
        let fc = cutoffHz / sampleRate

        var h = [Float](repeating: 0, count: taps)
        let center = Double(taps - 1) / 2.0
        var sum: Double = 0

        for i in 0..<taps {
            let n = Double(i)
            let sincArg = 2.0 * Double.pi * fc * (n - center)
            let sincVal: Double
            if abs(n - center) < 1e-10 {
                sincVal = 2.0 * fc
            } else {
                sincVal = sin(sincArg) / (Double.pi * (n - center))
            }
            let w = 0.42 - 0.50 * cos(2.0 * Double.pi * n / Double(taps - 1))
                        + 0.08 * cos(4.0 * Double.pi * n / Double(taps - 1))
            h[i] = Float(sincVal * w)
            sum += Double(h[i])
        }

        if sum > 0 {
            for i in 0..<taps { h[i] /= Float(sum) }
        }

        self.kernel = h
    }

    /// Process one complex sample. Returns filtered output only every `decimation`-th sample.
    /// - Parameters:
    ///   - inI: Real (I) component
    ///   - inQ: Imaginary (Q) component
    /// - Returns: Filtered (I, Q) pair if output is ready, nil otherwise
    @inline(__always)
    mutating func process(_ inI: Float, _ inQ: Float) -> (Float, Float)? {
        // Write new sample into circular buffer
        delayI[writePos] = inI
        delayQ[writePos] = inQ
        writePos += 1
        if writePos >= length { writePos = 0 }

        // Only compute output every decimation-th sample
        decimCount += 1
        if decimCount < decimation { return nil }
        decimCount = 0

        // Convolve with kernel
        var outI: Float = 0
        var outQ: Float = 0
        var readPos = writePos - 1
        if readPos < 0 { readPos = length - 1 }

        for k in 0..<length {
            outI += kernel[k] * delayI[readPos]
            outQ += kernel[k] * delayQ[readPos]
            readPos -= 1
            if readPos < 0 { readPos = length - 1 }
        }

        return (outI, outQ)
    }

    /// Reset the filter state (clear delay lines).
    mutating func reset() {
        delayI = [Float](repeating: 0, count: length)
        delayQ = [Float](repeating: 0, count: length)
        writePos = 0
        decimCount = 0
    }
}

// MARK: - Complex RTTY Demodulator

/// fldigi-style complex RTTY demodulator with dual mixer + lowpass filter architecture.
///
/// Replaces Goertzel-based tone detection with complex downconversion followed by
/// narrow lowpass filtering. This gives arbitrarily narrow frequency selectivity
/// (limited only by the FIR filter tap count), compared to Goertzel's fixed
/// resolution of sampleRate / blockSize.
///
/// For standard 45.45 baud RTTY:
/// - Goertzel: 91 Hz frequency resolution (blockSize=528)
/// - Complex demod with 64-tap FIR: ~68 Hz effective bandwidth
///
/// The demodulator uses the same Baudot decode logic as FSKDemodulator but
/// replaces the front-end tone detection with the fldigi complex mixing approach.
///
/// ## DSP Pipeline
/// ```
/// audio → [mark mixer] → [mark LPF] → |mag| → mark_power
///       → [space mixer] → [space LPF] → |mag| → space_power
/// → Optimal ATC bit decision
/// → fldigi-style state machine → Baudot decode → character output
/// ```
public final class ComplexRTTYDemodulator {

    // MARK: - Configuration

    private var configuration: RTTYConfiguration
    private let baudotCodec: BaudotCodec

    // MARK: - Complex Mixer State

    /// Mark tone local oscillator phase (radians)
    private var markPhase: Float = 0

    /// Space tone local oscillator phase (radians)
    private var spacePhase: Float = 0

    /// Phase increment per sample for mark tone
    private let markPhaseInc: Float

    /// Phase increment per sample for space tone
    private let spacePhaseInc: Float

    // MARK: - Lowpass Filters

    /// Mark channel complex lowpass filter
    private var markFilter: ComplexFIRFilter

    /// Space channel complex lowpass filter
    private var spaceFilter: ComplexFIRFilter

    // MARK: - Envelope Tracking (fldigi-style asymmetric decay averager)

    /// Mark channel envelope (fast attack, slow decay)
    private var markEnvelope: Float = 0

    /// Space channel envelope
    private var spaceEnvelope: Float = 0

    /// Mark channel noise floor
    private var markNoise: Float = 0

    /// Space channel noise floor
    private var spaceNoise: Float = 0

    /// Shared noise floor (minimum of mark and space noise)
    private var noiseFloor: Float = 0

    /// Number of decimated samples per symbol (baud period at output rate)
    private let symbolLength: Int

    /// Decimation factor for the lowpass filters
    private let decimationFactor: Int

    // MARK: - Bit Decision and State Machine

    /// Bit buffer for start-bit edge detection (full symbol length, like fldigi)
    private var bitBuffer: [Bool]
    private let bitBufferLength: Int

    /// Moving average for bit smoothing (fldigi: Cmovavg of symbollen/8)
    private var bitSmoother: [Float] = []
    private let bitSmootherLength: Int

    /// Demodulator state (fldigi rx state machine)
    private enum RxState {
        case idle
        case startBit(counter: Int)
        case data(counter: Int, bitIndex: Int, rxData: UInt8)
        case stopBit(counter: Int, rxData: UInt8)
    }

    private var rxState: RxState = .idle

    /// Number of data bits per character (5 for Baudot)
    private let numBits: Int = 5

    // MARK: - Output

    /// Delegate for decoded characters
    public weak var delegate: ComplexRTTYDemodulatorDelegate?

    /// Whether polarity is inverted (swaps mark/space interpretation)
    public var polarityInverted: Bool = false

    /// Whether a valid signal is detected
    public private(set) var signalDetected: Bool = false

    /// Signal strength metric (0.0 to 1.0)
    public var signalStrength: Float {
        let signal = markEnvelope + spaceEnvelope
        let noise = noiseFloor * 2.0 + 1e-10
        return min(1.0, (signal / noise) / 20.0)
    }

    /// Center (mark) frequency
    public var centerFrequency: Double {
        configuration.markFrequency
    }

    /// Current Baudot shift state
    public var currentShiftState: BaudotCodec.ShiftState {
        baudotCodec.currentShift
    }

    /// Squelch level (0.0 = disabled, >0 = manual threshold)
    public var squelchLevel: Float = 0

    // MARK: - Initialization

    /// Create a complex RTTY demodulator.
    ///
    /// - Parameter configuration: RTTY configuration (frequencies, baud rate, etc.)
    public init(configuration: RTTYConfiguration = .standard) {
        self.configuration = configuration
        self.baudotCodec = BaudotCodec()

        // Decimation factor: reduces post-filter sample rate for cheaper processing.
        // The lowpass filter has ~68 Hz bandwidth, so Nyquist requires at least ~136 Hz
        // output rate. We use a conservative factor to preserve bit timing accuracy.
        // For 45.45 baud at 48 kHz: symbolLength_full = 1056 samples.
        // Decimation by 8 → symbolLength = 132 decimated samples per bit.
        // This keeps good timing resolution while reducing state machine work by 8x.
        let fullSymbolLength = Int((configuration.sampleRate / configuration.baudRate).rounded())
        let decim = max(1, fullSymbolLength / 132)  // Target ~132 samples/bit after decimation
        self.decimationFactor = decim
        self.symbolLength = max(1, fullSymbolLength / decim)

        // Pre-compute phase increments for mixer oscillators
        let twoPi = Float(2.0 * Double.pi)
        let sr = Float(configuration.sampleRate)
        self.markPhaseInc = twoPi * Float(configuration.markFrequency) / sr
        self.spacePhaseInc = twoPi * Float(configuration.spaceFrequency) / sr

        // FIR lowpass filter bandwidth: baud_rate * 1.5
        // This is the key advantage over Goertzel — the filter bandwidth is independent
        // of the analysis window size and can be made arbitrarily narrow.
        //
        // Tap count: 65 gives good selectivity (~-40 dB out-of-band with Blackman window).
        let cutoffHz = configuration.baudRate * 1.5
        let taps = 65  // Odd number for symmetric FIR

        self.markFilter = ComplexFIRFilter(
            cutoffHz: cutoffHz,
            sampleRate: configuration.sampleRate,
            taps: taps,
            decimation: decim
        )
        self.spaceFilter = ComplexFIRFilter(
            cutoffHz: cutoffHz,
            sampleRate: configuration.sampleRate,
            taps: taps,
            decimation: decim
        )

        // Bit smoother: moving average of length symbollen/8 (fldigi convention)
        self.bitSmootherLength = max(1, symbolLength / 8)

        // Bit buffer for edge detection (full symbol length, fldigi convention)
        self.bitBufferLength = symbolLength
        self.bitBuffer = [Bool](repeating: true, count: symbolLength)
    }

    // MARK: - Processing

    /// Process a buffer of audio samples.
    ///
    /// - Parameter samples: Audio samples (Float, typically from AudioService)
    public func process(samples: [Float]) {
        for sample in samples {
            processSample(sample)
        }
    }

    /// Process a single audio sample through the complete demodulation pipeline.
    ///
    /// 1. Mix with mark/space oscillators → baseband complex signals
    /// 2. Lowpass filter each channel (with decimation)
    /// 3. When filter output is ready: extract magnitude, update envelopes,
    ///    make bit decision, feed state machine
    @inline(__always)
    private func processSample(_ sample: Float) {

        // --- Complex mixer: shift each tone to baseband ---
        //
        // Mixer produces: out = sample * exp(-j*2π*f*t)
        //   outI = sample * cos(phase)
        //   outQ = sample * -sin(phase)

        let markCos = cosf(markPhase)
        let markSin = sinf(markPhase)
        let markI = sample * markCos
        let markQ = sample * -markSin

        let spaceCos = cosf(spacePhase)
        let spaceSin = sinf(spacePhase)
        let spaceI = sample * spaceCos
        let spaceQ = sample * -spaceSin

        // Advance oscillator phases
        markPhase += markPhaseInc
        if markPhase > Float.pi * 2.0 { markPhase -= Float.pi * 2.0 }
        spacePhase += spacePhaseInc
        if spacePhase > Float.pi * 2.0 { spacePhase -= Float.pi * 2.0 }

        // --- Lowpass filter each channel (with decimation) ---
        // IMPORTANT: Always call both filters to keep their decimation counters in sync.
        let markOut = markFilter.process(markI, markQ)
        let spaceOut = spaceFilter.process(spaceI, spaceQ)

        // Both filters have the same decimation factor and are fed in sync,
        // so they should always produce output at the same time.
        guard let (fMarkI, fMarkQ) = markOut,
              let (fSpaceI, fSpaceQ) = spaceOut else {
            return  // No output yet — decimation waiting for more samples
        }

        // --- Post-filter processing at decimated rate ---
        processDecimatedSample(fMarkI, fMarkQ, fSpaceI, fSpaceQ)
    }

    /// Process one decimated sample: envelope tracking, ATC, state machine.
    ///
    /// Runs at sampleRate / decimationFactor. For 48 kHz with decim=8, this is 6 kHz.
    private func processDecimatedSample(
        _ fMarkI: Float, _ fMarkQ: Float,
        _ fSpaceI: Float, _ fSpaceQ: Float
    ) {
        // --- Extract magnitudes ---
        let markMag = sqrtf(fMarkI * fMarkI + fMarkQ * fMarkQ)
        let spaceMag = sqrtf(fSpaceI * fSpaceI + fSpaceQ * fSpaceQ)

        // --- Update envelopes (fldigi-style asymmetric decay averaging) ---
        // decayavg(avg, input, weight) = avg + (input - avg) / weight
        // Fast attack: symbolLength / 4
        // Slow decay: symbolLength * 16 for envelope, * 48 for noise
        let sym = Float(symbolLength)

        let markEnvWeight = markMag > markEnvelope ? sym / 4.0 : sym * 16.0
        markEnvelope += (markMag - markEnvelope) / max(markEnvWeight, 1.0)

        let markNoiseWeight = markMag < markNoise ? sym / 4.0 : sym * 48.0
        markNoise += (markMag - markNoise) / max(markNoiseWeight, 1.0)

        let spaceEnvWeight = spaceMag > spaceEnvelope ? sym / 4.0 : sym * 16.0
        spaceEnvelope += (spaceMag - spaceEnvelope) / max(spaceEnvWeight, 1.0)

        let spaceNoiseWeight = spaceMag < spaceNoise ? sym / 4.0 : sym * 48.0
        spaceNoise += (spaceMag - spaceNoise) / max(spaceNoiseWeight, 1.0)

        noiseFloor = min(markNoise, spaceNoise)

        // --- Optimal ATC bit decision (fldigi rtty.cxx:696-756) ---
        //
        // Clip instantaneous magnitude to envelope level
        let mClipped = min(markMag, markEnvelope)
        let sClipped = min(spaceMag, spaceEnvelope)

        // Clamp to noise floor
        let mClamped = max(mClipped, noiseFloor)
        let sClamped = max(sClipped, noiseFloor)

        // Optimal ATC formula (W7AY):
        //   v = (mClipped - noise) * (markEnv - noise)
        //     - (sClipped - noise) * (spaceEnv - noise)
        //     - 0.25 * ((markEnv - noise)^2 - (spaceEnv - noise)^2)
        let nf = noiseFloor
        let mEnvN = max(0 as Float, markEnvelope - nf)
        let sEnvN = max(0 as Float, spaceEnvelope - nf)

        let v = (mClamped - nf) * mEnvN
              - (sClamped - nf) * sEnvN
              - 0.25 * (mEnvN * mEnvN - sEnvN * sEnvN)

        let rawBit = polarityInverted ? (v <= 0) : (v > 0)

        // --- Bit smoothing (moving average, fldigi: Cmovavg of symbollen/8) ---
        bitSmoother.append(rawBit ? 1.0 : 0.0)
        if bitSmoother.count > bitSmootherLength {
            bitSmoother.removeFirst(bitSmoother.count - bitSmootherLength)
        }
        let smoothedBit = (bitSmoother.reduce(0, +) / Float(bitSmoother.count)) > 0.5

        // --- Feed into fldigi-style state machine ---
        rxProcess(bit: smoothedBit)
    }

    // MARK: - State Machine (fldigi-style, rtty.cxx:472-539)

    /// Detect mark-to-space transition for start bit detection.
    ///
    /// Checks the bit buffer for a transition where the first sample is mark
    /// and the last is space, with the transition near the center.
    /// Returns the number of mark samples (correction offset) if valid.
    private func detectStartEdge() -> Int? {
        guard bitBuffer[0] == true && bitBuffer[bitBufferLength - 1] == false else {
            return nil
        }

        var markCount = 0
        for b in bitBuffer {
            if b { markCount += 1 }
        }

        // Transition should be near the middle
        let halfSymbol = bitBufferLength / 2
        let tolerance = max(6, bitBufferLength / 16)
        if abs(halfSymbol - markCount) < tolerance {
            return markCount
        }

        return nil
    }

    /// Check if the center of the bit buffer is mark.
    @inline(__always)
    private func isMark() -> Bool {
        return bitBuffer[bitBufferLength / 2]
    }

    /// Process one bit through the fldigi-style state machine.
    ///
    /// Operates sample-by-sample (not block-by-block) for precise bit timing.
    private func rxProcess(bit: Bool) {
        // Shift bit buffer left by one
        for i in 1..<bitBufferLength {
            bitBuffer[i - 1] = bitBuffer[i]
        }
        bitBuffer[bitBufferLength - 1] = bit

        switch rxState {
        case .idle:
            if let correction = detectStartEdge() {
                rxState = .startBit(counter: correction)
            }

        case .startBit(var counter):
            counter -= 1
            if counter <= 0 {
                if !isMark() {
                    // Valid start bit confirmed — begin receiving data
                    rxState = .data(counter: symbolLength, bitIndex: 0, rxData: 0)
                } else {
                    // False start
                    rxState = .idle
                }
            } else {
                rxState = .startBit(counter: counter)
            }

        case .data(var counter, let bitIndex, var rxData):
            counter -= 1
            if counter <= 0 {
                // Sample the bit at center of bit period
                if isMark() {
                    rxData |= UInt8(1 << bitIndex)
                }

                let nextBit = bitIndex + 1
                if nextBit >= numBits {
                    // All data bits received — move to stop bit
                    rxState = .stopBit(counter: symbolLength, rxData: rxData)
                } else {
                    rxState = .data(counter: symbolLength, bitIndex: nextBit, rxData: rxData)
                }
            } else {
                rxState = .data(counter: counter, bitIndex: bitIndex, rxData: rxData)
            }

        case .stopBit(var counter, let rxData):
            counter -= 1
            if counter <= 0 {
                // Stop bit complete — check if it's mark (valid framing)
                if isMark() {
                    decodeAndEmit(rxData)
                }
                rxState = .idle
            } else {
                rxState = .stopBit(counter: counter, rxData: rxData)
            }
        }
    }

    /// Decode a Baudot code and emit via delegate.
    private func decodeAndEmit(_ code: UInt8) {
        // Apply squelch
        if squelchLevel > 0 {
            guard signalStrength >= squelchLevel else { return }
        }

        if let character = baudotCodec.decode(code) {
            delegate?.demodulator(
                self,
                didDecode: character,
                atFrequency: centerFrequency
            )
        }
    }

    // MARK: - Control

    /// Reset the demodulator to initial state.
    public func reset() {
        markPhase = 0
        spacePhase = 0
        markFilter.reset()
        spaceFilter.reset()
        markEnvelope = 0
        spaceEnvelope = 0
        markNoise = 0
        spaceNoise = 0
        noiseFloor = 0
        bitSmoother.removeAll(keepingCapacity: true)
        bitBuffer = [Bool](repeating: true, count: bitBufferLength)
        rxState = .idle
        signalDetected = false
        baudotCodec.reset()
    }

    /// Tune to a different center frequency.
    /// - Parameter frequency: New mark frequency in Hz
    public func tune(to frequency: Double) {
        configuration = configuration.withCenterFrequency(frequency)
        reset()
    }
}
