//
//  LDPC174_87.swift
//  AmateurDigitalCore
//
//  (174,87) LDPC code used by FT8 and JS8Call.
//  Rate-1/2, regular column weight 3, PEG-constructed.
//  Includes encoder, belief propagation decoder, and ordered statistics decoder.
//

import Foundation

public struct LDPC174_87 {

    // MARK: - Public API

    /// Encode 87 information bits into a 174-bit codeword.
    public static func encode(_ message: [UInt8]) -> [UInt8] {
        let gen = generatorMatrix
        var pchecks = [UInt8](repeating: 0, count: M)
        for i in 0..<M {
            var sum = 0
            for j in 0..<K {
                sum += Int(message[j]) * Int(gen[i][j])
            }
            pchecks[i] = UInt8(sum & 1)
        }
        // itmp: parity first, then message
        var itmp = [UInt8](repeating: 0, count: N)
        for i in 0..<M { itmp[i] = pchecks[i] }
        for i in 0..<K { itmp[M + i] = message[i] }
        // Reorder columns
        var codeword = [UInt8](repeating: 0, count: N)
        for i in 0..<N { codeword[colorder[i]] = itmp[i] }
        return codeword
    }

    /// Decode 174 LLRs using belief propagation, then OSD fallback.
    /// Returns (decoded 87 bits, hard error count) on success, nil on failure.
    public static func decode(llr: [Double], maxBPIterations: Int = 30, osdDepth: Int = 3) -> (bits: [UInt8], nharderrors: Int, dmin: Double)? {
        // Try BP first
        if let result = bpDecode(llr: llr, maxIterations: maxBPIterations) {
            return result
        }
        // Fallback to OSD
        if osdDepth > 0 {
            return osdDecode(llr: llr, depth: osdDepth)
        }
        return nil
    }

    // MARK: - Belief Propagation Decoder

    /// BP decoder for the (174,87) LDPC code.
    /// Returns (87 decoded bits, hard error count, dmin=0) on success, nil on failure.
    public static func bpDecode(llr: [Double], maxIterations: Int = 30) -> (bits: [UInt8], nharderrors: Int, dmin: Double)? {
        var tov = [[Double]](repeating: [Double](repeating: 0, count: 3), count: N)
        var toc = [[Double]](repeating: [Double](repeating: 0, count: 7), count: M)
        var zn = [Double](repeating: 0, count: N)
        var cw = [UInt8](repeating: 0, count: N)

        // Initialize messages from channel LLRs
        for j in 0..<M {
            for i in 0..<nrw[j] {
                let bitIdx = nm[j][i] - 1
                if bitIdx >= 0 && bitIdx < N {
                    toc[j][i] = llr[bitIdx]
                }
            }
        }

        var nclast = M
        var ncnt = 0

        for iter in 0...maxIterations {
            // Update bit beliefs
            for i in 0..<N {
                let t = tov[i]
                zn[i] = llr[i] + t[0] + t[1] + t[2]
            }

            // Hard decisions
            for i in 0..<N { cw[i] = zn[i] > 0 ? 1 : 0 }

            // Check all parity equations
            var ncheck = 0
            for j in 0..<M {
                var sum = 0
                for i in 0..<nrw[j] {
                    let bitIdx = nm[j][i] - 1
                    if bitIdx >= 0 && bitIdx < N { sum += Int(cw[bitIdx]) }
                }
                if sum & 1 != 0 { ncheck += 1 }
            }

            if ncheck == 0 {
                // Valid codeword found - reorder and extract message bits
                var reordered = [UInt8](repeating: 0, count: N)
                for i in 0..<N { reordered[i] = cw[colorder[i]] }
                let decoded = Array(reordered[M..<N])
                // Count hard errors
                var nerr = 0
                for i in 0..<N {
                    if Double(2 * Int(cw[i]) - 1) * llr[i] < 0 { nerr += 1 }
                }
                return (decoded, nerr, 0.0)
            }

            // Early stopping: abort if stuck for 5+ iterations with poor quality
            if iter > 0 {
                let nd = ncheck - nclast
                if nd < 0 { ncnt = 0 } else { ncnt += 1 }
                if ncnt >= 5 && iter >= 10 && ncheck > 15 { return nil }
            }
            nclast = ncheck

            // Variable-to-check messages
            for j in 0..<M {
                for i in 0..<nrw[j] {
                    let bitIdx = nm[j][i] - 1
                    guard bitIdx >= 0 && bitIdx < N else { continue }
                    toc[j][i] = zn[bitIdx]
                    // Subtract what this check already sent to this bit
                    for kk in 0..<3 {
                        if mn[bitIdx][kk] - 1 == j {
                            toc[j][i] -= tov[bitIdx][kk]
                        }
                    }
                }
            }

            // Check-to-variable messages (tanh rule)
            for bitIdx in 0..<N {
                for k in 0..<3 {
                    let checkIdx = mn[bitIdx][k] - 1
                    guard checkIdx >= 0 && checkIdx < M else { continue }

                    // Product of tanh(-toc/2) for all OTHER bits in this check
                    var product = 1.0
                    for i in 0..<nrw[checkIdx] {
                        let otherBit = nm[checkIdx][i] - 1
                        if otherBit != bitIdx {
                            let x = -toc[checkIdx][i] / 2.0
                            product *= tanh(x)
                        }
                    }
                    // Clamp before atanh to avoid NaN
                    let clamped = max(-0.9999, min(0.9999, -product))
                    tov[bitIdx][k] = 2.0 * atanh(clamped)
                }
            }
        }

        return nil
    }

