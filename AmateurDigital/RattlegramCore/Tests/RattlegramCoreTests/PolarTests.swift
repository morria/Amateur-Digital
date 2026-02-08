import XCTest
@testable import RattlegramCore

final class PolarTests: XCTestCase {
    func testPolarEncoderInit() {
        let encoder = PolarEncoderWrapper()
        _ = encoder
    }

    func testPolarDecoderInit() {
        let decoder = PolarDecoderWrapper()
        _ = decoder
    }

    func testPolarEncodeRoundTrip() {
        let encoder = PolarEncoderWrapper()
        let decoder = PolarDecoderWrapper()

        // Mode 16: 680 data bits = 85 bytes
        let dataBits = 680
        let frozenBits = frozen_2048_712
        let codeLen = 2048

        // Create test message
        var message = [UInt8](repeating: 0, count: 85)
        message[0] = 0x48 // H
        message[1] = 0x45 // E
        message[2] = 0x4C // L
        message[3] = 0x4C // L
        message[4] = 0x4F // O

        var code = [Int8](repeating: 0, count: codeLen)
        encoder.encode(&code, message, frozenBits, dataBits)

        // Verify code is non-trivial
        var nonZero = 0
        for v in code {
            if v != 0 { nonZero += 1 }
        }
        XCTAssertGreaterThan(nonZero, 0, "Encoded code should have non-zero values")

        // Decode
        var decoded = [UInt8](repeating: 0, count: 170)
        let result = decoder.decode(&decoded, code, frozenBits, dataBits)
        XCTAssertGreaterThanOrEqual(result, 0, "Polar decode should succeed")

        // Verify first few bytes match
        XCTAssertEqual(decoded[0], 0x48)
        XCTAssertEqual(decoded[1], 0x45)
        XCTAssertEqual(decoded[2], 0x4C)
        XCTAssertEqual(decoded[3], 0x4C)
        XCTAssertEqual(decoded[4], 0x4F)
    }

    func testPolarEncodeMode15() {
        let encoder = PolarEncoderWrapper()
        let decoder = PolarDecoderWrapper()

        let dataBits = 1024
        let frozenBits = frozen_2048_1056
        let codeLen = 2048

        var message = [UInt8](repeating: 0, count: dataBits / 8)
        for i in 0..<min(message.count, 10) {
            message[i] = UInt8(i + 1)
        }

        var code = [Int8](repeating: 0, count: codeLen)
        encoder.encode(&code, message, frozenBits, dataBits)

        var decoded = [UInt8](repeating: 0, count: 170)
        let result = decoder.decode(&decoded, code, frozenBits, dataBits)
        XCTAssertGreaterThanOrEqual(result, 0, "Mode 15 polar decode should succeed")

        for i in 0..<10 {
            XCTAssertEqual(decoded[i], UInt8(i + 1), "Byte \(i) mismatch in mode 15")
        }
    }

    func testPolarHelperSaturating() {
        // Test clamped addition
        let result = PolarHelper.qadd(100, 100)
        XCTAssertEqual(result, 127) // saturated

        let result2 = PolarHelper.qadd(-100, -100)
        XCTAssertEqual(result2, -127) // saturated

        let result3 = PolarHelper.qadd(50, 30)
        XCTAssertEqual(result3, 80) // not saturated
    }
}
