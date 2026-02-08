/*
 Successive cancellation list decoding of polar codes - ported from polar_list_decoder.hh
 Original Copyright 2020 Ahmet Inan <inan@aicodix.de>
 */

import Foundation

public final class PolarListDecoder {
    public static let codeOrder = 11
    public static let codeLen = 1 << codeOrder
    private static let maxN = codeLen

    private var soft: [SIMDVector]
    private var hard: [SIMDVector]
    private var maps: [SIMDMap]

    public init() {
        soft = [SIMDVector](repeating: SIMDVector(), count: 2 * Self.maxN)
        hard = [SIMDVector](repeating: SIMDVector(), count: Self.maxN)
        maps = [SIMDMap](repeating: SIMDMap(), count: Self.maxN)
    }

    public func decode(_ message: inout [SIMDVector], _ codeword: [Int8],
                        _ frozen: [UInt32], _ level: Int) {
        var metric = [Int](repeating: 0, count: SIMDVector.SIZE)
        var count = 0
        metric[0] = 0
        for k in 1..<SIMDVector.SIZE {
            metric[k] = 1000000
        }
        let length = 1 << level
        for i in 0..<length {
            soft[length + i] = vdup(codeword[i])
        }
        decodeTree(&metric, &message, &maps, &count, &hard, &soft,
                   frozen, level, 0, 0, 0)

        // Unwind the permutation maps
        var acc = maps[count - 1]
        for i in stride(from: count - 2, through: 0, by: -1) {
            message[i] = vshuf(message[i], acc)
            acc = vshuf(maps[i], acc)
        }
    }

    // MARK: - Recursive tree decoder

    private func decodeTree(_ metric: inout [Int], _ message: inout [SIMDVector],
                            _ maps: inout [SIMDMap], _ count: inout Int,
                            _ hard: inout [SIMDVector], _ soft: inout [SIMDVector],
                            _ frozen: [UInt32], _ m: Int,
                            _ hardOff: Int, _ softOff: Int, _ frozenBitOff: Int) -> SIMDMap {
        if m == 1 {
            return decodeM1(&metric, &message, &maps, &count, &hard, &soft,
                            frozen, hardOff, softOff, frozenBitOff)
        }

        let n = 1 << m
        let halfN = n / 2

        // Compute left soft values
        for i in 0..<halfN {
            soft[softOff + i + halfN] = PolarHelperSIMD.prod(
                soft[softOff + i + n], soft[softOff + i + halfN + n])
        }

        // Check if left subtree is all frozen
        let lmap: SIMDMap
        if isAllFrozen(frozen, frozenBitOff, halfN) {
            lmap = rate0(&metric, &hard, &soft, hardOff, softOff, halfN)
        } else {
            lmap = decodeTree(&metric, &message, &maps, &count, &hard, &soft,
                              frozen, m - 1, hardOff, softOff, frozenBitOff)
        }

        // Compute right soft values
        for i in 0..<halfN {
            soft[softOff + i + halfN] = PolarHelperSIMD.madd(
                hard[hardOff + i],
                vshuf(soft[softOff + i + n], lmap),
                vshuf(soft[softOff + i + halfN + n], lmap))
        }

        // Check if right subtree is all frozen
        let rmap: SIMDMap
        if isAllFrozen(frozen, frozenBitOff + halfN, halfN) {
            rmap = rate0(&metric, &hard, &soft, hardOff + halfN, softOff, halfN)
        } else {
            rmap = decodeTree(&metric, &message, &maps, &count, &hard, &soft,
                              frozen, m - 1, hardOff + halfN, softOff, frozenBitOff + halfN)
        }

        // Combine hard decisions
        for i in 0..<halfN {
            hard[hardOff + i] = PolarHelperSIMD.qmul(
                vshuf(hard[hardOff + i], rmap), hard[hardOff + halfN + i])
        }

        return vshuf(lmap, rmap)
    }

    // MARK: - M=1 leaf node

    private func decodeM1(_ metric: inout [Int], _ message: inout [SIMDVector],
                          _ maps: inout [SIMDMap], _ count: inout Int,
                          _ hard: inout [SIMDVector], _ soft: inout [SIMDVector],
                          _ frozen: [UInt32], _ hardOff: Int, _ softOff: Int,
                          _ frozenBitOff: Int) -> SIMDMap {
        // Compute soft value
        soft[softOff + 1] = PolarHelperSIMD.prod(soft[softOff + 2], soft[softOff + 3])

        let frozenLeft = isFrozen(frozen, frozenBitOff)
        let frozenRight = isFrozen(frozen, frozenBitOff + 1)

        let lmap: SIMDMap
        if frozenLeft {
            lmap = rate0Leaf(&metric, &hard, &soft, hardOff, softOff)
        } else {
            lmap = rate1Leaf(&metric, &message, &maps, &count, &hard, &soft, hardOff, softOff)
        }

        // Compute right soft value
        soft[softOff + 1] = PolarHelperSIMD.madd(
            hard[hardOff],
            vshuf(soft[softOff + 2], lmap),
            vshuf(soft[softOff + 3], lmap))

        let rmap: SIMDMap
        if frozenRight {
            rmap = rate0Leaf(&metric, &hard, &soft, hardOff + 1, softOff)
        } else {
            rmap = rate1Leaf(&metric, &message, &maps, &count, &hard, &soft, hardOff + 1, softOff)
        }

        // Combine
        hard[hardOff] = PolarHelperSIMD.qmul(vshuf(hard[hardOff], rmap), hard[hardOff + 1])

        return vshuf(lmap, rmap)
    }

