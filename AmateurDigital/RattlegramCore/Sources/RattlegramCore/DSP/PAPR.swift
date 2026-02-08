/*
 Peak-to-average power ratio improvement - ported from papr.hh
 Original Copyright 2021 Ahmet Inan <inan@aicodix.de>
 */

import Foundation

public struct ImprovePAPR {
    private let size: Int
    private let factor: Int
    private let fwd: FFT
    private let bwd: FFT
    private var temp: [cmplx]
    private var over: [cmplx]
    private var used: [Bool]

    public init(size: Int, oversamplingFactor: Int) {
        self.size = size
        self.factor = oversamplingFactor
        let totalSize = factor * size
        self.fwd = FFT(size: totalSize, sign: 1)
        self.bwd = FFT(size: totalSize, sign: -1)
        self.temp = [cmplx](repeating: cmplx(), count: totalSize)
        self.over = [cmplx](repeating: cmplx(), count: totalSize)
        self.used = [Bool](repeating: false, count: size)
    }

    public mutating func improve(_ freq: inout [cmplx]) {
        if factor == 1 {
            improveFactor1(&freq)
        } else {
            improveFactorN(&freq)
        }
    }

    private mutating func improveFactor1(_ freq: inout [cmplx]) {
        for i in 0..<size {
            used[i] = freq[i].real != 0 || freq[i].imag != 0
        }
        bwd.transform(&temp, freq)
        let scale: Float = 1 / Foundation.sqrt(Float(size))
        for i in 0..<size {
            temp[i] *= scale
        }
        for i in 0..<size {
            let pwr = norm(temp[i])
            if pwr > 1 {
                temp[i] /= Foundation.sqrt(pwr)
            }
        }
        fwd.transform(&freq, temp)
        for i in 0..<size {
            if used[i] {
                freq[i] *= scale
            } else {
                freq[i] = cmplx()
            }
        }
    }

    private mutating func improveFactorN(_ freq: inout [cmplx]) {
        for i in 0..<size {
            used[i] = freq[i].real != 0 || freq[i].imag != 0
        }
        // Zero-pad in frequency domain
        for i in 0..<(size / 2) {
            over[i] = freq[i]
        }
        for i in (size / 2)..<(factor * size - size / 2) {
            over[i] = cmplx()
        }
        for i in (size / 2)..<size {
            over[size * (factor - 1) + i] = freq[i]
        }
        bwd.transform(&temp, over)
        let scale: Float = 1 / Foundation.sqrt(Float(factor * size))
        for i in 0..<(factor * size) {
            temp[i] *= scale
        }
        for i in 0..<(factor * size) {
            let pwr = norm(temp[i])
            if pwr > 1 {
                temp[i] /= Foundation.sqrt(pwr)
            }
        }
        fwd.transform(&over, temp)
        for i in 0..<(size / 2) {
            if used[i] {
                freq[i] = scale * over[i]
            }
        }
        for i in (size / 2)..<size {
            if used[i] {
                freq[i] = scale * over[size * (factor - 1) + i]
            }
        }
    }
}
