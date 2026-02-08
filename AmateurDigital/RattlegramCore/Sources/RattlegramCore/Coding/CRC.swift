/*
 Cyclic redundancy check - ported from crc.hh
 Original Copyright 2018 Ahmet Inan <inan@aicodix.de>
 */

public struct CRC<T: FixedWidthInteger & UnsignedInteger> {
    private var lut: [T]
    private let poly: T
    private var crc: T

    public init(poly: T, initial: T = 0) {
        self.poly = poly
        self.crc = initial
        self.lut = [T](repeating: 0, count: 256)
        for j in 0..<256 {
            var tmp = T(j)
            for _ in 0..<8 {
                tmp = Self.updateBit(tmp, data: false, poly: poly)
            }
            lut[j] = tmp
        }
    }

    private static func updateBit(_ prev: T, data: Bool, poly: T) -> T {
        let tmp = prev ^ (data ? 1 : 0)
        return (prev >> 1) ^ ((tmp & 1) * poly)
    }

    public mutating func reset(_ v: T = 0) {
        crc = v
    }

    public var value: T { crc }

    public mutating func update(bit data: Bool) {
        crc = Self.updateBit(crc, data: data, poly: poly)
    }

    public mutating func update(byte data: UInt8) {
        let tmp = crc ^ T(data)
        crc = (crc >> 8) ^ lut[Int(tmp & 255)]
    }

    public mutating func update(uint16 data: UInt16) {
        update(byte: UInt8(data & 0xFF))
        update(byte: UInt8((data >> 8) & 0xFF))
    }

    public mutating func update(uint32 data: UInt32) {
        update(byte: UInt8(data & 0xFF))
        update(byte: UInt8((data >> 8) & 0xFF))
        update(byte: UInt8((data >> 16) & 0xFF))
        update(byte: UInt8((data >> 24) & 0xFF))
    }

    public mutating func update(uint64 data: UInt64) {
        update(byte: UInt8(data & 0xFF))
        update(byte: UInt8((data >> 8) & 0xFF))
        update(byte: UInt8((data >> 16) & 0xFF))
        update(byte: UInt8((data >> 24) & 0xFF))
        update(byte: UInt8((data >> 32) & 0xFF))
        update(byte: UInt8((data >> 40) & 0xFF))
        update(byte: UInt8((data >> 48) & 0xFF))
        update(byte: UInt8((data >> 56) & 0xFF))
    }
}

// Specialization for UInt8 CRC (matches C++ template specialization)
extension CRC where T == UInt8 {
    public mutating func updateByte(_ data: UInt8) {
        crc = lut[Int(crc ^ data)]
    }
}
