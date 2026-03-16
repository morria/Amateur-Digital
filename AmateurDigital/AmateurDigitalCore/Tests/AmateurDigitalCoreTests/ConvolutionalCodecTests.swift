//
//  ConvolutionalCodecTests.swift
//  AmateurDigitalCoreTests
//
//  Tests for the rate-1/2 K=5 convolutional encoder and Viterbi decoder.
//

import XCTest
@testable import AmateurDigitalCore

final class ConvolutionalCodecTests: XCTestCase {

    // MARK: - Encoder Tests

    func testEncodeProducesCorrectLength() {
        let input = [true, false, true, true, false]
        let encoded = ConvolutionalCodec.encode(input)
        // Rate 1/2: output = (input + K-1) * 2 = (5+4) * 2 = 18
        XCTAssertEqual(encoded.count, (input.count + ConvolutionalCodec.constraintLength - 1) * ConvolutionalCodec.rate)
    }

    func testEncodeEmptyInput() {
        let encoded = ConvolutionalCodec.encode([])
        // K-1 tail bits * rate = 4 * 2 = 8
        XCTAssertEqual(encoded.count, (ConvolutionalCodec.constraintLength - 1) * ConvolutionalCodec.rate)
    }

    // MARK: - Hard Decision Round-Trip

    func testHardDecisionRoundTrip() {
        let input: [Bool] = [true, false, true, true, false, true, false, false, true, true]
        let encoded = ConvolutionalCodec.encode(input)
        let decoded = ConvolutionalCodec.decodeHard(encoded)
        XCTAssertEqual(decoded, input, "Hard-decision round-trip should be exact")
    }

    func testHardDecisionLongerMessage() {
        // Encode "HELLO" as bits
        let message = "HELLO"
        var bits: [Bool] = []
        for char in message.utf8 {
            for i in stride(from: 7, through: 0, by: -1) {
                bits.append((char >> i) & 1 == 1)
            }
        }
        let encoded = ConvolutionalCodec.encode(bits)
        let decoded = ConvolutionalCodec.decodeHard(encoded)
        XCTAssertEqual(decoded, bits, "Should decode HELLO bits exactly")
    }

    func testHardDecisionAllZeros() {
        let input = [Bool](repeating: false, count: 20)
        let encoded = ConvolutionalCodec.encode(input)
        let decoded = ConvolutionalCodec.decodeHard(encoded)
        XCTAssertEqual(decoded, input)
    }

    func testHardDecisionAllOnes() {
        let input = [Bool](repeating: true, count: 20)
        let encoded = ConvolutionalCodec.encode(input)
        let decoded = ConvolutionalCodec.decodeHard(encoded)
        XCTAssertEqual(decoded, input)
    }

    // MARK: - Soft Decision Round-Trip

    func testSoftDecisionCleanRoundTrip() {
        let input: [Bool] = [true, false, true, true, false, true, false, false]
        let encoded = ConvolutionalCodec.encode(input)
        // Convert to soft symbols: true -> +127, false -> -127
        let soft = encoded.map { $0 ? Int8(127) : Int8(-127) }
        let decoded = ConvolutionalCodec.decodeSoft(soft)
        XCTAssertEqual(decoded, input, "Clean soft-decision should be exact")
    }

    func testSoftDecisionWithNoise() {
        let input: [Bool] = [true, false, true, true, false, true, false, false, true, true, false, true]
        let encoded = ConvolutionalCodec.encode(input)
        var soft = encoded.map { $0 ? Int8(127) : Int8(-127) }

        // Add noise: flip confidence on some symbols (but not the sign)
        var rng: UInt64 = 42
        for i in 0..<soft.count {
            rng ^= rng >> 12; rng ^= rng << 25; rng ^= rng >> 27
            let noise = Int8(clamping: Int(rng % 60) - 30)
            let noisy = Int(soft[i]) + Int(noise)
            soft[i] = Int8(clamping: noisy)
        }

        let decoded = ConvolutionalCodec.decodeSoft(soft)
        XCTAssertEqual(decoded, input, "Moderate noise should still decode correctly")
    }

