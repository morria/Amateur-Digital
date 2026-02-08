/*
 Utility functions - ported from utils.hh
 Original Copyright 2018 Ahmet Inan <inan@aicodix.de>
 */

import Foundation

@inlinable
public func signum<T: Comparable>(_ v: T) -> Int where T: ExpressibleByIntegerLiteral {
    (v > 0 ? 1 : 0) - (v < 0 ? 1 : 0)
}

@inlinable
public func lerp(_ a: Float, _ b: Float, _ x: Float) -> Float {
    (1 - x) * a + x * b
}

@inlinable
public func sinc(_ x: Float) -> Float {
    x == 0 ? 1 : Foundation.sin(Const.pi * x) / (Const.pi * x)
}

@inlinable
public func delta(_ x: Float) -> Float {
    x == 0 ? 1 : 0
}

@inlinable
public func normalPdf(_ x: Float, _ m: Float, _ s: Float) -> Float {
    Foundation.exp(-Foundation.pow((x - m) / s, 2) / 2) / (Const.sqrtTwoPi * s)
}

/// NRZ encoding: 0 → +1, 1 → -1
@inlinable
public func nrz(_ bit: Int) -> Int {
    1 - 2 * bit
}
