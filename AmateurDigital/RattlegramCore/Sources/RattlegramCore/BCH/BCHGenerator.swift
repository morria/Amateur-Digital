/*
 BCH Generator matrix builder - ported from osd.hh (BoseChaudhuriHocquenghemGenerator)
 Original Copyright 2020 Ahmet Inan <inan@aicodix.de>
 */

public enum BCHGenerator {
    /// Build generator polynomial and then generator matrix
    public static func matrix(_ genmat: inout [Int8], systematic: Bool,
                               n: Int = 255, k: Int = 71,
                               minimalPolynomials: [Int]) {
        let np = n - k

        // Build generator polynomial in first row
        for i in 0..<n {
            genmat[i] = 0
        }
        genmat[np] = 1

        var genpolyDegree = 1
        for m in minimalPolynomials {
            var mDegree = 0
            var tmp = m
            while tmp > 0 { mDegree += 1; tmp >>= 1 }
            mDegree -= 1

            for i in stride(from: genpolyDegree, through: 0, by: -1) {
                if genmat[np - i] == 0 { continue }
                genmat[np - i] = Int8(m & 1)
                for j in 1...mDegree {
                    genmat[np - (i + j)] ^= Int8((m >> j) & 1)
                }
            }
            genpolyDegree += mDegree
        }

        // Fill remaining rows by shifting
        for i in (np + 1)..<n {
            genmat[i] = 0
        }
        for j in 1..<k {
            for i in 0..<j {
                genmat[n * j + i] = 0
            }
            for i in 0...np {
                genmat[(n + 1) * j + i] = genmat[i]
            }
            for i in (j + np + 1)..<n {
                genmat[n * j + i] = 0
            }
        }

        // Make systematic if requested
        if systematic {
            for kk in stride(from: k - 1, through: 1, by: -1) {
                for j in 0..<kk {
                    if genmat[n * j + kk] != 0 {
                        for i in kk..<n {
                            genmat[n * j + i] ^= genmat[n * kk + i]
                        }
                    }
                }
            }
        }
    }
}
