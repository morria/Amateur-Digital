//
//  OverlapAddFilter.swift
//  AmateurDigitalCore
//
//  High-performance FIR bandpass filter using FFT overlap-add convolution.
//  Provides -73 dB+ stopband rejection vs ~40 dB from IIR biquads.
//  Based on the approach used by fldigi for RTTY/PSK filtering.
//
//  Reference: https://en.wikipedia.org/wiki/Overlap–add_method
//

import Foundation

/// FFT-based FIR filter using the overlap-add method for efficient real-time convolution.
///
/// Achieves steep filter rolloff (-73 dB or better) with linear phase (no group delay distortion).
/// Significantly outperforms cascaded IIR biquad filters for narrow bandpass applications.
///
/// Usage:
/// ```swift
/// var filter = OverlapAddFilter.bandpass(
///     lowCutoff: 1900, highCutoff: 2200,
///     sampleRate: 48000, taps: 256
/// )
/// let filtered = filter.process(samples)
/// ```
public struct OverlapAddFilter {

    /// FIR filter coefficients in frequency domain (pre-computed FFT)
    private let filterFFTReal: [Double]
    private let filterFFTImag: [Double]

    /// FFT block size (must be power of 2, >= taps + blockSize - 1)
    private let fftSize: Int

    /// Number of FIR taps
    private let taps: Int

    /// Processing block size (fftSize - taps + 1)
    private let blockSize: Int

    /// Overlap buffer from previous block
    private var overlapBuffer: [Double]

    /// Input accumulation buffer
    private var inputBuffer: [Float] = []

    // MARK: - Initialization

    /// Create a filter from FIR coefficients.
    /// - Parameters:
    ///   - coefficients: FIR filter coefficients (impulse response)
    ///   - blockSize: Processing block size (default: same as tap count for 50% overlap)
    public init(coefficients: [Double], blockSize: Int? = nil) {
        self.taps = coefficients.count
        let blk = blockSize ?? coefficients.count
        self.blockSize = blk

        // FFT size must be >= taps + blockSize - 1, rounded to power of 2
        self.fftSize = FFTProcessor.nextPow2(taps + blk - 1)

        // Pre-compute FFT of filter coefficients (zero-padded to fftSize)
        var re = [Double](repeating: 0, count: fftSize)
        var im = [Double](repeating: 0, count: fftSize)
        for i in 0..<taps { re[i] = coefficients[i] }
        FFTProcessor.fft(&re, &im)
        self.filterFFTReal = re
        self.filterFFTImag = im

        // Initialize overlap buffer
        self.overlapBuffer = [Double](repeating: 0, count: fftSize)
    }

    // MARK: - Processing

    /// Process a buffer of audio samples through the filter.
    /// - Parameter samples: Input audio samples
    /// - Returns: Filtered audio samples (same length as input)
    public mutating func process(_ samples: [Float]) -> [Float] {
        inputBuffer.append(contentsOf: samples)
        var output = [Float]()
        output.reserveCapacity(samples.count)

        while inputBuffer.count >= blockSize {
            let block = Array(inputBuffer.prefix(blockSize))
            inputBuffer.removeFirst(blockSize)

            let filtered = processBlock(block)
            output.append(contentsOf: filtered)
        }

        return output
    }

    /// Process a single block using overlap-add.
    private mutating func processBlock(_ block: [Float]) -> [Float] {
        // Zero-pad input block to fftSize
        var re = [Double](repeating: 0, count: fftSize)
        var im = [Double](repeating: 0, count: fftSize)
        for i in 0..<min(block.count, fftSize) {
            re[i] = Double(block[i])
        }

        // FFT of input
        FFTProcessor.fft(&re, &im)

        // Pointwise complex multiplication with filter FFT
        for i in 0..<fftSize {
            let a = re[i]
            let b = im[i]
            let c = filterFFTReal[i]
            let d = filterFFTImag[i]
            re[i] = a * c - b * d
            im[i] = a * d + b * c
        }

        // Inverse FFT
        FFTProcessor.fft(&re, &im, inverse: true)

        // Add overlap from previous block
        for i in 0..<fftSize {
            re[i] += overlapBuffer[i]
        }

        // Save the tail for next block's overlap
        overlapBuffer = [Double](repeating: 0, count: fftSize)
        for i in blockSize..<fftSize {
            overlapBuffer[i - blockSize] = re[i]
        }

        // Return the valid portion (first blockSize samples)
        var result = [Float](repeating: 0, count: blockSize)
        for i in 0..<blockSize {
            result[i] = Float(re[i])
        }
        return result
    }

