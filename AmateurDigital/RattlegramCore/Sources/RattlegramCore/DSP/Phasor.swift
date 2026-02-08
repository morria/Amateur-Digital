/*
 Numerically controlled oscillator - ported from phasor.hh
 Original Copyright 2019 Ahmet Inan <inan@aicodix.de>
 */

import Foundation

public struct Phasor {
    private var prev: cmplx = cmplx(1, 0)
    private var delta: cmplx = cmplx(1, 0)

    public init() {}

    public mutating func omega(_ n: Int, _ N: Int) {
        let angle = Const.twoPi * Float(n) / Float(N)
        delta = cmplx(Foundation.cos(angle), Foundation.sin(angle))
    }

    public mutating func omega(_ v: Float) {
        delta = cmplx(Foundation.cos(v), Foundation.sin(v))
    }

    public mutating func freq(_ v: Float) {
        omega(Const.twoPi * v)
    }

    public mutating func reset() {
        prev = cmplx(1, 0)
    }

    @discardableResult
    public mutating func next() -> cmplx {
        let tmp = prev
        prev *= delta
        let mag = abs(prev)
        if mag > 0 {
            prev /= mag
        }
        return tmp
    }
}