    // MARK: - Ordered Statistics Decoder

    /// OSD decoder for the (174,87) LDPC code.
    /// Fallback when BP fails. Depth 1-5 controls search exhaustiveness.
    /// Returns (87 decoded bits, hard error count, dmin) on success, nil on failure.
    public static func osdDecode(llr: [Double], depth: Int = 3) -> (bits: [UInt8], nharderrors: Int, dmin: Double)? {
        let ndeep = min(depth, 5)

        // Reorder received word by reliability
        var rx = [Double](repeating: 0, count: N)
        for i in 0..<N { rx[i] = llr[colorder[i]] }

        var absrx = rx.map { abs($0) }
        var indices = Array(0..<N)
        indices.sort { absrx[$0] > absrx[$1] }

        // Reorder by descending reliability
        let sortedRx = indices.map { rx[$0] }
        let sortedAbsRx = indices.map { absrx[$0] }

        // Build generator matrix in systematic form
        // Start with the full gen matrix [I_K | P^T] in the original column order
        var genmrb = [[UInt8]](repeating: [UInt8](repeating: 0, count: N), count: K)

        // Fill from stored generator matrix + identity
        for i in 0..<M {
            let genRow = generatorMatrix[i]
            for j in 0..<K {
                genmrb[j][i] = genRow[j]
            }
        }
        for i in 0..<K {
            genmrb[i][M + i] = 1
        }

        // Reorder columns by reliability
        var g2 = [[UInt8]](repeating: [UInt8](repeating: 0, count: N), count: K)
        for i in 0..<K {
            for j in 0..<N {
                g2[i][j] = genmrb[i][indices[j]]
            }
        }

        // Gaussian elimination to put most reliable bits in systematic positions
        var pivotCols = indices
        for id in 0..<K {
            var found = false
            for icol in id..<min(N, K + 20) {
                if g2[id][icol] == 1 {
                    if icol != id {
                        // Swap columns
                        for row in 0..<K {
                            let tmp = g2[row][id]
                            g2[row][id] = g2[row][icol]
                            g2[row][icol] = tmp
                        }
                        pivotCols.swapAt(id, icol)
                    }
                    // Eliminate other rows
                    for ii in 0..<K {
                        if ii != id && g2[ii][id] == 1 {
                            for jj in 0..<N {
                                g2[ii][jj] ^= g2[id][jj]
                            }
                        }
                    }
                    found = true
                    break
                }
            }
            if !found { break }
        }

        // Hard decisions on reordered received word
        var hdec = [UInt8](repeating: 0, count: N)
        for i in 0..<N { hdec[i] = sortedRx[i] >= 0 ? 1 : 0 }

        // Reorder hdec by pivot columns
        var hdecPivot = [UInt8](repeating: 0, count: N)
        for i in 0..<N { hdecPivot[i] = hdec[i] }  // Already sorted

        // Order-0 message: hard decisions on K most reliable bits
        var m0 = Array(hdecPivot.prefix(K))

        // Encode m0 to get order-0 codeword
        func mrbencode(_ me: [UInt8]) -> [UInt8] {
            var cw = [UInt8](repeating: 0, count: N)
            for i in 0..<K {
                if me[i] == 1 {
                    for j in 0..<N {
                        cw[j] ^= g2[i][j]
                    }
                }
            }
            return cw
        }

        var c0 = mrbencode(m0)
        var bestCW = c0
        var bestNhard = 0
        var bestDmin = 0.0

        // Compute initial distance
        for i in 0..<N {
            if c0[i] != hdecPivot[i] {
                bestNhard += 1
                bestDmin += sortedAbsRx[i]
            }
        }

        guard ndeep > 0 else {
            return extractResult(bestCW, indices: pivotCols, nhard: bestNhard, dmin: bestDmin, llr: llr)
        }

        // Order-1 search: try flipping each of the K message bits
        for n1 in 0..<K {
            var me = m0
            me[n1] ^= 1
            let ce = mrbencode(me)

            var nhard = 0
            var dmin = 0.0
            for i in 0..<N {
                if ce[i] != hdecPivot[i] {
                    nhard += 1
                    dmin += sortedAbsRx[i]
                }
            }
            if dmin < bestDmin {
                bestDmin = dmin
                bestNhard = nhard
                bestCW = ce
            }
        }

        // Order-2 search (depth >= 4): try flipping pairs
        if ndeep >= 4 {
            for n1 in 0..<K {
                for n2 in (n1+1)..<K {
                    var me = m0
                    me[n1] ^= 1
                    me[n2] ^= 1
                    let ce = mrbencode(me)

                    var nhard = 0
                    var dmin = 0.0
                    for i in 0..<N {
                        if ce[i] != hdecPivot[i] {
                            nhard += 1
                            dmin += sortedAbsRx[i]
                        }
                    }
                    if dmin < bestDmin {
                        bestDmin = dmin
                        bestNhard = nhard
                        bestCW = ce
                    }
                }
            }
        }

        return extractResult(bestCW, indices: pivotCols, nhard: bestNhard, dmin: bestDmin, llr: llr)
    }

