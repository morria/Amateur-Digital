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
