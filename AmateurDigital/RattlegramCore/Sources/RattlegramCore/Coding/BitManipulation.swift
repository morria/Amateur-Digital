/*
 Bit manipulation of byte arrays - ported from bitman.hh
 Original Copyright 2018 Ahmet Inan <inan@aicodix.de>
 */

@inlinable
public func xorBEBit(_ buf: inout [UInt8], _ pos: Int, _ val: Bool) {
    buf[pos / 8] ^= (val ? 1 : 0) << (7 - pos % 8)
}

@inlinable
public func xorLEBit(_ buf: inout [UInt8], _ pos: Int, _ val: Bool) {
    buf[pos / 8] ^= (val ? 1 : 0) << (pos % 8)
}

@inlinable
public func setBEBit(_ buf: inout [UInt8], _ pos: Int, _ val: Bool) {
    let bit = 7 - pos % 8
    buf[pos / 8] = (~(1 << bit) & buf[pos / 8]) | ((val ? 1 : 0) << bit)
}

@inlinable
public func setLEBit(_ buf: inout [UInt8], _ pos: Int, _ val: Bool) {
    let bit = pos % 8
    buf[pos / 8] = (~(1 << bit) & buf[pos / 8]) | ((val ? 1 : 0) << bit)
}

@inlinable
public func getBEBit(_ buf: [UInt8], _ pos: Int) -> Bool {
    (buf[pos / 8] >> (7 - pos % 8)) & 1 != 0
}

@inlinable
public func getLEBit(_ buf: [UInt8], _ pos: Int) -> Bool {
    (buf[pos / 8] >> (pos % 8)) & 1 != 0
}
