/*
 Polar encoder - ported from polar_encoder.hh
 Original Copyright 2020 Ahmet Inan <inan@aicodix.de>
 */

/// Non-systematic polar encoder (single pass) - used by the decoder's systematic() step
public struct PolarNonSysEnc {
    public init() {}

    private static func get(_ bits: [UInt32], _ idx: Int) -> Bool {
        (bits[idx / 32] >> (idx % 32)) & 1 != 0
    }

    public func encode(_ codeword: inout [Int8], _ message: [Int8], _ frozen: [UInt32], _ level: Int) {
        let length = 1 << level
        var msgIdx = 0
        for i in stride(from: 0, to: length, by: 2) {
            let msg0: Int8 = Self.get(frozen, i) ? PolarHelper.one() : { let v = message[msgIdx]; msgIdx += 1; return v }()
            let msg1: Int8 = Self.get(frozen, i + 1) ? PolarHelper.one() : { let v = message[msgIdx]; msgIdx += 1; return v }()
            codeword[i] = PolarHelper.qmul(msg0, msg1)
            codeword[i + 1] = msg1
        }
        var h = 2
        while h < length {
            for i in stride(from: 0, to: length, by: 2 * h) {
                for j in i..<(i + h) {
                    codeword[j] = PolarHelper.qmul(codeword[j], codeword[j + h])
                }
            }
            h *= 2
        }
    }
}

/// Systematic polar encoder (two-pass) - used for encoding messages
public struct PolarSysEnc {
    public init() {}

    private static func get(_ bits: [UInt32], _ idx: Int) -> Bool {
        (bits[idx / 32] >> (idx % 32)) & 1 != 0
    }

    public func encode(_ codeword: inout [Int8], _ message: [Int8], _ frozen: [UInt32], _ level: Int) {
        let length = 1 << level
        var msgIdx = 0
        // First pass: insert message/frozen bits and first butterfly
        for i in stride(from: 0, to: length, by: 2) {
            let msg0: Int8 = Self.get(frozen, i) ? PolarHelper.one() : { let v = message[msgIdx]; msgIdx += 1; return v }()
            let msg1: Int8 = Self.get(frozen, i + 1) ? PolarHelper.one() : { let v = message[msgIdx]; msgIdx += 1; return v }()
            codeword[i] = PolarHelper.qmul(msg0, msg1)
            codeword[i + 1] = msg1
        }
        // Subsequent butterflies
        var h = 2
        while h < length {
            for i in stride(from: 0, to: length, by: 2 * h) {
                for j in i..<(i + h) {
                    codeword[j] = PolarHelper.qmul(codeword[j], codeword[j + h])
                }
            }
            h *= 2
        }
        // Second pass for systematic encoding
        msgIdx = 0
        for i in stride(from: 0, to: length, by: 2) {
            let msg0: Int8 = Self.get(frozen, i) ? PolarHelper.one() : codeword[i]
            let msg1: Int8 = Self.get(frozen, i + 1) ? PolarHelper.one() : codeword[i + 1]
            codeword[i] = PolarHelper.qmul(msg0, msg1)
            codeword[i + 1] = msg1
        }
        h = 2
        while h < length {
            for i in stride(from: 0, to: length, by: 2 * h) {
                for j in i..<(i + h) {
                    codeword[j] = PolarHelper.qmul(codeword[j], codeword[j + h])
                }
            }
            h *= 2
        }
    }
}