    private static func extractResult(_ cw: [UInt8], indices: [Int], nhard: Int, dmin: Double, llr: [Double]) -> (bits: [UInt8], nharderrors: Int, dmin: Double)? {
        // Undo the column reordering to get back to received-word order
        var cwOrig = [UInt8](repeating: 0, count: N)
        for i in 0..<N { cwOrig[indices[i]] = cw[i] }

        // Undo the colorder to get systematic form
        var cwSys = [UInt8](repeating: 0, count: N)
        for i in 0..<N { cwSys[i] = cwOrig[colorder[i]] }

        let decoded = Array(cwSys[M..<N])
        return (decoded, nhard, dmin)
    }

    // MARK: - Constants

    private static let N = JS8CallConstants.N   // 174
    private static let K = JS8CallConstants.K   // 87
    private static let M = JS8CallConstants.M   // 87

    // MARK: - Column Reorder Table

    static let colorder: [Int] = [
        0,1,2,3,30,4,5,6,7,8,9,10,11,32,12,40,13,14,15,16,
        17,18,37,45,29,19,20,21,41,22,42,31,33,34,44,35,47,51,50,43,
        36,52,63,46,25,55,27,24,23,53,39,49,59,38,48,61,60,57,28,62,
        56,58,65,66,26,70,64,69,68,67,74,71,54,76,72,75,78,77,80,79,
        73,83,84,81,82,85,86,87,88,89,90,91,92,93,94,95,96,97,98,99,
        100,101,102,103,104,105,106,107,108,109,110,111,112,113,114,115,116,117,118,119,
        120,121,122,123,124,125,126,127,128,129,130,131,132,133,134,135,136,137,138,139,
        140,141,142,143,144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,
        160,161,162,163,164,165,166,167,168,169,170,171,172,173,
    ]

