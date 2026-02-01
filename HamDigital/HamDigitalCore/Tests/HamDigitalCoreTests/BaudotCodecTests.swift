//
//  BaudotCodecTests.swift
//  DigiModesCoreTests
//

import XCTest
@testable import HamDigitalCore

final class BaudotCodecTests: XCTestCase {

    var codec: BaudotCodec!

    override func setUp() {
        super.setUp()
        codec = BaudotCodec()
    }

    override func tearDown() {
        codec = nil
        super.tearDown()
    }

    // MARK: - Decoding Tests

    func testDecodeLetters() {
        // Test basic letter decoding
        XCTAssertEqual(codec.decode(0x01), "E")
        XCTAssertEqual(codec.decode(0x03), "A")
        XCTAssertEqual(codec.decode(0x05), "S")
        XCTAssertEqual(codec.decode(0x10), "T")
    }

    func testDecodeSpace() {
        XCTAssertEqual(codec.decode(0x04), " ")
    }

    func testDecodeCarriageReturnLineFeed() {
        XCTAssertEqual(codec.decode(0x08), "\r")
        XCTAssertEqual(codec.decode(0x02), "\n")
    }

    func testDecodeFiguresAfterShift() {
        // First decode FIGS shift
        XCTAssertNil(codec.decode(0x1B))  // FIGS shift returns nil
        XCTAssertEqual(codec.currentShift, .figures)

        // Now decode figures
        XCTAssertEqual(codec.decode(0x01), "3")
        XCTAssertEqual(codec.decode(0x10), "5")
        XCTAssertEqual(codec.decode(0x19), "?")
    }

    func testDecodeShiftBackToLetters() {
        // Switch to figures
        _ = codec.decode(0x1B)  // FIGS
        XCTAssertEqual(codec.currentShift, .figures)

        // Switch back to letters
        XCTAssertNil(codec.decode(0x1F))  // LTRS shift returns nil
        XCTAssertEqual(codec.currentShift, .letters)

        // Verify we're back in letters mode
        XCTAssertEqual(codec.decode(0x01), "E")
    }

    func testDecodeString() {
        // "CQ" in Baudot: C=0x0E, Q=0x17
        let codes: [UInt8] = [0x0E, 0x17]
        let result = codec.decode(codes)
        XCTAssertEqual(result, "CQ")
    }

    func testDecodeStringWithShift() {
        // "A1" requires shift: A=0x03, FIGS=0x1B, 1=0x17
        let codes: [UInt8] = [0x03, 0x1B, 0x17]
        let result = codec.decode(codes)
        XCTAssertEqual(result, "A1")
    }

    // MARK: - Encoding Tests

    func testEncodeLetters() {
        let codes = codec.encode("A")
        XCTAssertEqual(codes, [0x03])
    }

    func testEncodeLowercaseConvertsToUpper() {
        let codes = codec.encode("a")
        XCTAssertEqual(codes, [0x03])  // Same as "A"
    }

    func testEncodeSpace() {
        let codes = codec.encode(" ")
        XCTAssertEqual(codes, [0x04])
    }

    func testEncodeFiguresRequiresShift() {
        codec = BaudotCodec(initialShift: .letters)
        let codes = codec.encode("5")
        // Should be: FIGS shift (0x1B), then 5 (0x10)
        XCTAssertEqual(codes, [0x1B, 0x10])
        XCTAssertEqual(codec.currentShift, .figures)
    }

    func testEncodeStringCQ() {
        let codes = codec.encode("CQ")
        // C=0x0E, Q=0x17
        XCTAssertEqual(codes, [0x0E, 0x17])
    }

    func testEncodeStringWithMixedShifts() {
        let codes = codec.encode("A1B")
        // A=0x03, FIGS=0x1B, 1=0x17, LTRS=0x1F, B=0x19
        XCTAssertEqual(codes, [0x03, 0x1B, 0x17, 0x1F, 0x19])
    }

    func testEncodeWithPreamble() {
        let codes = codec.encodeWithPreamble("CQ", preambleCount: 2)
        // LTRS, LTRS, C, Q
        XCTAssertEqual(codes, [0x1F, 0x1F, 0x0E, 0x17])
    }

    // MARK: - Round-trip Tests

    func testRoundTripLettersOnly() {
        let original = "CQ CQ CQ DE W1AW"
        let encoder = BaudotCodec()
        let decoder = BaudotCodec()

        let encoded = encoder.encode(original)
        let decoded = decoder.decode(encoded)

        XCTAssertEqual(decoded, original)
    }

    func testRoundTripWithNumbers() {
        let original = "RST 599"
        let encoder = BaudotCodec()
        let decoder = BaudotCodec()

        let encoded = encoder.encode(original)
        let decoded = decoder.decode(encoded)

        XCTAssertEqual(decoded, original)
    }

    func testRoundTripMixedContent() {
        let original = "UR RST 599 599 NAME HIRAM QTH CT"
        let encoder = BaudotCodec()
        let decoder = BaudotCodec()

        let encoded = encoder.encode(original)
        let decoded = decoder.decode(encoded)

        XCTAssertEqual(decoded, original)
    }

    // MARK: - Edge Cases

    func testResetState() {
        // Switch to figures
        _ = codec.decode(0x1B)
        XCTAssertEqual(codec.currentShift, .figures)

        // Reset
        codec.reset()
        XCTAssertEqual(codec.currentShift, .letters)
    }

    func testUnknownCharacterEncodesAsSpace() {
        // Characters not in Baudot (like @) should encode as space
        let codes = codec.encode("@")
        XCTAssertEqual(codes, [0x04])  // Space
    }

    func testMasksTo5Bits() {
        // Even if we pass in garbage high bits, it should mask to 5 bits
        // 0xFF & 0x1F = 0x1F = LTRS shift
        XCTAssertNil(codec.decode(0xFF))
    }
}
