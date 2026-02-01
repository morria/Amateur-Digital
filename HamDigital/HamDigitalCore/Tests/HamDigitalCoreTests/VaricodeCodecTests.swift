//
//  VaricodeCodecTests.swift
//  HamDigitalCoreTests
//
//  Tests for Varicode encoding/decoding
//

import XCTest
@testable import HamDigitalCore

final class VaricodeCodecTests: XCTestCase {

    var codec: VaricodeCodec!

    override func setUp() {
        super.setUp()
        codec = VaricodeCodec()
    }

    override func tearDown() {
        codec = nil
        super.tearDown()
    }

    // MARK: - Encoding Tests

    func testEncodeSpace() {
        // Space is the shortest code: just 1 bit
        let bits = codec.encode(" ")
        XCTAssertEqual(bits, [true, false, false])  // 1 + 00 separator
    }

    func testEncodeE() {
        // 'e' is 2 bits: 11
        let bits = codec.encode("e")
        XCTAssertEqual(bits, [true, true, false, false])  // 11 + 00 separator
    }

    func testEncodeT() {
        // 't' is 3 bits: 101
        let bits = codec.encode("t")
        XCTAssertEqual(bits, [true, false, true, false, false])  // 101 + 00
    }

    func testEncodeO() {
        // 'o' is 3 bits: 111
        let bits = codec.encode("o")
        XCTAssertEqual(bits, [true, true, true, false, false])  // 111 + 00
    }

    func testEncodeCQ() {
        // Encode "CQ" - two uppercase letters
        let bits = codec.encode("CQ")
        XCTAssertFalse(bits.isEmpty)
        // C = 10101101 (8 bits) + 00, Q = 111011101 (9 bits) + 00
        // Total should be 8 + 2 + 9 + 2 = 21 bits
        XCTAssertEqual(bits.count, 21)
    }

    func testEncodeMixedCase() {
        // Case-sensitive encoding
        let bitsLower = codec.encode("a")
        codec.reset()
        let bitsUpper = codec.encode("A")

        // 'a' and 'A' should have different encodings
        XCTAssertNotEqual(bitsLower, bitsUpper)
    }

    func testEncodeWithPreamble() {
        let bits = codec.encodeWithPreamble("e", idleBits: 8)
        // 8 idle bits + 'e' (2 bits) + separator (2 bits) = 12 bits
        XCTAssertEqual(bits.count, 12)
        // First 8 bits should be zeros (idle)
        for i in 0..<8 {
            XCTAssertFalse(bits[i], "Idle bit \(i) should be false")
        }
    }

    // MARK: - Decoding Tests

    func testDecodeSpace() {
        // Space = 1, then 00 separator
        let bits: [Bool] = [true, false, false]
        let result = codec.decode(bits: bits)
        XCTAssertEqual(result, " ")
    }

    func testDecodeE() {
        // e = 11, then 00 separator
        let bits: [Bool] = [true, true, false, false]
        let result = codec.decode(bits: bits)
        XCTAssertEqual(result, "e")
    }

    func testDecodeT() {
        // t = 101, then 00 separator
        let bits: [Bool] = [true, false, true, false, false]
        let result = codec.decode(bits: bits)
        XCTAssertEqual(result, "t")
    }

    func testDecodeMultipleCharacters() {
        // "et" = 11 00 101 00
        let bits: [Bool] = [true, true, false, false, true, false, true, false, false]
        let result = codec.decode(bits: bits)
        XCTAssertEqual(result, "et")
    }

    func testDecodeWithLeadingZeros() {
        // Leading zeros (idle) should be ignored
        let bits: [Bool] = [false, false, false, false, true, true, false, false]
        let result = codec.decode(bits: bits)
        XCTAssertEqual(result, "e")
    }

    // MARK: - Round-trip Tests

    func testRoundTripSingleCharacter() {
        let original = "a"
        let encoder = VaricodeCodec()
        let decoder = VaricodeCodec()

        let encoded = encoder.encode(original)
        let decoded = decoder.decode(bits: encoded)

        XCTAssertEqual(decoded, original)
    }

