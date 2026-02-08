/*
 Pseudorandom number generators - ported from xorshift.hh
 Original Copyright 2018 Ahmet Inan <inan@aicodix.de>
 */

public struct Xorshift32 {
    public static let defaultSeed: UInt32 = 2463534242

    private var y: UInt32

    public init(seed: UInt32 = Xorshift32.defaultSeed) {
        self.y = seed
    }

    public mutating func reset(_ seed: UInt32 = Xorshift32.defaultSeed) {
        y = seed
    }

    @discardableResult
    public mutating func next() -> UInt32 {
        y ^= y &<< 13
        y ^= y >> 17
        y ^= y &<< 5
        return y
    }
}

public struct Xorshift64 {
    public static let defaultSeed: UInt64 = 88172645463325252

    private var x: UInt64

    public init(seed: UInt64 = Xorshift64.defaultSeed) {
        self.x = seed
    }

    public mutating func reset(_ seed: UInt64 = Xorshift64.defaultSeed) {
        x = seed
    }

    @discardableResult
    public mutating func next() -> UInt64 {
        x ^= x &<< 13
        x ^= x >> 7
        x ^= x &<< 17
        return x
    }
}

public struct Xorshift128 {
    public static let defaultX: UInt32 = 123456789
    public static let defaultY: UInt32 = 362436069
    public static let defaultZ: UInt32 = 521288629
    public static let defaultW: UInt32 = 88675123

    private var x, y, z, w: UInt32

    public init(x: UInt32 = defaultX, y: UInt32 = defaultY,
                z: UInt32 = defaultZ, w: UInt32 = defaultW) {
        self.x = x; self.y = y; self.z = z; self.w = w
    }

    public mutating func reset(x: UInt32 = defaultX, y: UInt32 = defaultY,
                                z: UInt32 = defaultZ, w: UInt32 = defaultW) {
        self.x = x; self.y = y; self.z = z; self.w = w
    }

    @discardableResult
    public mutating func next() -> UInt32 {
        let t = (x ^ (x &<< 11))
        x = y; y = z; z = w
        w = (w ^ (w >> 19)) ^ (t ^ (t >> 8))
        return w
    }
}