    /// Reset the filter state (clear overlap buffer and input buffer).
    public mutating func reset() {
        overlapBuffer = [Double](repeating: 0, count: fftSize)
        inputBuffer.removeAll(keepingCapacity: true)
    }

    // MARK: - Factory Methods

    /// Create a bandpass FIR filter using the window method.
    /// - Parameters:
    ///   - lowCutoff: Lower cutoff frequency in Hz
    ///   - highCutoff: Upper cutoff frequency in Hz
    ///   - sampleRate: Audio sample rate in Hz
    ///   - taps: Number of FIR taps (higher = steeper rolloff). Must be odd.
    /// - Returns: Configured OverlapAddFilter
    public static func bandpass(
        lowCutoff: Double, highCutoff: Double,
        sampleRate: Double, taps: Int = 257
    ) -> OverlapAddFilter {
        let n = taps | 1  // Ensure odd
        let coefficients = designBandpassFIR(
            lowCutoff: lowCutoff, highCutoff: highCutoff,
            sampleRate: sampleRate, taps: n
        )
        return OverlapAddFilter(coefficients: coefficients)
    }

    /// Create a bandpass filter centered around mark and space frequencies with margin.
    /// Convenience for RTTY/FSK applications.
    public static func fskBandpass(
        markFrequency: Double, spaceFrequency: Double,
        margin: Double = 50.0, sampleRate: Double, taps: Int = 257
    ) -> OverlapAddFilter {
        let low = min(markFrequency, spaceFrequency) - margin
        let high = max(markFrequency, spaceFrequency) + margin
        return bandpass(lowCutoff: max(10, low), highCutoff: min(sampleRate / 2 - 10, high),
                        sampleRate: sampleRate, taps: taps)
    }

    /// Create a lowpass FIR filter.
    public static func lowpass(
        cutoff: Double, sampleRate: Double, taps: Int = 257
    ) -> OverlapAddFilter {
        let n = taps | 1
        let coefficients = designLowpassFIR(cutoff: cutoff, sampleRate: sampleRate, taps: n)
        return OverlapAddFilter(coefficients: coefficients)
    }

    /// Create an equalized raised cosine lowpass filter for RTTY matched filtering.
    ///
    /// Based on W7AY's design (http://w7ay.net/site/Technical/EqualizedRaisedCosine/)
    /// as implemented in fldigi's `fftfilt::rtty_filter()`.
    ///
    /// The equalized raised cosine compensates for the rectangular FSK pulse shape
    /// by dividing the standard raised cosine response by the sinc envelope of the
    /// rectangular pulse, achieving zero inter-symbol interference (ISI).
    ///
    /// The filter is designed directly in the frequency domain and applied via
    /// FFT overlap-add convolution. There is no closed-form impulse response.
    ///
    /// - Parameters:
    ///   - baudRate: Symbol rate in baud (e.g. 45.45 for standard RTTY)
    ///   - sampleRate: Audio sample rate in Hz (e.g. 48000)
    ///   - filterLength: FFT filter length (must be power of 2). If nil, automatically computed
    ///     to provide adequate frequency resolution (at least 4 bins across the filter transition).
    ///   - shapeFactor: Frequency scaling factor (1.0-2.0, default 1.4 per fldigi optimization)
    /// - Returns: Configured OverlapAddFilter for use as per-tone baseband lowpass
    public static func equalizedRaisedCosine(
        baudRate: Double, sampleRate: Double,
        filterLength: Int? = nil, shapeFactor: Double = 1.4
    ) -> OverlapAddFilter {
        // Auto-size: ensure at least 4 frequency bins span the filter transition band.
        // fldigi uses 512 at 8000 Hz for 45.45 baud. Scale proportionally for higher rates.
        let fNorm = (baudRate / sampleRate) * shapeFactor
        let minFlen2 = max(256, Int(ceil(4.0 / (2.0 * fNorm))))
        let autoFlen = FFTProcessor.nextPow2(minFlen2 * 2)
        let flen = filterLength ?? autoFlen
        let flen2 = flen / 2

        // Normalized baud rate with shape factor
        let f = fNorm

        // Build lowpass ERC in frequency domain matching fldigi's rtty_filter()
        // This is a baseband lowpass — we'll IFFT to get time-domain coefficients
        var lpRe = [Double](repeating: 0, count: flen)
        var lpIm = [Double](repeating: 0, count: flen)

        for i in 0..<flen2 {
            let x = Double(i) / Double(flen2)

            var dht: Double
            if x <= 0 {
                dht = 1.0
            } else if x > 2.0 * f {
                dht = 0.0
            } else {
                let cosVal = cos(Double.pi * x / (f * 4.0))
                dht = cosVal * cosVal
            }

            let sincArg = 2.0 * Double(i) * f
            let sincVal = abs(sincArg) < 1e-10 ? 1.0 : sin(Double.pi * sincArg) / (Double.pi * sincArg)
            if abs(sincVal) > 1e-10 {
                dht /= sincVal
            }

            // Store as real-valued lowpass response (symmetric, real)
            lpRe[i] = dht
            if i > 0 && i < flen2 {
                lpRe[flen - i] = dht  // Mirror for negative frequencies
            }
        }

        // IFFT to get time-domain impulse response
        FFTProcessor.fft(&lpRe, &lpIm, inverse: true)

        // Extract time-domain coefficients and window with Blackman-Harris
        // The impulse response is centered at index 0, wrapping around.
        // We need to extract flen2 taps centered on the filter.
        var coefficients = [Double](repeating: 0, count: flen2)
        let twopi = 2.0 * Double.pi
        let m = flen2 - 1

        for i in 0..<flen2 {
            // Circularly shift: take samples from [flen-flen2/2 .. flen-1, 0 .. flen2/2-1]
            let srcIdx = (i - flen2 / 2 + flen) % flen
            let w = 0.35875
                  - 0.48829 * cos(twopi * Double(i) / Double(m))
                  + 0.14128 * cos(2.0 * twopi * Double(i) / Double(m))
                  - 0.01168 * cos(3.0 * twopi * Double(i) / Double(m))
            coefficients[i] = lpRe[srcIdx] * w
        }

        // Normalize for unity DC gain
        let sum = coefficients.reduce(0, +)
        if abs(sum) > 1e-10 {
            for i in 0..<flen2 { coefficients[i] /= sum }
        }

        return OverlapAddFilter(coefficients: coefficients)
    }