    // MARK: - Rate-0 node (all frozen)

    private func rate0(_ metric: inout [Int], _ hard: inout [SIMDVector],
                       _ soft: inout [SIMDVector], _ hardOff: Int, _ softOff: Int,
                       _ n: Int) -> SIMDMap {
        for i in 0..<n {
            hard[hardOff + i] = PolarHelperSIMD.one()
        }
        for i in 0..<n {
            for k in 0..<SIMDVector.SIZE {
                if soft[softOff + i + n].v[k] < 0 {
                    metric[k] -= Int(soft[softOff + i + n].v[k])
                }
            }
        }
        var map = SIMDMap()
        for k in 0..<SIMDVector.SIZE {
            map.v[k] = UInt8(k)
        }
        return map
    }

    private func rate0Leaf(_ metric: inout [Int], _ hard: inout [SIMDVector],
                           _ soft: inout [SIMDVector], _ hardOff: Int, _ softOff: Int) -> SIMDMap {
        hard[hardOff] = PolarHelperSIMD.one()
        for k in 0..<SIMDVector.SIZE {
            if soft[softOff + 1].v[k] < 0 {
                metric[k] -= Int(soft[softOff + 1].v[k])
            }
        }
        var map = SIMDMap()
        for k in 0..<SIMDVector.SIZE {
            map.v[k] = UInt8(k)
        }
        return map
    }

    // MARK: - Rate-1 leaf node (information bit)

    private func rate1Leaf(_ metric: inout [Int], _ message: inout [SIMDVector],
                           _ maps: inout [SIMDMap], _ count: inout Int,
                           _ hard: inout [SIMDVector], _ soft: inout [SIMDVector],
                           _ hardOff: Int, _ softOff: Int) -> SIMDMap {
        let sft = soft[softOff + 1]

        // Fork: each existing path splits into two (keep bit = +1 or flip bit = -1)
        var fork = [Int](repeating: 0, count: 2 * SIMDVector.SIZE)
        for k in 0..<SIMDVector.SIZE {
            fork[2 * k] = metric[k]
            fork[2 * k + 1] = metric[k]
        }
        for k in 0..<SIMDVector.SIZE {
            if sft.v[k] < 0 {
                fork[2 * k] -= Int(sft.v[k])
            } else {
                fork[2 * k + 1] += Int(sft.v[k])
            }
        }

        // Sort and keep best SIZE paths
        var perm = [Int](repeating: 0, count: 2 * SIMDVector.SIZE)
        insertionSort(&perm, &fork)

        for k in 0..<SIMDVector.SIZE {
            metric[k] = fork[k]
        }

        var map = SIMDMap()
        for k in 0..<SIMDVector.SIZE {
            map.v[k] = UInt8(perm[k] >> 1)
        }

        var hrd = SIMDVector()
        for k in 0..<SIMDVector.SIZE {
            hrd.v[k] = Int8(1 - 2 * (perm[k] & 1))
        }

        message[count] = hrd
        maps[count] = map
        count += 1

        hard[hardOff] = hrd
        return map
    }

    // MARK: - Helpers

    private func isFrozen(_ frozen: [UInt32], _ idx: Int) -> Bool {
        (frozen[idx / 32] >> (idx % 32)) & 1 != 0
    }

    private func isAllFrozen(_ frozen: [UInt32], _ startBit: Int, _ count: Int) -> Bool {
        // Check if all bits in range [startBit, startBit+count) are set
        for i in 0..<count {
            if !isFrozen(frozen, startBit + i) {
                return false
            }
        }
        return true
    }

    /// Insertion sort that produces sorted fork[] and corresponding permutation perm[]
    private func insertionSort(_ perm: inout [Int], _ fork: inout [Int]) {
        let n = 2 * SIMDVector.SIZE
        for i in 0..<n { perm[i] = i }
        // Sort by ascending metric (best = smallest)
        for i in 1..<n {
            let t = fork[i]
            let p = perm[i]
            var j = i
            while j > 0 && t < fork[j - 1] {
                fork[j] = fork[j - 1]
                perm[j] = perm[j - 1]
                j -= 1
            }
            fork[j] = t
            perm[j] = p
        }
    }
}