    func testSoftDecisionWithBitErrors() {
        let input: [Bool] = [true, false, true, true, false, true, false, false, true, true, false, true]
        let encoded = ConvolutionalCodec.encode(input)
        var soft = encoded.map { $0 ? Int8(100) : Int8(-100) }

        // Flip 2 soft symbols (simulating bit errors)
        soft[3] = -soft[3]
        soft[10] = -soft[10]

        let decoded = ConvolutionalCodec.decodeSoft(soft)
        // Viterbi should correct isolated errors
        XCTAssertEqual(decoded, input, "Should correct 2 bit errors in 32 coded bits")
    }

    // MARK: - Interleaver Tests

    func testInterleaveDeinterleaveRoundTrip() {
        let interleaver = BlockInterleaver.psk31
        let input = (0..<100).map { $0 % 2 == 0 }
        let interleaved = interleaver.interleave(input)
        let deinterleaved = interleaver.deinterleave(interleaved)
        XCTAssertEqual(deinterleaved, input, "Interleave/deinterleave should round-trip")
    }

    func testInterleaveShufflesBits() {
        let interleaver = BlockInterleaver(rows: 4, cols: 4)
        let input: [Bool] = [
            true,  true,  true,  true,   // Row 0
            false, false, false, false,   // Row 1
            true,  true,  true,  true,   // Row 2
            false, false, false, false,   // Row 3
        ]
        let interleaved = interleaver.interleave(input)
        // Column-major read should alternate between rows
        XCTAssertNotEqual(interleaved, input, "Interleaving should shuffle bits")
        // First column (indices 0,4,8,12 of input) should become first 4 of output
        XCTAssertEqual(interleaved[0], true)   // input[0]
        XCTAssertEqual(interleaved[1], false)  // input[4]
        XCTAssertEqual(interleaved[2], true)   // input[8]
        XCTAssertEqual(interleaved[3], false)  // input[12]
    }

    func testSoftSymbolInterleaveRoundTrip() {
        let interleaver = BlockInterleaver.psk31
        let input: [Int8] = (0..<100).map { Int8($0 % 127) }
        let interleaved = interleaver.interleaveSoft(input)
        let deinterleaved = interleaver.deinterleaveSoft(interleaved)
        XCTAssertEqual(deinterleaved, input)
    }

    // MARK: - Combined: Encode + Interleave + Deinterleave + Decode

    func testFullPipelineRoundTrip() {
        let input: [Bool] = [true, false, true, true, false, true, false, false,
                              true, true, false, true, false, true, true, false,
                              true, false, false, true, true, false, true, false]

        // TX: encode -> interleave
        let encoded = ConvolutionalCodec.encode(input)
        let interleaver = BlockInterleaver(rows: 4, cols: encoded.count / 4)
        let interleaved = interleaver.interleave(encoded)

        // Simulate channel: convert to soft and add noise
        var soft = interleaved.map { $0 ? Int8(100) : Int8(-100) }
        // Introduce a burst error (3 consecutive flips, simulating fade)
        soft[10] = -soft[10]
        soft[11] = -soft[11]
        soft[12] = -soft[12]

        // RX: deinterleave -> decode
        let deinterleaved = interleaver.deinterleaveSoft(soft)
        let decoded = ConvolutionalCodec.decodeSoft(deinterleaved)

        // The burst error should be spread by the deinterleaver so Viterbi can fix it
        XCTAssertEqual(decoded, input, "Full pipeline should correct burst error of 3 bits")
    }

    // MARK: - Quantization

    func testQuantizeSoft() {
        XCTAssertEqual(ConvolutionalCodec.quantizeSoft(1.0), 127)
        XCTAssertEqual(ConvolutionalCodec.quantizeSoft(-1.0), -127)
        XCTAssertEqual(ConvolutionalCodec.quantizeSoft(0.0), 0)
        XCTAssertEqual(ConvolutionalCodec.quantizeSoft(0.5), 63)
    }
}