    /// Create an FSK bandpass filter using equalized raised cosine pulse shaping.
    ///
    /// Creates a bandpass filter spanning mark and space frequencies with the W7AY
    /// equalized raised cosine response applied at each tone. This eliminates ISI
    /// from rectangular FSK pulses while providing bandpass noise rejection.
    ///
    /// The filter is applied as a pre-filter before Goertzel analysis, replacing
    /// the standard IIR or FFT bandpass. The Goertzel then analyzes the ISI-free signal.
    ///
    /// - Parameters:
    ///   - markFrequency: Mark tone frequency in Hz
    ///   - spaceFrequency: Space tone frequency in Hz
    ///   - baudRate: Symbol rate in baud
    ///   - sampleRate: Audio sample rate in Hz
    ///   - taps: FIR filter length (must be odd). If nil, auto-computed.
    ///   - shapeFactor: ERC shape factor (default 1.4)
    /// - Returns: Configured OverlapAddFilter as FSK bandpass with ERC pulse shaping
    public static func fskEqualizedBandpass(
        markFrequency: Double, spaceFrequency: Double,
        baudRate: Double, sampleRate: Double,
        taps: Int? = nil, shapeFactor: Double = 1.4
    ) -> OverlapAddFilter {
        // Filter length: scale from fldigi's 512 at 8000 Hz.
        // At 48 kHz: ~2.5 symbol periods worth of taps.
        let samplesPerBit = sampleRate / baudRate
        let autoTaps = max(257, Int(ceil(samplesPerBit * 2.5)) | 1)
        let n = taps ?? autoTaps

        // Design the lowpass ERC impulse response
        let ercLP = designEqualizedRaisedCosineLowpass(
            baudRate: baudRate, sampleRate: sampleRate,
            taps: n, shapeFactor: shapeFactor
        )

        // Frequency-shift the lowpass ERC to create bandpass at each tone:
        // h_bp(t) = h_lp(t) * 2*cos(2π*f_mark*t) + h_lp(t) * 2*cos(2π*f_space*t)
        // This creates a dual-bandpass filter with ERC pulse shaping at each tone.
        let halfM = Double(n - 1) / 2.0
        var bp = [Double](repeating: 0, count: n)
        let twopi = 2.0 * Double.pi

        for i in 0..<n {
            let t = (Double(i) - halfM) / sampleRate
            let markMod = cos(twopi * markFrequency * t)
            let spaceMod = cos(twopi * spaceFrequency * t)
            bp[i] = ercLP[i] * (markMod + spaceMod)
        }

        return OverlapAddFilter(coefficients: bp)
    }

