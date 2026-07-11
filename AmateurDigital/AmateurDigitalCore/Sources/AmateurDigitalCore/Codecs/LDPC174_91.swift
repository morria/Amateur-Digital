//
//  LDPC174_91.swift
//  AmateurDigitalCore
//
//  (174,91) LDPC code used by FT8 (WSJT-X).
//  Rate ≈ 0.52, column weight 3, 83 parity checks.
//  K=91 information bits = 77 message + 14 CRC.
//
//  Unlike the (174,87) JS8Call code which uses [parity | message] with colorder
//  reordering, FT8's (174,91) code uses message-first systematic form:
//  codeword = [91 message bits | 83 parity bits], with no column reordering.
//
//  Tables transcribed from WSJT-X Fortran source:
//    ldpc_174_91_c_parity.f90    — Mn, Nm, nrw
//    ldpc_174_91_c_generator.f90 — g (83 hex strings)
//    ldpc_174_91_c_colorder.f90  — colorder (unused in encode/decode)
//

import Foundation

public struct LDPC174_91 {

    // MARK: - Constants

    public static let N = 174  // codeword length
    public static let K = 91   // information bits (77 message + 14 CRC)
    public static let M = 83   // parity checks (N - K)

    // MARK: - Public API

    /// Encode 91 information bits into a 174-bit codeword.
    /// Codeword format: [91 message bits | 83 parity bits] (no column reordering).
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
        // FT8 systematic form: message first, parity second
        var codeword = [UInt8](repeating: 0, count: N)
        for i in 0..<K { codeword[i] = message[i] }
        for i in 0..<M { codeword[K + i] = pchecks[i] }
        return codeword
    }

    /// Decode 174 LLRs using belief propagation, then OSD fallback.
    /// Returns (decoded 91 bits, hard error count, dmin) on success, nil on failure.
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

    /// BP decoder for the (174,91) LDPC code.
    /// Returns (91 decoded bits, hard error count, dmin=0) on success, nil on failure.
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
                // Valid codeword found — extract first K bits (message-first format)
                let decoded = Array(cw[0..<K])
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

    /// OSD decoder for the (174,91) LDPC code.
    /// Fallback when BP fails. Depth 1-5 controls search exhaustiveness.
    /// Returns (91 decoded bits, hard error count, dmin) on success, nil on failure.
    public static func osdDecode(llr: [Double], depth: Int = 3) -> (bits: [UInt8], nharderrors: Int, dmin: Double)? {
        let ndeep = min(depth, 5)

        // No column reordering for (174,91) — work directly with LLRs
        let rx = llr

        let absrx = rx.map { abs($0) }
        var indices = Array(0..<N)
        indices.sort { absrx[$0] > absrx[$1] }

        // Reorder by descending reliability
        let sortedRx = indices.map { rx[$0] }
        let sortedAbsRx = indices.map { absrx[$0] }

        // Build generator matrix in systematic form
        // The (174,91) generator: gen[M][K], codeword = [message | gen^T * message]
        // Full generator in codeword space: row i has identity column i (for message bits)
        //   plus gen[j][i] at position K+j (for parity bits)
        var genmrb = [[UInt8]](repeating: [UInt8](repeating: 0, count: N), count: K)

        // Fill: identity in first K columns, gen^T in last M columns
        for i in 0..<K {
            genmrb[i][i] = 1  // identity part
        }
        for i in 0..<M {
            let genRow = generatorMatrix[i]
            for j in 0..<K {
                genmrb[j][K + i] = genRow[j]  // parity part
            }
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
        var hdecPivot = [UInt8](repeating: 0, count: N)
        for i in 0..<N { hdecPivot[i] = sortedRx[i] >= 0 ? 1 : 0 }

        // Order-0 message: hard decisions on K most reliable bits
        let m0 = Array(hdecPivot.prefix(K))

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
        // Undo the reliability reordering to get back to systematic order
        var cwOrig = [UInt8](repeating: 0, count: N)
        for i in 0..<N { cwOrig[indices[i]] = cw[i] }

        // FT8 systematic form: first K bits are message (no colorder to undo)
        let decoded = Array(cwOrig[0..<K])
        return (decoded, nhard, dmin)
    }

    // MARK: - Tanner Graph: Mn (bit-to-check, 3 checks per bit, 1-indexed)

    /// mn[bit][0..2] = which 3 check nodes connect to each of 174 bits (1-indexed).
    /// Transcribed from WSJT-X ldpc_174_91_c_parity.f90 Mn(3,174).
    static let mn: [[Int]] = [
        [16, 45, 73], [25, 51, 62], [33, 58, 78], [ 1, 44, 45], [ 2,  7, 61],  //   1-5
        [ 3,  6, 54], [ 4, 35, 48], [ 5, 13, 21], [ 8, 56, 79], [ 9, 64, 69],  //   6-10
        [10, 19, 66], [11, 36, 60], [12, 37, 58], [14, 32, 43], [15, 63, 80],  //  11-15
        [17, 28, 77], [18, 74, 83], [22, 53, 81], [23, 30, 34], [24, 31, 40],  //  16-20
        [26, 41, 76], [27, 57, 70], [29, 49, 65], [ 3, 38, 78], [ 5, 39, 82],  //  21-25
        [46, 50, 73], [51, 52, 74], [55, 71, 72], [44, 67, 72], [43, 68, 78],  //  26-30
        [ 1, 32, 59], [ 2,  6, 71], [ 4, 16, 54], [ 7, 65, 67], [ 8, 30, 42],  //  31-35
        [ 9, 22, 31], [10, 18, 76], [11, 23, 82], [12, 28, 61], [13, 52, 79],  //  36-40
        [14, 50, 51], [15, 81, 83], [17, 29, 60], [19, 33, 64], [20, 26, 73],  //  41-45
        [21, 34, 40], [24, 27, 77], [25, 55, 58], [35, 53, 66], [36, 48, 68],  //  46-50
        [37, 46, 75], [38, 45, 47], [39, 57, 69], [41, 56, 62], [20, 49, 53],  //  51-55
        [46, 52, 63], [45, 70, 75], [27, 35, 80], [ 1, 15, 30], [ 2, 68, 80],  //  56-60
        [ 3, 36, 51], [ 4, 28, 51], [ 5, 31, 56], [ 6, 20, 37], [ 7, 40, 82],  //  61-65
        [ 8, 60, 69], [ 9, 10, 49], [11, 44, 57], [12, 39, 59], [13, 24, 55],  //  66-70
        [14, 21, 65], [16, 71, 78], [17, 30, 76], [18, 25, 80], [19, 61, 83],  //  71-75
        [22, 38, 77], [23, 41, 50], [ 7, 26, 58], [29, 32, 81], [33, 40, 73],  //  76-80
        [18, 34, 48], [13, 42, 64], [ 5, 26, 43], [47, 69, 72], [54, 55, 70],  //  81-85
        [45, 62, 68], [10, 63, 67], [14, 66, 72], [22, 60, 74], [35, 39, 79],  //  86-90
        [ 1, 46, 64], [ 1, 24, 66], [ 2,  5, 70], [ 3, 31, 65], [ 4, 49, 58],  //  91-95
        [ 1,  4,  5], [ 6, 60, 67], [ 7, 32, 75], [ 8, 48, 82], [ 9, 35, 41],  //  96-100
        [10, 39, 62], [11, 14, 61], [12, 71, 74], [13, 23, 78], [11, 35, 55],  // 101-105
        [15, 16, 79], [ 7,  9, 16], [17, 54, 63], [18, 50, 57], [19, 30, 47],  // 106-110
        [20, 64, 80], [21, 28, 69], [22, 25, 43], [13, 22, 37], [ 2, 47, 51],  // 111-115
        [23, 54, 74], [26, 34, 72], [27, 36, 37], [21, 36, 63], [29, 40, 44],  // 116-120
        [19, 26, 57], [ 3, 46, 82], [14, 15, 58], [33, 52, 53], [30, 43, 52],  // 121-125
        [ 6,  9, 52], [27, 33, 65], [25, 69, 73], [38, 55, 83], [20, 39, 77],  // 126-130
        [18, 29, 56], [32, 48, 71], [42, 51, 59], [28, 44, 79], [34, 60, 62],  // 131-135
        [31, 45, 61], [46, 68, 77], [ 6, 24, 76], [ 8, 10, 78], [40, 41, 70],  // 136-140
        [17, 50, 53], [42, 66, 68], [ 4, 22, 72], [36, 64, 81], [13, 29, 47],  // 141-145
        [ 2,  8, 81], [56, 67, 73], [ 5, 38, 50], [12, 38, 64], [59, 72, 80],  // 146-150
        [ 3, 26, 79], [45, 76, 81], [ 1, 65, 74], [ 7, 18, 77], [11, 56, 59],  // 151-155
        [14, 39, 54], [16, 37, 66], [10, 28, 55], [15, 60, 70], [17, 25, 82],  // 156-160
        [20, 30, 31], [12, 67, 68], [23, 75, 80], [27, 32, 62], [24, 69, 75],  // 161-165
        [19, 21, 71], [34, 53, 61], [35, 46, 47], [33, 59, 76], [40, 43, 83],  // 166-170
        [41, 42, 63], [49, 75, 83], [20, 44, 48], [42, 49, 57],               // 171-174
    ]

    // MARK: - Tanner Graph: Nm (check-to-bit, up to 7 bits per check, 1-indexed)

    /// nm[check][0..6] = which bits (1-indexed) participate in each of 83 check equations.
    /// Unused entries are 0.
    /// Transcribed from WSJT-X ldpc_174_91_c_parity.f90 Nm(7,83).
    static let nm: [[Int]] = [
        [  4,  31,  59,  91,  92,  96, 153],  // check  1
        [  5,  32,  60,  93, 115, 146,   0],  // check  2
        [  6,  24,  61,  94, 122, 151,   0],  // check  3
        [  7,  33,  62,  95,  96, 143,   0],  // check  4
        [  8,  25,  63,  83,  93,  96, 148],  // check  5
        [  6,  32,  64,  97, 126, 138,   0],  // check  6
        [  5,  34,  65,  78,  98, 107, 154],  // check  7
        [  9,  35,  66,  99, 139, 146,   0],  // check  8
        [ 10,  36,  67, 100, 107, 126,   0],  // check  9
        [ 11,  37,  67,  87, 101, 139, 158],  // check 10
        [ 12,  38,  68, 102, 105, 155,   0],  // check 11
        [ 13,  39,  69, 103, 149, 162,   0],  // check 12
        [  8,  40,  70,  82, 104, 114, 145],  // check 13
        [ 14,  41,  71,  88, 102, 123, 156],  // check 14
        [ 15,  42,  59, 106, 123, 159,   0],  // check 15
        [  1,  33,  72, 106, 107, 157,   0],  // check 16
        [ 16,  43,  73, 108, 141, 160,   0],  // check 17
        [ 17,  37,  74,  81, 109, 131, 154],  // check 18
        [ 11,  44,  75, 110, 121, 166,   0],  // check 19
        [ 45,  55,  64, 111, 130, 161, 173],  // check 20
        [  8,  46,  71, 112, 119, 166,   0],  // check 21
        [ 18,  36,  76,  89, 113, 114, 143],  // check 22
        [ 19,  38,  77, 104, 116, 163,   0],  // check 23
        [ 20,  47,  70,  92, 138, 165,   0],  // check 24
        [  2,  48,  74, 113, 128, 160,   0],  // check 25
        [ 21,  45,  78,  83, 117, 121, 151],  // check 26
        [ 22,  47,  58, 118, 127, 164,   0],  // check 27
        [ 16,  39,  62, 112, 134, 158,   0],  // check 28
        [ 23,  43,  79, 120, 131, 145,   0],  // check 29
        [ 19,  35,  59,  73, 110, 125, 161],  // check 30
        [ 20,  36,  63,  94, 136, 161,   0],  // check 31
        [ 14,  31,  79,  98, 132, 164,   0],  // check 32
        [  3,  44,  80, 124, 127, 169,   0],  // check 33
        [ 19,  46,  81, 117, 135, 167,   0],  // check 34
        [  7,  49,  58,  90, 100, 105, 168],  // check 35
        [ 12,  50,  61, 118, 119, 144,   0],  // check 36
        [ 13,  51,  64, 114, 118, 157,   0],  // check 37
        [ 24,  52,  76, 129, 148, 149,   0],  // check 38
        [ 25,  53,  69,  90, 101, 130, 156],  // check 39
        [ 20,  46,  65,  80, 120, 140, 170],  // check 40
        [ 21,  54,  77, 100, 140, 171,   0],  // check 41
        [ 35,  82, 133, 142, 171, 174,   0],  // check 42
        [ 14,  30,  83, 113, 125, 170,   0],  // check 43
        [  4,  29,  68, 120, 134, 173,   0],  // check 44
        [  1,   4,  52,  57,  86, 136, 152],  // check 45
        [ 26,  51,  56,  91, 122, 137, 168],  // check 46
        [ 52,  84, 110, 115, 145, 168,   0],  // check 47
        [  7,  50,  81,  99, 132, 173,   0],  // check 48
        [ 23,  55,  67,  95, 172, 174,   0],  // check 49
        [ 26,  41,  77, 109, 141, 148,   0],  // check 50
        [  2,  27,  41,  61,  62, 115, 133],  // check 51
        [ 27,  40,  56, 124, 125, 126,   0],  // check 52
        [ 18,  49,  55, 124, 141, 167,   0],  // check 53
        [  6,  33,  85, 108, 116, 156,   0],  // check 54
        [ 28,  48,  70,  85, 105, 129, 158],  // check 55
        [  9,  54,  63, 131, 147, 155,   0],  // check 56
        [ 22,  53,  68, 109, 121, 174,   0],  // check 57
        [  3,  13,  48,  78,  95, 123,   0],  // check 58
        [ 31,  69, 133, 150, 155, 169,   0],  // check 59
        [ 12,  43,  66,  89,  97, 135, 159],  // check 60
        [  5,  39,  75, 102, 136, 167,   0],  // check 61
        [  2,  54,  86, 101, 135, 164,   0],  // check 62
        [ 15,  56,  87, 108, 119, 171,   0],  // check 63
        [ 10,  44,  82,  91, 111, 144, 149],  // check 64
        [ 23,  34,  71,  94, 127, 153,   0],  // check 65
        [ 11,  49,  88,  92, 142, 157,   0],  // check 66
        [ 29,  34,  87,  97, 147, 162,   0],  // check 67
        [ 30,  50,  60,  86, 137, 142, 162],  // check 68
        [ 10,  53,  66,  84, 112, 128, 165],  // check 69
        [ 22,  57,  85,  93, 140, 159,   0],  // check 70
        [ 28,  32,  72, 103, 132, 166,   0],  // check 71
        [ 28,  29,  84,  88, 117, 143, 150],  // check 72
        [  1,  26,  45,  80, 128, 147,   0],  // check 73
        [ 17,  27,  89, 103, 116, 153,   0],  // check 74
        [ 51,  57,  98, 163, 165, 172,   0],  // check 75
        [ 21,  37,  73, 138, 152, 169,   0],  // check 76
        [ 16,  47,  76, 130, 137, 154,   0],  // check 77
        [  3,  24,  30,  72, 104, 139,   0],  // check 78
        [  9,  40,  90, 106, 134, 151,   0],  // check 79
        [ 15,  58,  60,  74, 111, 150, 163],  // check 80
        [ 18,  42,  79, 144, 146, 152,   0],  // check 81
        [ 25,  38,  65,  99, 122, 160,   0],  // check 82
        [ 17,  42,  75, 129, 170, 172,   0],  // check 83
    ]

    /// Row weights: number of bits per check (6 or 7).
    /// Transcribed from WSJT-X ldpc_174_91_c_parity.f90 nrw(83).
    static let nrw: [Int] = [
        7, 6, 6, 6, 7, 6, 7, 6, 6, 7, 6, 6, 7, 7, 6, 6,
        6, 7, 6, 7, 6, 7, 6, 6, 6, 7, 6, 6, 6, 7, 6, 6,
        6, 6, 7, 6, 6, 6, 7, 7, 6, 6, 6, 6, 7, 7, 6, 6,
        6, 6, 7, 6, 6, 6, 7, 6, 6, 6, 6, 7, 6, 6, 6, 7,
        6, 6, 6, 7, 7, 6, 6, 7, 6, 6, 6, 6, 6, 6, 6, 7,
        6, 6, 6,
    ]

    // MARK: - Generator Matrix

    /// 83 hex strings of 23 characters each. Each hex character = 4 bits,
    /// except the last character which contributes only 3 bits (22*4 + 3 = 91).
    /// Transcribed from WSJT-X ldpc_174_91_c_generator.f90.
    private static let generatorHex: [String] = [
        "8329ce11bf31eaf509f27fc",  //  1
        "761c264e25c259335493132",  //  2
        "dc265902fb277c6410a1bdc",  //  3
        "1b3f417858cd2dd33ec7f62",  //  4
        "09fda4fee04195fd034783a",  //  5
        "077cccc11b8873ed5c3d48a",  //  6
        "29b62afe3ca036f4fe1a9da",  //  7
        "6054faf5f35d96d3b0c8c3e",  //  8
        "e20798e4310eed27884ae90",  //  9
        "775c9c08e80e26ddae56318",  // 10
        "b0b811028c2bf997213487c",  // 11
        "18a0c9231fc60adf5c5ea32",  // 12
        "76471e8302a0721e01b12b8",  // 13
        "ffbccb80ca8341fafb47b2e",  // 14
        "66a72a158f9325a2bf67170",  // 15
        "c4243689fe85b1c51363a18",  // 16
        "0dff739414d1a1b34b1c270",  // 17
        "15b48830636c8b99894972e",  // 18
        "29a89c0d3de81d665489b0e",  // 19
        "4f126f37fa51cbe61bd6b94",  // 20
        "99c47239d0d97d3c84e0940",  // 21
        "1919b75119765621bb4f1e8",  // 22
        "09db12d731faee0b86df6b8",  // 23
        "488fc33df43fbdeea4eafb4",  // 24
        "827423ee40b675f756eb5fe",  // 25
        "abe197c484cb74757144a9a",  // 26
        "2b500e4bc0ec5a6d2bdbdd0",  // 27
        "c474aa53d70218761669360",  // 28
        "8eba1a13db3390bd6718cec",  // 29
        "753844673a27782cc42012e",  // 30
        "06ff83a145c37035a5c1268",  // 31
        "3b37417858cc2dd33ec3f62",  // 32
        "9a4a5a28ee17ca9c324842c",  // 33
        "bc29f465309c977e89610a4",  // 34
        "2663ae6ddf8b5ce2bb29488",  // 35
        "46f231efe457034c1814418",  // 36
        "3fb2ce85abe9b0c72e06fbe",  // 37
        "de87481f282c153971a0a2e",  // 38
        "fcd7ccf23c69fa99bba1412",  // 39
        "f0261447e9490ca8e474cec",  // 40
        "4410115818196f95cdd7012",  // 41
        "088fc31df4bfbde2a4eafb4",  // 42
        "b8fef1b6307729fb0a078c0",  // 43
        "5afea7acccb77bbc9d99a90",  // 44
        "49a7016ac653f65ecdc9076",  // 45
        "1944d085be4e7da8d6cc7d0",  // 46
        "251f62adc4032f0ee714002",  // 47
        "56471f8702a0721e00b12b8",  // 48
        "2b8e4923f2dd51e2d537fa0",  // 49
        "6b550a40a66f4755de95c26",  // 50
        "a18ad28d4e27fe92a4f6c84",  // 51
        "10c2e586388cb82a3d80758",  // 52
        "ef34a41817ee02133db2eb0",  // 53
        "7e9c0c54325a9c15836e000",  // 54
        "3693e572d1fde4cdf079e86",  // 55
        "bfb2cec5abe1b0c72e07fbe",  // 56
        "7ee18230c583cccc57d4b08",  // 57
        "a066cb2fedafc9f52664126",  // 58
        "bb23725abc47cc5f4cc4cd2",  // 59
        "ded9dba3bee40c59b5609b4",  // 60
        "d9a7016ac653e6decdc9036",  // 61
        "9ad46aed5f707f280ab5fc4",  // 62
        "e5921c77822587316d7d3c2",  // 63
        "4f14da8242a8b86dca73352",  // 64
        "8b8b507ad467d4441df770e",  // 65
        "22831c9cf1169467ad04b68",  // 66
        "213b838fe2ae54c38ee7180",  // 67
        "5d926b6dd71f085181a4e12",  // 68
        "66ab79d4b29ee6e69509e56",  // 69
        "958148682d748a38dd68baa",  // 70
        "b8ce020cf069c32a723ab14",  // 71
        "f4331d6d461607e95752746",  // 72
        "6da23ba424b9596133cf9c8",  // 73
        "a636bcbc7b30c5fbeae67fe",  // 74
        "5cb0d86a07df654a9089a20",  // 75
        "f11f106848780fc9ecdd80a",  // 76
        "1fbb5364fb8d2c9d730d5ba",  // 77
        "fcb86bc70a50c9d02a5d034",  // 78
        "a534433029eac15f322e34c",  // 79
        "c989d9c7c3d3b8c55d75130",  // 80
        "7bb38b2f0186d46643ae962",  // 81
        "2644ebadeb44b9467d1f42c",  // 82
        "608cc857594bfbb55d69600",  // 83
    ]

    private static func hexCharVal(_ c: Character) -> Int {
        switch c {
        case "0"..."9": return Int(c.asciiValue! - Character("0").asciiValue!)
        case "a"..."f": return Int(c.asciiValue! - Character("a").asciiValue!) + 10
        default: return 0
        }
    }

    /// Lazy-loaded generator matrix (83 parity rows x 91 message columns).
    /// Each hex char = 4 bits, except the 23rd char which contributes only 3 bits.
    /// Parsing matches WSJT-X Fortran: btest(istr, 4-jj) for jj=1..ibmax,
    /// where ibmax=4 for chars 1-22 and ibmax=3 for char 23.
    static let generatorMatrix: [[UInt8]] = {
        var gen = [[UInt8]](repeating: [UInt8](repeating: 0, count: K), count: M)
        for i in 0..<M {
            let hex = Array(generatorHex[i])
            for j in 0..<23 {
                let nibble = hexCharVal(hex[j])
                let ibmax = (j == 22) ? 3 : 4
                for jj in 1...ibmax {
                    let icol = j * 4 + jj - 1  // 0-indexed: (j*4) + (jj-1)
                    if icol < K {
                        gen[i][icol] = (nibble >> (4 - jj)) & 1 != 0 ? 1 : 0
                    }
                }
            }
        }
        return gen
    }()

    // MARK: - Column Reorder Table (included for completeness, not used in encode/decode)

    /// Column reorder table from WSJT-X ldpc_174_91_c_colorder.f90.
    /// The (174,91) encode/decode does NOT use column reordering (unlike the 174,87 code),
    /// but the table is retained here for reference and potential future use.
    static let colorder: [Int] = [
          0,   1,   2,   3,  28,   4,   5,   6,   7,   8,   9,  10,  11,  34,  12,  32,  13,  14,  15,  16,
         17,  18,  36,  29,  43,  19,  20,  42,  21,  40,  30,  37,  22,  47,  61,  45,  44,  23,  41,  39,
         49,  24,  46,  50,  48,  26,  31,  33,  51,  38,  52,  59,  55,  66,  57,  27,  60,  35,  54,  58,
         25,  56,  62,  64,  67,  69,  63,  68,  70,  72,  65,  73,  75,  74,  71,  77,  78,  76,  79,  80,
         53,  81,  83,  82,  84,  85,  86,  87,  88,  89,  90,  91,  92,  93,  94,  95,  96,  97,  98,  99,
        100, 101, 102, 103, 104, 105, 106, 107, 108, 109, 110, 111, 112, 113, 114, 115, 116, 117, 118, 119,
        120, 121, 122, 123, 124, 125, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139,
        140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152, 153, 154, 155, 156, 157, 158, 159,
        160, 161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171, 172, 173,
    ]
}