    // MARK: - Generator Matrix

    private static let generatorHex: [String] = [
        "23bba830e23b6b6f50982e","1f8e55da218c5df3309052","ca7b3217cd92bd59a5ae20","56f78313537d0f4382964e",
        "29c29dba9c545e267762fe","6be396b5e2e819e373340c","293548a138858328af4210","cb6c6afcdc28bb3f7c6e86",
        "3f2a86f5c5bd225c961150","849dd2d63673481860f62c","56cdaec6e7ae14b43feeee","04ef5cfa3766ba778f45a4",
        "c525ae4bd4f627320a3974","fe37802941d66dde02b99c","41fd9520b2e4abeb2f989c","40907b01280f03c0323946",
        "7fb36c24085a34d8c1dbc4","40fc3e44bb7d2bb2756e44","d38ab0a1d2e52a8ec3bc76","3d0f929ef3949bd84d4734",
        "45d3814f504064f80549ae","f14dbf263825d0bd04b05e","f08a91fb2e1f78290619a8","7a8dec79a51e8ac5388022",
        "ca4186dd44c3121565cf5c","db714f8f64e8ac7af1a76e","8d0274de71e7c1a8055eb0","51f81573dd4049b082de14",
        "d037db825175d851f3af00","d8f937f31822e57c562370","1bf1490607c54032660ede","1616d78018d0b4745ca0f2",
        "a9fa8e50bcb032c85e3304","83f640f1a48a8ebc0443ea","eca9afa0f6b01d92305edc","3776af54ccfbae916afde6",
        "6abb212d9739dfc02580f2","05209a0abb530b9e7e34b0","612f63acc025b6ab476f7c","0af7723161ec223080be86",
        "a8fc906976c35669e79ce0","45b7ab6242b77474d9f11a","b274db8abd3c6f396ea356","9059dfa2bb20ef7ef73ad4",
        "3d188ea477f6fa41317a4e","8d9071b7e7a6a2eed6965e","a377253773ea678367c3f6","ecbd7c73b9cd34c3720c8a",
        "b6537f417e61d1a7085336","6c280d2a0523d9c4bc5946","d36d662a69ae24b74dcbd8","d747bfc5fd65ef70fbd9bc",
        "a9fa2eefa6f8796a355772","cc9da55fe046d0cb3a770c","f6ad4824b87c80ebfce466","cc6de59755420925f90ed2",
        "164cc861bdd803c547f2ac","c0fc3ec4fb7d2bb2756644","0dbd816fba1543f721dc72","a0c0033a52ab6299802fd2",
        "bf4f56e073271f6ab4bf80","57da6d13cb96a7689b2790","81cfc6f18c35b1e1f17114","481a2a0df8a23583f82d6c",
        "1ac4672b549cd6dba79bcc","c87af9a5d5206abca532a8","97d4169cb33e7435718d90","a6573f3dc8b16c9d19f746",
        "2c4142bf42b01e71076acc","081c29a10d468ccdbcecb6","5b0f7742bca86b8012609a","012dee2198eba82b19a1da",
        "f1627701a2d692fd9449e6","35ad3fb0faeb5f1b0c30dc","b1ca4ea2e3d173bad4379c","37d8e0af9258b9e8c5f9b2",
        "cd921fdf59e882683763f6","6114e08483043fd3f38a8a","2e547dd7a05f6597aac516","95e45ecd0135aca9d6e6ae",
        "b33ec97be83ce413f9acc8","c8b5dffc335095dcdcaf2a","3dd01a59d86310743ec752","14cd0f642fc0c5fe3a65ca",
        "3a0a1dfd7eee29c2e827e0","8abdb889efbe39a510a118","3f231f212055371cf3e2a2",
    ]

    private static func hexCharVal(_ c: Character) -> Int {
        switch c {
        case "0"..."9": return Int(c.asciiValue! - Character("0").asciiValue!)
        case "a"..."f": return Int(c.asciiValue! - Character("a").asciiValue!) + 10
        default: return 0
        }
    }