    func testRoundTripSpace() {
        let original = " "
        let encoder = VaricodeCodec()
        let decoder = VaricodeCodec()

        let encoded = encoder.encode(original)
        let decoded = decoder.decode(bits: encoded)

        XCTAssertEqual(decoded, original)
    }

    func testRoundTripShortText() {
        let original = "cq"
        let encoder = VaricodeCodec()
        let decoder = VaricodeCodec()

        let encoded = encoder.encode(original)
        let decoded = decoder.decode(bits: encoded)

        XCTAssertEqual(decoded, original)
    }

    func testRoundTripMixedCase() {
        let original = "CQ cq CQ"
        let encoder = VaricodeCodec()
        let decoder = VaricodeCodec()

        let encoded = encoder.encode(original)
        let decoded = decoder.decode(bits: encoded)

        XCTAssertEqual(decoded, original)
    }

    func testRoundTripCallsign() {
        let original = "W1AW"
        let encoder = VaricodeCodec()
        let decoder = VaricodeCodec()

        let encoded = encoder.encode(original)
        let decoded = decoder.decode(bits: encoded)

        XCTAssertEqual(decoded, original)
    }

    func testRoundTripNumbers() {
        let original = "73"
        let encoder = VaricodeCodec()
        let decoder = VaricodeCodec()

        let encoded = encoder.encode(original)
        let decoded = decoder.decode(bits: encoded)

        XCTAssertEqual(decoded, original)
    }

    func testRoundTripPunctuation() {
        let original = "CQ? de W1AW!"
        let encoder = VaricodeCodec()
        let decoder = VaricodeCodec()

        let encoded = encoder.encode(original)
        let decoded = decoder.decode(bits: encoded)

        XCTAssertEqual(decoded, original)
    }

    func testRoundTripFullMessage() {
        let original = "CQ CQ CQ de W1AW W1AW pse k"
        let encoder = VaricodeCodec()
        let decoder = VaricodeCodec()

        let encoded = encoder.encode(original)
        let decoded = decoder.decode(bits: encoded)

        XCTAssertEqual(decoded, original)
    }

    func testRoundTripNewline() {
        let original = "line1\nline2"
        let encoder = VaricodeCodec()
        let decoder = VaricodeCodec()

        let encoded = encoder.encode(original)
        let decoded = decoder.decode(bits: encoded)

        XCTAssertEqual(decoded, original)
    }

    // MARK: - Bit Length Tests

    func testBitLengthSpace() {
        let length = VaricodeCodec.bitLength(for: " ")
        XCTAssertEqual(length, 3)  // 1 bit + 2 separator
    }

    func testBitLengthE() {
        let length = VaricodeCodec.bitLength(for: "e")
        XCTAssertEqual(length, 4)  // 2 bits + 2 separator
    }

    func testBitLengthString() {
        let length = VaricodeCodec.bitLength(for: "test")
        XCTAssertTrue(length > 0)
    }

    // MARK: - Edge Cases

    func testResetState() {
        // Decode partial data
        _ = codec.decode(bit: true)
        _ = codec.decode(bit: true)

        // Reset
        codec.reset()

        // Decode fresh data - should work correctly
        let bits: [Bool] = [true, true, false, false]  // "e"
        let result = codec.decode(bits: bits)
        XCTAssertEqual(result, "e")
    }

    func testNonAsciiCharacterReturnsNil() {
        // Single non-ASCII character returns nil
        let char: Character = "é"
        let bits = codec.encode(char)
        XCTAssertNil(bits)
    }

    func testNonAsciiInStringSkipped() {
        // Non-ASCII characters in a string are skipped
        let bits = codec.encode("aéb")
        // Should only encode 'a' and 'b', skipping 'é'
        let decoder = VaricodeCodec()
        let decoded = decoder.decode(bits: bits)
        XCTAssertEqual(decoded, "ab")
    }

    func testEmptyStringEncode() {
        let bits = codec.encode("")
        XCTAssertTrue(bits.isEmpty)
    }

    func testEmptyBitsDecode() {
        let result = codec.decode(bits: [])
        XCTAssertEqual(result, "")
    }

    func testAllZerosDecode() {
        // All zeros should produce no output (just idle)
        let bits = [Bool](repeating: false, count: 100)
        let result = codec.decode(bits: bits)
        XCTAssertEqual(result, "")
    }
}
