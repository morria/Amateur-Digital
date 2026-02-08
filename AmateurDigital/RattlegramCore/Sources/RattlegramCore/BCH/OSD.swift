/*
 Ordered Statistics Decoding - ported from osd.hh
 Original Copyright 2020 Ahmet Inan <inan@aicodix.de>
 */

import Foundation

public final class OrderedStatisticsDecoder {
    private let n: Int // = 255
    private let k: Int // = 71
    private let order: Int // = 2
    private let w: Int // padded row width
    private var g: [Int8]
    private var codeword: [Int8]
    private var candidate: [Int8]
    private var softperm: [Int8]
    private var perm: [Int16]

    public init(n: Int = 255, k: Int = 71, order: Int = 2) {
        self.n = n
        self.k = k
        self.order = order
        let s = MemoryLayout<Int>.size
        self.w = (n + s - 1) & ~(s - 1)
        g = [Int8](repeating: 0, count: w * k)
        codeword = [Int8](repeating: 0, count: w)
        candidate = [Int8](repeating: 0, count: w)
        softperm = [Int8](repeating: 0, count: w)
        perm = [Int16](repeating: 0, count: w)
    }

    /// Decode soft decisions using OSD. Returns true if decoding succeeded.
    public func decode(_ hard: inout [UInt8], _ soft: [Int8], _ genmat: [Int8]) -> Bool {
        // Initialize permutation
        for i in 0..<n { perm[i] = Int16(i) }

        // Sort by reliability (|soft value|), most reliable first
        var absSoft = [Int8](repeating: 0, count: n)
        for i in 0..<n {
            absSoft[i] = Int8(clamping: Int(Swift.abs(Int(max(soft[i], -127)))))
        }

        // Merge sort by descending reliability
        mergeSort(&perm, n) { a, b in
            absSoft[Int(a)] > absSoft[Int(b)]
        }

        // Permute generator matrix columns
        for j in 0..<k {
            for i in 0..<n {
                g[w * j + i] = genmat[n * j + Int(perm[i])]
            }
            for i in n..<w {
                g[w * j + i] = 0
            }
        }

        // Row echelon form
        rowEchelon()

        // Systematic form (back-substitution)
        systematic()

        // Permuted soft values
        for i in 0..<n {
            softperm[i] = max(soft[Int(perm[i])], -127)
        }
        for i in n..<w {
            softperm[i] = 0
        }

        // Hard decision from most reliable bits
        for i in 0..<k {
            codeword[i] = softperm[i] < 0 ? 1 : 0
        }
        encode()

        // Initial candidate
        for i in 0..<n { candidate[i] = codeword[i] }
        var best = metric()
        var next = -1

        // Order-O search
        for a in 0..<k where order >= 1 {
            flip(a)
            updateCandidate(&best, &next)
            for b in (a + 1)..<k where order >= 2 {
                flip(b)
                updateCandidate(&best, &next)
                flip(b)
            }
            flip(a)
        }

        // Write result
        for i in 0..<n {
            setBEBit(&hard, Int(perm[i]), candidate[i] != 0)
        }
        return best != next
    }

    // MARK: - Private

    private func rowEchelon() {
        for kk in 0..<k {
            // Find pivot
            for j in kk..<k {
                if g[w * j + kk] != 0 {
                    if j != kk {
                        for i in kk..<n { g.swapAt(w * j + i, w * kk + i) }
                    }
                    break
                }
            }
            // Search for column swap if no pivot found
            var jj = kk + 1
            while g[w * kk + kk] == 0 && jj < n {
                for h in kk..<k {
                    if g[w * h + jj] != 0 {
                        perm.swapAt(kk, jj)
                        for i in 0..<k { g.swapAt(w * i + kk, w * i + jj) }
                        if h != kk {
                            for i in kk..<n { g.swapAt(w * h + i, w * kk + i) }
                        }
                        break
                    }
                }
                jj += 1
            }
            // Zero out below pivot
            for j in (kk + 1)..<k {
                if g[w * j + kk] != 0 {
                    for i in kk..<n {
                        g[w * j + i] ^= g[w * kk + i]
                    }
                }
            }
        }
    }

    private func systematic() {
        for kk in stride(from: k - 1, through: 1, by: -1) {
            for j in 0..<kk {
                if g[w * j + kk] != 0 {
                    for i in kk..<n {
                        g[w * j + i] ^= g[w * kk + i]
                    }
                }
            }
        }
    }

    private func encode() {
        for i in k..<n {
            codeword[i] = codeword[0] & g[i]
        }
        for j in 1..<k {
            for i in k..<n {
                codeword[i] ^= codeword[j] & g[w * j + i]
            }
        }
    }

    private func flip(_ j: Int) {
        for i in 0..<w {
            codeword[i] ^= g[w * j + i]
        }
    }

    private func metric() -> Int {
        var sum = 0
        for i in 0..<w {
            sum += Int(1 - 2 * Int16(codeword[i])) * Int(softperm[i])
        }
        return sum
    }

    private func updateCandidate(_ best: inout Int, _ next: inout Int) {
        let met = metric()
        if met > best {
            next = best
            best = met
            for i in 0..<n { candidate[i] = codeword[i] }
        } else if met > next {
            next = met
        }
    }

    // MARK: - Sort

    private func mergeSort(_ a: inout [Int16], _ n: Int,
                           _ comp: (Int16, Int16) -> Bool) {
        // Simple insertion sort (sufficient for N=255)
        for i in 1..<n {
            let t = a[i]
            var j = i
            while j > 0 && comp(t, a[j - 1]) {
                a[j] = a[j - 1]
                j -= 1
            }
            a[j] = t
        }
    }
}
