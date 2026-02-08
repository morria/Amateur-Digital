/*
 Discrete Hilbert transformation - ported from hilbert.hh
 Original Copyright 2020 Ahmet Inan <inan@aicodix.de>
 */

import Foundation

public struct Hilbert {
    private let taps: Int
    private var real: [Float]
    private let imco: [Float]
    private let reco: Float

    public init(taps: Int = 129, a: Float = 2) {
        precondition((taps - 1) % 4 == 0, "TAPS-1 must be divisible by four")
        self.taps = taps
        self.real = [Float](repeating: 0, count: taps)
        let kaiser = Kaiser(a: a)
        self.reco = kaiser.evaluate(n: (taps - 1) / 2, total: taps)
        let imcoCount = (taps - 1) / 4
        var imcoTmp = [Float](repeating: 0, count: imcoCount)
        for i in 0..<imcoCount {
            imcoTmp[i] = kaiser.evaluate(n: (2 * i + 1) + (taps - 1) / 2, total: taps) *
                2 / (Float(2 * i + 1) * Const.pi)
        }
        self.imco = imcoTmp
    }

    public mutating func process(_ input: Float) -> cmplx {
        let half = (taps - 1) / 2
        let re = reco * real[half]
        var im = imco[0] * (real[half - 1] - real[half + 1])
        for i in 1..<(taps - 1) / 4 {
            im += imco[i] * (real[half - (2 * i + 1)] - real[half + (2 * i + 1)])
        }
        for i in 0..<(taps - 1) {
            real[i] = real[i + 1]
        }
        real[taps - 1] = input
        return cmplx(re, im)
    }
}
