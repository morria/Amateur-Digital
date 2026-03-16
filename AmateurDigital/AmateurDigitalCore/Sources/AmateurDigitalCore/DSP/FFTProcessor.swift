//
//  FFTProcessor.swift
//  AmateurDigitalCore
//
//  Radix-2 Cooley-Tukey FFT for JS8Call spectrogram and symbol extraction.
//

import Foundation

public struct FFTProcessor {

    /// Next power of 2 >= n.
    public static func nextPow2(_ n: Int) -> Int {
        var p = 1
        while p < n { p <<= 1 }
        return p
    }

    /// In-place radix-2 complex FFT (Cooley-Tukey decimation-in-time).
    /// `real` and `imag` must have the same power-of-2 length.
    /// Set `inverse` to true for the inverse transform (includes 1/N scaling).
    public static func fft(_ real: inout [Double], _ imag: inout [Double], inverse: Bool = false) {
        let n = real.count
        guard n > 1 && (n & (n - 1)) == 0 else { return } // must be power of 2

        // Bit-reversal permutation
        var j = 0
        for i in 0..<n {
            if i < j {
                real.swapAt(i, j)
                imag.swapAt(i, j)
            }
            var m = n >> 1
            while m >= 1 && j >= m {
                j -= m
                m >>= 1
            }
            j += m
        }

        // Butterfly stages
        var step = 1
        while step < n {
            let halfStep = step
            step <<= 1
            let angle = (inverse ? 1.0 : -1.0) * Double.pi / Double(halfStep)
            let wR = cos(angle)
            let wI = sin(angle)

            var k = 0
            while k < n {
                var curR = 1.0
                var curI = 0.0
                for m in 0..<halfStep {
                    let i1 = k + m
                    let i2 = k + m + halfStep
                    let tR = curR * real[i2] - curI * imag[i2]
                    let tI = curR * imag[i2] + curI * real[i2]
                    real[i2] = real[i1] - tR
                    imag[i2] = imag[i1] - tI
                    real[i1] = real[i1] + tR
                    imag[i1] = imag[i1] + tI
                    let newR = curR * wR - curI * wI
                    let newI = curR * wI + curI * wR
                    curR = newR
                    curI = newI
                }
                k += step
            }
        }

        if inverse {
            let scale = 1.0 / Double(n)
            for i in 0..<n {
                real[i] *= scale
                imag[i] *= scale
            }
        }
    }

    /// Compute power spectrum (|X[k]|^2) of a real input signal.
    /// Input is zero-padded to the next power of 2. Returns N/2 bins.
    public static func powerSpectrum(_ input: [Double]) -> [Double] {
        let n = nextPow2(input.count)
        var re = [Double](repeating: 0, count: n)
        var im = [Double](repeating: 0, count: n)
        for i in 0..<input.count { re[i] = input[i] }
        fft(&re, &im)
        let half = n / 2
        var power = [Double](repeating: 0, count: half)
        for i in 0..<half {
            power[i] = re[i] * re[i] + im[i] * im[i]
        }
        return power
    }
}
