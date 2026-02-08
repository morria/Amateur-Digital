/*
 Window functions - ported from window.hh
 Original Copyright 2018 Ahmet Inan <inan@aicodix.de>
 */

import Foundation

public enum Hann {
    public static func evaluate(n: Int, total N: Int) -> Float {
        0.5 * (1 - Foundation.cos(Const.twoPi * Float(n) / Float(N - 1)))
    }
}

public struct Kaiser {
    private let a: Float

    public init(a: Float) {
        self.a = a
    }

    private static func i0(_ x: Float) -> Float {
        var sum: Float = 1
        var val: Float = 1
        for n in 1..<35 {
            val *= x / Float(2 * n)
            let term = val * val
            sum += term
            if term < sum * 1e-10 { break }
        }
        return sum
    }

    public func evaluate(n: Int, total N: Int) -> Float {
        let arg = 1 - Foundation.pow(Float(2 * n) / Float(N - 1) - 1, 2)
        return Self.i0(Const.pi * a * Foundation.sqrt(Swift.max(0, arg))) /
               Self.i0(Const.pi * a)
    }
}

public struct Blackman {
    private let a0: Float
    private let a1: Float
    private let a2: Float

    public init() {
        // "exact Blackman"
        a0 = 7938.0 / 18608.0
        a1 = 9240.0 / 18608.0
        a2 = 1430.0 / 18608.0
    }

    public init(a: Float) {
        a0 = (1 - a) / 2
        a1 = 0.5
        a2 = a / 2
    }

    public func evaluate(n: Int, total N: Int) -> Float {
        a0 - a1 * Foundation.cos(Const.twoPi * Float(n) / Float(N - 1)) +
            a2 * Foundation.cos(Const.twoPi * Float(2 * n % (N - 1)) / Float(N - 1))
    }
}
