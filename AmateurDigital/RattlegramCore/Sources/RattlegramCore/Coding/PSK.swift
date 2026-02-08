/*
 Phase-shift keying - ported from psk.hh
 Original Copyright 2021 Ahmet Inan <inan@aicodix.de>
 */

import Foundation

public enum BPSK {
    public static let dist: Float = 2

    public static func hard(_ c: cmplx) -> Int8 {
        c.real < 0 ? -1 : 1
    }

    public static func soft(_ c: cmplx, precision: Float) -> Int8 {
        quantize(precision: precision, value: c.real)
    }

    public static func map(_ b: Int8) -> cmplx {
        cmplx(Float(b), 0)
    }

    private static func quantize(precision: Float, value: Float) -> Int8 {
        let v = value * dist * precision
        return Int8(clamping: Int(Foundation.nearbyint(min(max(v, -128), 127))))
    }
}

public enum QPSK {
    public static let rcpSqrt2: Float = 0.70710678118654752440
    public static let dist: Float = 2 * 0.70710678118654752440

    public static func hard(_ c: cmplx) -> (Int8, Int8) {
        let b0: Int8 = c.real < 0 ? -1 : 1
        let b1: Int8 = c.imag < 0 ? -1 : 1
        return (b0, b1)
    }

    public static func soft(_ c: cmplx, precision: Float) -> (Int8, Int8) {
        (quantize(precision: precision, value: c.real),
         quantize(precision: precision, value: c.imag))
    }

    public static func map(_ b0: Int8, _ b1: Int8) -> cmplx {
        cmplx(rcpSqrt2 * Float(b0), rcpSqrt2 * Float(b1))
    }

    /// Soft decision into a buffer (matches C++ interface for mod_soft)
    public static func soft(_ b: inout [Int8], offset: Int, _ c: cmplx, precision: Float) {
        let s = soft(c, precision: precision)
        b[offset] = s.0
        b[offset + 1] = s.1
    }

    /// Hard decision into a buffer
    public static func hard(_ b: inout [Int8], offset: Int, _ c: cmplx) {
        let h = hard(c)
        b[offset] = h.0
        b[offset + 1] = h.1
    }

    /// Map from buffer
    public static func map(_ b: [Int8], offset: Int) -> cmplx {
        map(b[offset], b[offset + 1])
    }

    private static func quantize(precision: Float, value: Float) -> Int8 {
        let v = value * dist * precision
        return Int8(clamping: Int(Foundation.nearbyint(min(max(v, -128), 127))))
    }
}
