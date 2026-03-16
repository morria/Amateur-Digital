//
//  ConvolutionalCodec.swift
//  AmateurDigitalCore
//
//  Rate-1/2 constraint-length-5 convolutional encoder and soft-decision Viterbi decoder.
//  Used by PSK31's QPSK mode for forward error correction.
//
//  The code uses the same polynomials as the PSK31 specification:
//  G1 = 0x19 (binary 11001, taps 0,3,4)
//  G2 = 0x17 (binary 10111, taps 0,1,2,4)
//
//  Soft-decision Viterbi decoding provides ~2 dB gain over hard-decision.
//
//  Reference: Phil Karn KA9Q, "Convolutional Decoders for Amateur Packet Radio"
//

import Foundation

public struct ConvolutionalCodec {

    /// Constraint length K=5 (4 memory elements, 16 states)
    public static let constraintLength = 5
    public static let numStates = 16  // 2^(K-1)
    public static let rate = 2  // Rate 1/2: 2 output bits per input bit

    /// Generator polynomials (octal: 31, 27 / binary: 11001, 10111)
    /// These are the standard PSK31 QPSK polynomials.
    private static let poly1: UInt8 = 0x19  // 11001
    private static let poly2: UInt8 = 0x17  // 10111

    /// Traceback depth: 5 * (K-1) = 20 is standard for rate-1/2
    public static let tracebackDepth = 20

    // MARK: - Encoder

    /// Encode a bit stream using the rate-1/2 K=5 convolutional code.
    /// Convention: new bits shift in at LSB (bit 0), old bits shift left toward MSB.
    /// State = bits [K-2..1] (the 4 memory elements, not including the current input).
    /// - Parameter bits: Input bit stream
    /// - Returns: Encoded bit stream (2x length + tail bits for flushing)
    public static func encode(_ bits: [Bool]) -> [Bool] {
        var register: UInt8 = 0  // 5-bit shift register
        var output: [Bool] = []
        output.reserveCapacity((bits.count + constraintLength - 1) * rate)

        let totalBits = bits.count + constraintLength - 1
        for i in 0..<totalBits {
            let inputBit: UInt8 = (i < bits.count && bits[i]) ? 1 : 0

            // Shift left, new bit enters at LSB
            register = ((register << 1) | inputBit) & 0x1F

            let out1 = parity(register & poly1)
            let out2 = parity(register & poly2)

            output.append(out1)
            output.append(out2)
        }

        return output
    }

    /// Compute parity (XOR of all bits) of a byte
    private static func parity(_ x: UInt8) -> Bool {
        var v = x
        v ^= v >> 4
        v ^= v >> 2
        v ^= v >> 1
        return (v & 1) == 1
    }

    // MARK: - Viterbi Decoder (Hard Decision)

    /// Decode using hard-decision Viterbi algorithm.
    /// - Parameter bits: Received bit stream (pairs of coded bits)
    /// - Returns: Decoded bit stream
    public static func decodeHard(_ bits: [Bool]) -> [Bool] {
        // Convert hard bits to soft metrics: true -> +127, false -> -127
        let soft = bits.map { $0 ? Int8(127) : Int8(-127) }
        return decodeSoft(soft)
    }

    // MARK: - Viterbi Decoder (Soft Decision)

