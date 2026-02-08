/*
 Maximum length sequence - ported from mls.hh
 Original Copyright 2020 Ahmet Inan <inan@aicodix.de>
 */

public struct MLS {
    private let poly: Int
    private let test: Int
    private var reg: Int

    private static func hibit(_ n: UInt32) -> UInt32 {
        var n = n
        n |= n >> 1
        n |= n >> 2
        n |= n >> 4
        n |= n >> 8
        n |= n >> 16
        return n ^ (n >> 1)
    }

    public init(poly: Int = 0b100000000000000000001001, reg: Int = 1) {
        self.poly = poly
        self.test = Int(Self.hibit(UInt32(poly)) >> 1)
        self.reg = reg
    }

    public mutating func reset(_ r: Int = 1) {
        reg = r
    }

    @discardableResult
    public mutating func next() -> Bool {
        let fb = (reg & test) != 0
        reg <<= 1
        reg ^= (fb ? 1 : 0) * poly
        return fb
    }

    public mutating func bad(_ r: Int = 1) -> Bool {
        reg = r
        let len = Int(Self.hibit(UInt32(poly))) - 1
        for _ in 1..<len {
            next()
            if reg == r { return true }
        }
        next()
        return reg != r
    }
}
