/*
 Simple moving average (SWA-based) - ported from sma.hh / swa.hh
 Original Copyright 2019/2020 Ahmet Inan <inan@aicodix.de>
 */

/// Sliding Window Aggregator - binary tree approach for O(log N) sliding window sum
public struct SWA<T: AdditiveArithmetic> {
    private var tree: [T]
    private var leaf: Int
    private let num: Int

    public init(size: Int, identity: T) {
        self.num = size
        self.tree = [T](repeating: identity, count: 2 * size)
        self.leaf = size
    }

    public mutating func process(_ input: T) -> T {
        tree[leaf] = input
        var child = leaf
        var parent = leaf / 2
        while parent > 0 {
            tree[parent] = tree[child] + tree[child ^ 1]
            child = parent
            parent /= 2
        }
        leaf += 1
        if leaf >= 2 * num { leaf = num }
        return tree[1]
    }
}

/// SMA4 - Simple Moving Average using SWA (matches C++ SMA4)
public struct SMA4<T: AdditiveArithmetic & FloatingPoint> {
    private var swa: SWA<T>
    private let num: T
    private let normalize: Bool

    public init(size: Int, normalize: Bool = true) {
        self.swa = SWA(size: size, identity: T.zero)
        self.num = T(size)
        self.normalize = normalize
    }

    public mutating func process(_ input: T) -> T {
        let sum = swa.process(input)
        return normalize ? sum / num : sum
    }
}

/// SMA4 specialized for cmplx
public struct SMA4Complex {
    private var swa: SWA<cmplx>
    private let num: Float
    private let normalize: Bool

    public init(size: Int, normalize: Bool = true) {
        self.swa = SWA(size: size, identity: cmplx())
        self.num = Float(size)
        self.normalize = normalize
    }

    public mutating func process(_ input: cmplx) -> cmplx {
        let sum = swa.process(input)
        return normalize ? sum / num : sum
    }
}
