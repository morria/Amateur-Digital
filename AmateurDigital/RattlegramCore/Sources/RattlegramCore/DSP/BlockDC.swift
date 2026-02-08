/*
 DC Blocker - ported from blockdc.hh
 Original Copyright 2019 Ahmet Inan <inan@aicodix.de>
 */

public struct BlockDC {
    private var x1: Float = 0
    private var y1: Float = 0
    private var a: Float = 0
    private var b: Float = 0.5

    public init() {}

    public mutating func samples(_ s: Int) {
        a = Float(s - 1) / Float(s)
        b = (1 + a) / 2
    }

    public mutating func process(_ x0: Float) -> Float {
        let y0 = b * (x0 - x1) + a * y1
        x1 = x0
        y1 = y0
        return y0
    }
}