    /// Design a lowpass equalized raised cosine FIR impulse response.
    /// Used internally to construct bandpass ERC filters.
    private static func designEqualizedRaisedCosineLowpass(
        baudRate: Double, sampleRate: Double,
        taps n: Int, shapeFactor: Double
    ) -> [Double] {
        // Use FFT to compute the impulse response from the frequency-domain design
        let fftSize = FFTProcessor.nextPow2(n * 2)
        let fNorm = (baudRate / sampleRate) * shapeFactor

        var freqRe = [Double](repeating: 0, count: fftSize)
        var freqIm = [Double](repeating: 0, count: fftSize)
        let half = fftSize / 2

        for i in 0...half {
            let x = Double(i) / Double(half)  // 0 to 1 (normalized freq, 1 = Nyquist)

            var dht: Double
            if x <= 0 {
                dht = 1.0
            } else if x > 2.0 * fNorm {
                dht = 0.0
            } else {
                let cosVal = cos(Double.pi * x / (fNorm * 4.0))
                dht = cosVal * cosVal
            }

            // Equalize for rectangular pulse: divide by sinc(2*i*f)
            // where i is the frequency bin index and f = baudRate/sampleRate * shapeFactor
            // This matches fldigi's sinc(2.0 * i * f) formulation
            let sf = 2.0 * Double(i) * fNorm
            let sincVal = abs(sf) < 1e-10 ? 1.0 : sin(Double.pi * sf) / (Double.pi * sf)
            if abs(sincVal) > 1e-10 {
                dht /= sincVal
            }

            freqRe[i] = dht
            if i > 0 && i < half {
                freqRe[fftSize - i] = dht  // Mirror
            }
        }

        // IFFT to get time-domain impulse response
        FFTProcessor.fft(&freqRe, &freqIm, inverse: true)

        // Extract n taps centered on the peak, apply Blackman-Harris window
        var h = [Double](repeating: 0, count: n)
        let twopi = 2.0 * Double.pi

        for i in 0..<n {
            let srcIdx = (i - n / 2 + fftSize) % fftSize
            let w = 0.35875
                  - 0.48829 * cos(twopi * Double(i) / Double(n - 1))
                  + 0.14128 * cos(2.0 * twopi * Double(i) / Double(n - 1))
                  - 0.01168 * cos(3.0 * twopi * Double(i) / Double(n - 1))
            h[i] = freqRe[srcIdx] * w
        }

        // Normalize for unity DC gain
        let sum = h.reduce(0, +)
        if abs(sum) > 1e-10 {
            for i in 0..<n { h[i] /= sum }
        }

        return h
    }

    // MARK: - FIR Design (Windowed Sinc)

    /// Design a bandpass FIR filter using windowed sinc method with Blackman-Harris window.
    private static func designBandpassFIR(
        lowCutoff: Double, highCutoff: Double,
        sampleRate: Double, taps n: Int
    ) -> [Double] {
        // Bandpass = highpass - lowpass, implemented as difference of two lowpass sincs
        let lpHigh = designLowpassFIR(cutoff: highCutoff, sampleRate: sampleRate, taps: n)
        let lpLow = designLowpassFIR(cutoff: lowCutoff, sampleRate: sampleRate, taps: n)

        var bp = [Double](repeating: 0, count: n)
        for i in 0..<n {
            bp[i] = lpHigh[i] - lpLow[i]
        }
        return bp
    }

    /// Design a lowpass FIR filter using windowed sinc with Blackman-Harris window.
    /// Achieves ~-73 dB stopband rejection.
    private static func designLowpassFIR(
        cutoff: Double, sampleRate: Double, taps n: Int
    ) -> [Double] {
        let fc = cutoff / sampleRate  // Normalized cutoff (0 to 0.5)
        let m = n - 1
        let halfM = Double(m) / 2.0

        var h = [Double](repeating: 0, count: n)
        let twopi = 2.0 * Double.pi

        for i in 0..<n {
            let x = Double(i) - halfM

            // Sinc function (lowpass ideal impulse response)
            let sinc: Double
            if abs(x) < 1e-10 {
                sinc = 2.0 * fc
            } else {
                sinc = sin(twopi * fc * x) / (Double.pi * x)
            }

            // Blackman-Harris window (4-term, -92 dB sidelobes)
            let w = 0.35875
                  - 0.48829 * cos(twopi * Double(i) / Double(m))
                  + 0.14128 * cos(2.0 * twopi * Double(i) / Double(m))
                  - 0.01168 * cos(3.0 * twopi * Double(i) / Double(m))

            h[i] = sinc * w
        }

        // Normalize for unity gain at passband center
        let sum = h.reduce(0, +)
        if abs(sum) > 1e-10 {
            for i in 0..<n { h[i] /= sum }
        }

        return h
    }
}
