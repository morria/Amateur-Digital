/*
 BCH Encoder - ported from bose_chaudhuri_hocquenghem_encoder.hh
 Original Copyright 2018 Ahmet Inan <inan@aicodix.de>
 */

public struct BCHEncoder {
    public let n: Int  // = 255
    public let k: Int  // = 71
    public let np: Int // = 184
    private var generator: [UInt8]

    private static func slb1(_ buf: [UInt8], _ pos: Int) -> UInt8 {
        (buf[pos] << 1) | (buf[pos + 1] >> 7)
    }

    public init(n: Int = 255, k: Int = 71, minimalPolynomials: [Int]) {
        self.n = n
        self.k = k
        self.np = n - k
        let g = ((np + 1) + 7) / 8
        generator = [UInt8](repeating: 0, count: g)
        setBEBit(&generator, np, true)

        var generatorDegree = 1
        for m in minimalPolynomials {
            var mDegree = 0
            var tmp = m
            while tmp > 0 {
                mDegree += 1
                tmp >>= 1
            }
            mDegree -= 1

            for i in stride(from: generatorDegree, through: 0, by: -1) {
                if !getBEBit(generator, np - i) { continue }
                setBEBit(&generator, np - i, m & 1 != 0)
                for j in 1...mDegree {
                    xorBEBit(&generator, np - (i + j), (m >> j) & 1 != 0)
                }
            }
            generatorDegree += mDegree
        }

        // Shift generator left by 1 (remove leading 1)
        for i in 0..<np {
            setBEBit(&generator, i, getBEBit(generator, i + 1))
        }
        setBEBit(&generator, np, false)
    }

    public func encode(_ data: [UInt8], _ parity: inout [UInt8], dataLen: Int? = nil) {
        let dl = dataLen ?? k
        for l in 0...((np - 1) / 8) {
            parity[l] = 0
        }
        for i in 0..<dl {
            if getBEBit(data, i) != getBEBit(parity, 0) {
                for l in 0..<((np - 1) / 8) {
                    parity[l] = generator[l] ^ Self.slb1(parity, l)
                }
                parity[(np - 1) / 8] = generator[(np - 1) / 8] ^ (parity[(np - 1) / 8] << 1)
            } else {
                for l in 0..<((np - 1) / 8) {
                    parity[l] = Self.slb1(parity, l)
                }
                parity[(np - 1) / 8] <<= 1
            }
        }
    }
}