    /// Lazy-loaded generator matrix (87 parity rows x 87 message columns).
    static let generatorMatrix: [[UInt8]] = {
        var gen = [[UInt8]](repeating: [UInt8](repeating: 0, count: K), count: M)
        for i in 0..<M {
            let hex = Array(generatorHex[i])
            for j in 0..<11 {
                let hi = hexCharVal(hex[j * 2])
                let lo = hexCharVal(hex[j * 2 + 1])
                let byte = (hi << 4) | lo
                for jj in 0..<8 {
                    let icol = j * 8 + jj
                    if icol < K {
                        gen[i][icol] = (byte >> (7 - jj)) & 1 != 0 ? 1 : 0
                    }
                }
            }
        }
        return gen
    }()

    // MARK: - Parity Check Matrix (Sparse Form)

    /// mn[bit][0..2] = which 3 check nodes connect to each of 174 bits (1-indexed).
    static let mn: [[Int]] = [
        [1,25,69],[2,5,73],[3,32,68],[4,51,61],[6,63,70],[7,33,79],[8,50,86],
        [9,37,43],[10,41,65],[11,14,64],[12,75,77],[13,23,81],[15,16,82],[17,56,66],
        [18,53,60],[19,31,52],[20,67,84],[21,29,72],[22,24,44],[26,35,76],[27,36,38],
        [28,40,42],[30,54,55],[34,49,87],[39,57,58],[45,74,83],[46,62,80],[47,48,85],
        [59,71,78],[1,50,53],[2,47,84],[3,25,79],[4,6,14],[5,7,80],[8,34,55],
        [9,36,69],[10,43,83],[11,23,74],[12,17,44],[13,57,76],[15,27,56],[16,28,29],
        [18,19,59],[20,40,63],[21,35,52],[22,54,64],[24,62,78],[26,32,77],[30,72,85],
        [31,65,87],[33,39,51],[37,48,75],[38,70,71],[41,42,68],[45,67,86],[46,81,82],
        [49,66,73],[58,60,66],[61,65,85],[1,14,21],[2,13,59],[3,67,82],[4,32,73],
        [5,36,54],[6,43,46],[7,28,75],[8,33,71],[9,49,76],[10,58,64],[11,48,68],
        [12,19,45],[15,50,61],[16,22,26],[17,72,80],[18,40,55],[20,35,51],[23,25,34],
        [24,63,87],[27,39,74],[29,78,83],[30,70,77],[31,69,84],[22,37,86],[38,41,81],
        [42,44,57],[47,53,62],[52,56,79],[60,75,81],[1,39,77],[2,16,41],[3,31,54],
        [4,36,78],[5,45,65],[6,57,85],[7,14,49],[8,21,46],[9,15,72],[10,20,62],
        [11,17,71],[12,34,47],[13,68,86],[18,23,43],[19,64,73],[24,48,79],[25,70,83],
        [26,80,87],[27,32,40],[28,56,69],[29,63,66],[30,42,50],[33,37,82],[35,60,74],
        [38,55,84],[44,52,61],[51,53,72],[58,59,67],[47,56,76],[1,19,37],[2,61,75],
        [3,8,66],[4,60,84],[5,34,39],[6,26,53],[7,32,57],[9,52,67],[10,12,15],
        [11,51,69],[13,14,65],[16,31,43],[17,20,36],[18,80,86],[21,48,59],[22,40,46],
        [23,33,62],[24,30,74],[25,42,64],[27,49,85],[28,38,73],[29,44,81],[35,68,70],
        [41,63,76],[45,49,71],[50,58,87],[48,54,83],[13,55,79],[77,78,82],[1,2,24],
        [3,6,75],[4,56,87],[5,44,53],[7,50,83],[8,10,28],[9,55,62],[11,29,67],
        [12,33,40],[14,16,20],[15,35,73],[17,31,39],[18,36,57],[19,46,76],[21,42,84],
        [22,34,59],[23,26,61],[25,60,65],[27,64,80],[30,37,66],[32,45,72],[38,51,86],
        [41,77,79],[43,56,68],[47,74,82],[40,52,78],[54,61,71],[46,58,69],
    ]

