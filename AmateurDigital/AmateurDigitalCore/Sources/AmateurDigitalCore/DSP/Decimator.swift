//
//  Decimator.swift
//  AmateurDigitalCore
//
//  Sample rate decimation with anti-alias filtering.
//  Reduces 48 kHz audio to 8 kHz (RTTY/PSK) or 12 kHz (JS8Call).
//

import Foundation

/// Sample rate decimator with built-in anti-alias low-pass filter.
///
/// Downsamples audio by an integer factor with proper anti-aliasing to prevent
/// spectral foldover. Reduces CPU load in all downstream processing stages.
///
/// Usage:
/// ```swift
/// var decimator = Decimator(factor: 6, inputRate: 48000)  // 48kHz -> 8kHz
/// let decimated = decimator.process(samples)
/// ```
public struct Decimator {

    /// Decimation factor (e.g., 6 for 48kHz -> 8kHz)
    public let factor: Int

    /// Input sample rate
    public let inputRate: Double

    /// Output sample rate (inputRate / factor)
    public var outputRate: Double { inputRate / Double(factor) }

    /// Anti-alias FIR filter coefficients
    private let filterCoeffs: [Float]

    /// Filter delay line
    private var delayLine: [Float]

    /// Current position in the decimation cycle
    private var phaseCounter: Int = 0

    /// Create a decimator with an anti-alias filter.
    /// - Parameters:
    ///   - factor: Decimation factor (e.g., 4 for 48kHz->12kHz, 6 for 48kHz->8kHz)
    ///   - inputRate: Input sample rate in Hz (default 48000)
    ///   - filterTaps: Number of FIR filter taps (default: 8 * factor + 1)
    public init(factor: Int, inputRate: Double = 48000, filterTaps: Int? = nil) {
        self.factor = max(1, factor)
        self.inputRate = inputRate

        let taps = filterTaps ?? (8 * self.factor + 1) | 1  // Ensure odd
        self.filterCoeffs = Self.designAntiAliasFilter(taps: taps, factor: self.factor)
        self.delayLine = [Float](repeating: 0, count: taps)
    }

    /// Process a buffer of input samples and return decimated output.
    /// - Parameter samples: Input samples at the original rate
    /// - Returns: Decimated samples at outputRate
    public mutating func process(_ samples: [Float]) -> [Float] {
        var output = [Float]()
        output.reserveCapacity(samples.count / factor + 1)

        let taps = filterCoeffs.count

        for sample in samples {
            // Shift delay line and insert new sample
            for i in stride(from: taps - 1, through: 1, by: -1) {
                delayLine[i] = delayLine[i - 1]
            }
            delayLine[0] = sample

            phaseCounter += 1
            if phaseCounter >= factor {
                phaseCounter = 0

                // Compute FIR output (dot product of delay line and coefficients)
                var sum: Float = 0
                for i in 0..<taps {
                    sum += delayLine[i] * filterCoeffs[i]
                }
                output.append(sum)
            }
        }

        return output
    }

    /// Reset the decimator state.
    public mutating func reset() {
        delayLine = [Float](repeating: 0, count: filterCoeffs.count)
        phaseCounter = 0
    }

    // MARK: - Filter Design

    /// Design a low-pass FIR anti-alias filter for decimation.
    /// Cutoff at 0.45 * (outputRate / 2) to prevent aliasing with margin.
    private static func designAntiAliasFilter(taps n: Int, factor: Int) -> [Float] {
        // Cutoff frequency: 0.45 / factor (normalized to input Nyquist)
        // The 0.45 factor provides transition band margin
        let fc = 0.45 / Double(factor)
        let m = n - 1
        let halfM = Double(m) / 2.0
        let twopi = 2.0 * Double.pi

        var h = [Float](repeating: 0, count: n)

        for i in 0..<n {
            let x = Double(i) - halfM

            // Sinc function
            let sinc: Double
            if abs(x) < 1e-10 {
                sinc = 2.0 * fc
            } else {
                sinc = sin(twopi * fc * x) / (Double.pi * x)
            }

            // Blackman window (good balance of rolloff and sidelobe suppression)
            let w = 0.42 - 0.5 * cos(twopi * Double(i) / Double(m))
                         + 0.08 * cos(2.0 * twopi * Double(i) / Double(m))

            h[i] = Float(sinc * w)
        }

        // Normalize for unity DC gain
        let sum = h.reduce(0, +)
        if abs(sum) > 1e-10 {
            for i in 0..<n { h[i] /= sum }
        }

        return h
    }

    // MARK: - Presets

    /// Decimator for 48 kHz -> 8 kHz (factor 6). Suitable for RTTY, PSK.
    public static func to8kHz(from inputRate: Double = 48000) -> Decimator {
        Decimator(factor: Int(inputRate / 8000), inputRate: inputRate)
    }

    /// Decimator for 48 kHz -> 12 kHz (factor 4). Suitable for JS8Call, CW.
    public static func to12kHz(from inputRate: Double = 48000) -> Decimator {
        Decimator(factor: Int(inputRate / 12000), inputRate: inputRate)
    }
}
