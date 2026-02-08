/*
 CA-SCL polar coding wrapper - ported from polar.hh
 Original Copyright 2022 Ahmet Inan <inan@aicodix.de>
 */

public final class PolarEncoderWrapper {
    private static let codeOrder = 11
    private static let maxBits = 1360 + 32
    private var crc = CRC<UInt32>(poly: 0x8F6E37A0)
    private let encode = PolarSysEnc()
    private var mesg = [Int8](repeating: 0, count: maxBits)

    public init() {}

    public func encode(_ code: inout [Int8], _ message: [UInt8],
                        _ frozenBits: [UInt32], _ dataBits: Int) {
        for i in 0..<dataBits {
            mesg[i] = Int8(nrz(getLEBit(message, i) ? 1 : 0))
        }
        crc.reset()
        for i in 0..<(dataBits / 8) {
            crc.update(byte: message[i])
        }
        let crcVal = crc.value
        for i in 0..<32 {
            mesg[i + dataBits] = Int8(nrz(Int((crcVal >> i) & 1)))
        }
        encode.encode(&code, mesg, frozenBits, Self.codeOrder)
    }
}

public final class PolarDecoderWrapper {
    private static let codeOrder = 11
    private static let codeLen = 1 << codeOrder
    private static let maxBits = 1360 + 32
    private var crc = CRC<UInt32>(poly: 0x8F6E37A0)
    private let nonSysEnc = PolarNonSysEnc() // non-systematic encoder for re-encoding
    private let listDecoder = PolarListDecoder()
    private var mesg = [SIMDVector](repeating: SIMDVector(), count: maxBits)
    private var mess = [SIMDVector](repeating: SIMDVector(), count: codeLen)

    public init() {}

    private func systematic(_ frozen: [UInt32], _ crcBits: Int) {
        // Re-encode decoded u-vector through non-systematic encoder to recover codeword,
        // then extract non-frozen positions as message bits.
        var mesgScalar = [Int8](repeating: 0, count: Self.maxBits)
        var codeScalar = [Int8](repeating: 0, count: Self.codeLen)

        for k in 0..<SIMDVector.SIZE {
            // Extract decoded u-values for path k
            for i in 0..<crcBits {
                mesgScalar[i] = mesg[i].v[k]
            }
            // Non-systematic encode: u-vector → codeword
            nonSysEnc.encode(&codeScalar, mesgScalar, frozen, Self.codeOrder)
            // Store codeword values per lane
            for i in 0..<Self.codeLen {
                mess[i].v[k] = codeScalar[i]
            }
        }
        // Extract non-frozen positions from codeword back to mesg
        var j = 0
        for i in 0..<Self.codeLen {
            guard j < crcBits else { break }
            if !((frozen[i / 32] >> (i % 32)) & 1 != 0) {
                mesg[j] = mess[i]
                j += 1
            }
        }
    }

    /// Decode polar code. Returns number of bit flips or -1 if CRC fails.
    public func decode(_ message: inout [UInt8], _ code: [Int8],
                        _ frozen: [UInt32], _ dataBits: Int) -> Int {
        let crcBits = dataBits + 32
        listDecoder.decode(&mesg, code, frozen, Self.codeOrder)
        systematic(frozen, crcBits)

        var best = -1
        for k in 0..<SIMDVector.SIZE {
            crc.reset()
            for i in 0..<crcBits {
                crc.update(bit: mesg[i].v[k] < 0)
            }
            if crc.value == 0 {
                best = k
                break
            }
        }

        if best < 0 { return -1 }

        var flips = 0
        var j = 0
        for i in 0..<dataBits {
            while (frozen[j / 32] >> (j % 32)) & 1 != 0 {
                j += 1
            }
            let received = code[j] < 0
            let decoded = mesg[i].v[best] < 0
            if received != decoded { flips += 1 }
            setLEBit(&message, i, decoded)
            j += 1
        }
        return flips
    }
}
