/*
 Digital delay line - ported from delay.hh
 Original Copyright 2020 Ahmet Inan <inan@aicodix.de>
 */

public struct Delay<T> {
    private var buf: [T]
    private var pos: Int
    private let num: Int

    public init(size: Int, initial: T) {
        self.num = size
        self.buf = [T](repeating: initial, count: size)
        self.pos = 0
    }

    public mutating func process(_ input: T) -> T {
        let tmp = buf[pos]
        buf[pos] = input
        pos += 1
        if pos >= num { pos = 0 }
        return tmp
    }
}
