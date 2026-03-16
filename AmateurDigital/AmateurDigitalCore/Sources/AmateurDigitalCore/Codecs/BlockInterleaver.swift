//
//  BlockInterleaver.swift
//  AmateurDigitalCore
//
//  Rectangular block interleaver/deinterleaver for burst error protection.
//  Used with the convolutional code in QPSK31/QPSK63 to spread fading-induced
//  burst errors across multiple codewords so the Viterbi decoder can correct them.
//

import Foundation

public struct BlockInterleaver {

    /// Number of rows (depth of interleaving)
    public let rows: Int
    /// Number of columns (span of interleaving)
    public let cols: Int
    /// Total block size
    public var blockSize: Int { rows * cols }

    /// Create an interleaver with specified dimensions.
    /// - Parameters:
    ///   - rows: Number of rows (depth). Larger = more protection, more latency.
    ///   - cols: Number of columns (span).
    public init(rows: Int, cols: Int) {
        self.rows = max(1, rows)
        self.cols = max(1, cols)
    }

    /// PSK31 QPSK standard interleaver (10x10 block)
    public static let psk31 = BlockInterleaver(rows: 10, cols: 10)

    // MARK: - Interleave (TX)

    /// Interleave a block of bits: write by rows, read by columns.
    /// This spreads consecutive bits across the block so that a burst error
    /// affecting consecutive transmitted bits gets distributed across different
    /// positions in the decoded stream.
    public func interleave(_ bits: [Bool]) -> [Bool] {
        let n = blockSize
        guard bits.count >= n else {
            // Pad with zeros if input is shorter than block size
            var padded = bits
            while padded.count < n { padded.append(false) }
            return interleaveBlock(padded)
        }

        // Process in blocks
        var result: [Bool] = []
        result.reserveCapacity(bits.count)
        var offset = 0
        while offset + n <= bits.count {
            let block = Array(bits[offset..<(offset + n)])
            result.append(contentsOf: interleaveBlock(block))
            offset += n
        }
        // Handle remaining bits (pass through)
        if offset < bits.count {
            result.append(contentsOf: bits[offset...])
        }
        return result
    }

    /// Interleave a single block
    private func interleaveBlock(_ block: [Bool]) -> [Bool] {
        var result = [Bool](repeating: false, count: blockSize)
        for r in 0..<rows {
            for c in 0..<cols {
                // Write position: row-major (input order)
                let writeIdx = r * cols + c
                // Read position: column-major (output order)
                let readIdx = c * rows + r
                if writeIdx < block.count {
                    result[readIdx] = block[writeIdx]
                }
            }
        }
        return result
    }

    // MARK: - Deinterleave (RX)

    /// Deinterleave a block of bits: reverse the interleaving.
    public func deinterleave(_ bits: [Bool]) -> [Bool] {
        let n = blockSize
        guard bits.count >= n else {
            var padded = bits
            while padded.count < n { padded.append(false) }
            return deinterleaveBlock(padded)
        }

        var result: [Bool] = []
        result.reserveCapacity(bits.count)
        var offset = 0
        while offset + n <= bits.count {
            let block = Array(bits[offset..<(offset + n)])
            result.append(contentsOf: deinterleaveBlock(block))
            offset += n
        }
        if offset < bits.count {
            result.append(contentsOf: bits[offset...])
        }
        return result
    }

    /// Deinterleave a single block
    private func deinterleaveBlock(_ block: [Bool]) -> [Bool] {
        var result = [Bool](repeating: false, count: blockSize)
        for r in 0..<rows {
            for c in 0..<cols {
                let readIdx = c * rows + r
                let writeIdx = r * cols + c
                if readIdx < block.count {
                    result[writeIdx] = block[readIdx]
                }
            }
        }
        return result
    }

    // MARK: - Soft Symbol Interleaving

    /// Interleave soft symbols (for soft-decision Viterbi)
    public func interleaveSoft(_ symbols: [Int8]) -> [Int8] {
        let n = blockSize
        guard symbols.count >= n else { return symbols }

        var result: [Int8] = []
        result.reserveCapacity(symbols.count)
        var offset = 0
        while offset + n <= symbols.count {
            var block = [Int8](repeating: 0, count: n)
            for r in 0..<rows {
                for c in 0..<cols {
                    let writeIdx = r * cols + c
                    let readIdx = c * rows + r
                    if writeIdx + offset < symbols.count {
                        block[readIdx] = symbols[offset + writeIdx]
                    }
                }
            }
            result.append(contentsOf: block)
            offset += n
        }
        if offset < symbols.count {
            result.append(contentsOf: symbols[offset...])
        }
        return result
    }

    /// Deinterleave soft symbols
    public func deinterleaveSoft(_ symbols: [Int8]) -> [Int8] {
        let n = blockSize
        guard symbols.count >= n else { return symbols }

        var result: [Int8] = []
        result.reserveCapacity(symbols.count)
        var offset = 0
        while offset + n <= symbols.count {
            var block = [Int8](repeating: 0, count: n)
            for r in 0..<rows {
                for c in 0..<cols {
                    let readIdx = c * rows + r
                    let writeIdx = r * cols + c
                    if readIdx + offset < symbols.count {
                        block[writeIdx] = symbols[offset + readIdx]
                    }
                }
            }
            result.append(contentsOf: block)
            offset += n
        }
        if offset < symbols.count {
            result.append(contentsOf: symbols[offset...])
        }
        return result
    }
}
