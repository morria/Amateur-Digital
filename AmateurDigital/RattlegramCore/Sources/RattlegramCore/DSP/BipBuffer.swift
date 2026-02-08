/*
 Bip buffer (circular buffer with contiguous view) - ported from bip_buffer.hh
 Original Copyright 2020 Ahmet Inan <inan@aicodix.de>
 */

public struct BipBuffer {
    private var buf: [cmplx]
    private var pos0: Int
    private var pos1: Int
    private let num: Int

    public init(size: Int) {
        self.num = size
        self.buf = [cmplx](repeating: cmplx(), count: 2 * size)
        self.pos0 = 0
        self.pos1 = size
    }

    /// Returns the start index of the contiguous view in the buffer
    public var readOffset: Int {
        min(pos0, pos1)
    }

    /// Read a contiguous slice of `num` elements
    public func read() -> ArraySlice<cmplx> {
        let off = min(pos0, pos1)
        return buf[off..<(off + num)]
    }

    /// Write a value and return the read offset into the internal buffer
    @discardableResult
    public mutating func write(_ input: cmplx) -> Int {
        buf[pos0] = input
        buf[pos1] = input
        pos0 += 1
        if pos0 >= 2 * num { pos0 = 0 }
        pos1 += 1
        if pos1 >= 2 * num { pos1 = 0 }
        return min(pos0, pos1)
    }

    /// Direct access to underlying buffer for FFT operations
    public func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<cmplx>) throws -> R) rethrows -> R {
        try buf.withUnsafeBufferPointer(body)
    }

    public subscript(index: Int) -> cmplx {
        buf[index]
    }

    public var count: Int { num }

    /// Access the raw internal buffer (2*num elements) without copying.
    /// Use with readOffset for zero-copy sample access.
    public var rawBuffer: [cmplx] { buf }
}