    /// nm[check][0..6] = which bits (1-indexed) participate in each of 87 check equations.
    /// Unused entries are 0.
    static let nm: [[Int]] = [
        [1,30,60,89,118,147,0],[2,31,61,90,119,147,0],[3,32,62,91,120,148,0],
        [4,33,63,92,121,149,0],[2,34,64,93,122,150,0],[5,33,65,94,123,148,0],
        [6,34,66,95,124,151,0],[7,35,67,96,120,152,0],[8,36,68,97,125,153,0],
        [9,37,69,98,126,152,0],[10,38,70,99,127,154,0],[11,39,71,100,126,155,0],
        [12,40,61,101,128,145,0],[10,33,60,95,128,156,0],[13,41,72,97,126,157,0],
        [13,42,73,90,129,156,0],[14,39,74,99,130,158,0],[15,43,75,102,131,159,0],
        [16,43,71,103,118,160,0],[17,44,76,98,130,156,0],[18,45,60,96,132,161,0],
        [19,46,73,83,133,162,0],[12,38,77,102,134,163,0],[19,47,78,104,135,147,0],
        [1,32,77,105,136,164,0],[20,48,73,106,123,163,0],[21,41,79,107,137,165,0],
        [22,42,66,108,138,152,0],[18,42,80,109,139,154,0],[23,49,81,110,135,166,0],
        [16,50,82,91,129,158,0],[3,48,63,107,124,167,0],[6,51,67,111,134,155,0],
        [24,35,77,100,122,162,0],[20,45,76,112,140,157,0],[21,36,64,92,130,159,0],
        [8,52,83,111,118,166,0],[21,53,84,113,138,168,0],[25,51,79,89,122,158,0],
        [22,44,75,107,133,155,172],[9,54,84,90,141,169,0],[22,54,85,110,136,161,0],
        [8,37,65,102,129,170,0],[19,39,85,114,139,150,0],[26,55,71,93,142,167,0],
        [27,56,65,96,133,160,174],[28,31,86,100,117,171,0],[28,52,70,104,132,144,0],
        [24,57,68,95,137,142,0],[7,30,72,110,143,151,0],[4,51,76,115,127,168,0],
        [16,45,87,114,125,172,0],[15,30,86,115,123,150,0],[23,46,64,91,144,173,0],
        [23,35,75,113,145,153,0],[14,41,87,108,117,149,170],[25,40,85,94,124,159,0],
        [25,58,69,116,143,174,0],[29,43,61,116,132,162,0],[15,58,88,112,121,164,0],
        [4,59,72,114,119,163,173],[27,47,86,98,134,153,0],[5,44,78,109,141,0,0],
        [10,46,69,103,136,165,0],[9,50,59,93,128,164,0],[14,57,58,109,120,166,0],
        [17,55,62,116,125,154,0],[3,54,70,101,140,170,0],[1,36,82,108,127,174,0],
        [5,53,81,105,140,0,0],[29,53,67,99,142,173,0],[18,49,74,97,115,167,0],
        [2,57,63,103,138,157,0],[26,38,79,112,135,171,0],[11,52,66,88,119,148,0],
        [20,40,68,117,141,160,0],[11,48,81,89,146,169,0],[29,47,80,92,146,172,0],
        [6,32,87,104,145,169,0],[27,34,74,106,131,165,0],[12,56,84,88,139,0,0],
        [13,56,62,111,146,171,0],[26,37,80,105,144,151,0],[17,31,82,113,121,161,0],
        [28,49,59,94,137,0,0],[7,55,83,101,131,168,0],[24,50,78,106,143,149,0],
    ]

    /// Row weights: number of bits per check (5, 6, or 7).
    static let nrw: [Int] = [
        6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,
        6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,7,
        6,6,6,6,6,7,6,6,6,6,6,6,6,6,6,7,6,6,6,6,
        7,6,5,6,6,6,6,6,6,5,6,6,6,6,6,6,6,6,6,6,
        5,6,6,6,5,6,6,
    ]
}
