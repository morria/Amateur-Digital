/*
 Polar helper for Int8 scalar operations - ported from polar_helper.hh
 Original Copyright 2020 Ahmet Inan <inan@aicodix.de>
 */

import Foundation

public enum PolarHelper {
    @inlinable
    public static func one() -> Int8 { 1 }

    @inlinable
    public static func zero() -> Int8 { 0 }

    @inlinable
    public static func signum(_ v: Int8) -> Int8 {
        (v > 0 ? 1 : 0) - (v < 0 ? 1 : 0)
    }

    @inlinable
    public static func quant(_ input: Float) -> Int8 {
        Int8(clamping: Int(Foundation.nearbyint(min(max(input, -127), 127))))
    }

    @inlinable
    public static func qabs(_ a: Int8) -> Int8 {
        let clamped = max(a, -127) // avoid overflow on Int8.min
        return clamped < 0 ? -clamped : clamped
    }

    @inlinable
    public static func qmin(_ a: Int8, _ b: Int8) -> Int8 {
        min(a, b)
    }

    @inlinable
    public static func qadd(_ a: Int8, _ b: Int8) -> Int8 {
        let sum = Int16(a) + Int16(b)
        return Int8(clamping: min(max(sum, -127), 127))
    }

    @inlinable
    public static func qmul(_ a: Int8, _ b: Int8) -> Int8 {
        a * b // only used for hard decisions (±1)
    }

    @inlinable
    public static func prod(_ a: Int8, _ b: Int8) -> Int8 {
        signum(a) * signum(b) * qmin(qabs(a), qabs(b))
    }

    @inlinable
    public static func madd(_ a: Int8, _ b: Int8, _ c: Int8) -> Int8 {
        let result = Int16(a) * Int16(b) + Int16(c)
        return Int8(clamping: min(max(result, -127), 127))
    }
}