    /// Decode using soft-decision Viterbi algorithm.
    /// Input is pairs of soft symbols (Int8, -127 to +127, positive = more likely '1').
    /// Provides ~2 dB gain over hard-decision decoding.
    ///
    /// - Parameter symbols: Soft symbols, pairs of (sym1, sym2) for each coded bit pair.
    ///   Length must be even.
    /// - Returns: Decoded bit stream
    public static func decodeSoft(_ symbols: [Int8]) -> [Bool] {
        guard symbols.count >= 2 else { return [] }

        let numSymbolPairs = symbols.count / 2
        let ns = numStates

        // Branch metrics table: for each state and input bit, compute the
        // expected output and store for metric computation.
        // nextState[state][input] and output[state][input] are precomputed.
        struct Transition {
            let nextState: Int
            let output0: Bool  // First coded bit
            let output1: Bool  // Second coded bit
        }

        // Build trellis transitions
        var transitions = [[Transition]](repeating: [Transition](repeating: Transition(nextState: 0, output0: false, output1: false), count: 2), count: ns)

        // State represents bits [K-1..1] of the shift register (the 4 memory elements).
        // The full 5-bit register is (state << 1 | input).
        // After shifting, the new state is the upper K-1 bits: (state << 1 | input) >> 1
        // which equals (state << 1 | input) >> 1, but since state is only K-1 bits,
        // nextState = ((state << 1) | input) >> 1 doesn't work directly.
        //
        // Correct mapping: full register = (state << 1 | input) & 0x1F
        // Next state = full register >> 1 = upper K-1 bits (drop LSB which was the oldest bit)
        //
        // Wait — the encoder shifts left (new at LSB), so:
        //   register = (old_register << 1 | input_bit) & 0x1F
        //   state = register >> 1 = bits [4..1] (dropping bit 0 = input)
        //
        // Actually state should be the memory BEFORE the new input:
        //   prev_state = old_register >> 1 (bits [4..1])
        //   full_register = (prev_state << 1 | input) & 0x1F (shift prev left, insert input)
        //   next_state = full_register >> 1 (new bits [4..1])

        for state in 0..<ns {
            for input in 0..<2 {
                let fullReg = UInt8((state << 1) | input) & 0x1F
                let out1 = parity(fullReg & poly1)
                let out2 = parity(fullReg & poly2)
                // Next state = lower K-1 bits (drop the oldest bit at position K-1)
                let nextState = Int(fullReg & UInt8(ns - 1))
                transitions[state][input] = Transition(nextState: nextState, output0: out1, output1: out2)
            }
        }

        // Path metrics (accumulated distance)
        var pathMetric = [Int](repeating: Int.max / 2, count: ns)
        pathMetric[0] = 0  // Start in state 0

        // Survivor paths: for each time step and state, store (input bit, previous state)
        var survivorInput = [[UInt8]](repeating: [UInt8](repeating: 0, count: ns), count: numSymbolPairs)
        var survivorPrev  = [[Int]](repeating: [Int](repeating: 0, count: ns), count: numSymbolPairs)

        // ACS (Add-Compare-Select) for each symbol pair
        for t in 0..<numSymbolPairs {
            let sym0 = Int(symbols[2 * t])      // First soft symbol
            let sym1 = Int(symbols[2 * t + 1])  // Second soft symbol

            var newPathMetric = [Int](repeating: Int.max / 2, count: ns)

            for state in 0..<ns {
                for input in 0..<2 {
                    let tr = transitions[state][input]

                    // Branch metric: correlation distance
                    // For soft decision: metric = sum of |received - expected|
                    // Expected +127 for '1', -127 for '0'
                    let exp0 = tr.output0 ? 127 : -127
                    let exp1 = tr.output1 ? 127 : -127
                    let branchMetric = abs(sym0 - exp0) + abs(sym1 - exp1)

                    let candidateMetric = pathMetric[state] + branchMetric

                    if candidateMetric < newPathMetric[tr.nextState] {
                        newPathMetric[tr.nextState] = candidateMetric
                        survivorInput[t][tr.nextState] = UInt8(input)
                        survivorPrev[t][tr.nextState] = state
                    }
                }
            }

            pathMetric = newPathMetric
        }

        // Traceback from the state with best metric
        var bestState = 0
        var bestMetric = pathMetric[0]
        for state in 1..<ns {
            if pathMetric[state] < bestMetric {
                bestMetric = pathMetric[state]
                bestState = state
            }
        }

        // Trace back: use stored previous states directly
        var decoded = [Bool](repeating: false, count: numSymbolPairs)
        var state = bestState
        for t in stride(from: numSymbolPairs - 1, through: 0, by: -1) {
            decoded[t] = survivorInput[t][state] == 1
            state = survivorPrev[t][state]
        }

        // Remove tail bits (K-1 = 4 flushing bits)
        let dataLength = max(0, numSymbolPairs - constraintLength + 1)
        return Array(decoded.prefix(dataLength))
    }

    // MARK: - Soft Symbol Quantization

    /// Quantize a phase distance to a 3-bit soft symbol (Int8 range).
    /// - Parameter phaseQuality: Phase quality metric from -1.0 (certain 0) to +1.0 (certain 1)
    /// - Returns: Soft symbol from -127 to +127
    public static func quantizeSoft(_ phaseQuality: Double) -> Int8 {
        let clamped = max(-1.0, min(1.0, phaseQuality))
        return Int8(clamped * 127.0)
    }
}
