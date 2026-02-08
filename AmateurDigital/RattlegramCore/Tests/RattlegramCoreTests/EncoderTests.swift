import XCTest
@testable import RattlegramCore

final class EncoderTests: XCTestCase {
    func testEncoderInit() {
        let encoder = Encoder(sampleRate: 48000)
        XCTAssertEqual(encoder.sampleRate, 48000)
        XCTAssertEqual(encoder.symbolLength, 7680)
        XCTAssertEqual(encoder.guardLength, 960)
        XCTAssertEqual(encoder.extendedLength, 8640)
    }

    func testEncoderInit8000() {
        let encoder = Encoder(sampleRate: 8000)
        XCTAssertEqual(encoder.symbolLength, 1280)
        XCTAssertEqual(encoder.guardLength, 160)
        XCTAssertEqual(encoder.extendedLength, 1440)
    }

    func testEncoderProducesSymbols() {
        let encoder = Encoder(sampleRate: 8000)
        var payload = [UInt8](repeating: 0, count: 170)
        payload[0] = 0x48 // H
        payload[1] = 0x49 // I

        encoder.configure(payload: payload, callSign: "TEST",
                           carrierFrequency: 1500)

        var symbolCount = 0
        var audioBuffer = [Int16](repeating: 0, count: encoder.extendedLength)

        while encoder.produce(&audioBuffer) {
            symbolCount += 1
            // Sanity: should not produce indefinitely
            if symbolCount > 20 { break }
        }

        // Expected: 1 schmidl-cox + 1 preamble + 4 payload + 1 silence = 7
        XCTAssertGreaterThanOrEqual(symbolCount, 6)
        XCTAssertLessThanOrEqual(symbolCount, 20)
    }

    func testEncoderOutputNonSilent() {
        let encoder = Encoder(sampleRate: 8000)
        var payload = [UInt8](repeating: 0, count: 170)
        payload[0] = 0x41 // A

        encoder.configure(payload: payload, callSign: "W1AW",
                           carrierFrequency: 1500)

        var audioBuffer = [Int16](repeating: 0, count: encoder.extendedLength)
        let hasMore = encoder.produce(&audioBuffer)
        XCTAssertTrue(hasMore)

        // Check that audio is not all zeros
        var maxAbs: Int16 = 0
        for s in audioBuffer {
            let a = s < 0 ? -s : s
            if a > maxAbs { maxAbs = a }
        }
        XCTAssertGreaterThan(maxAbs, 0, "Encoder output should not be silent")
    }

    func testPingMode() {
        let encoder = Encoder(sampleRate: 8000)
        // Empty payload -> mode 0 (ping)
        let payload = [UInt8](repeating: 0, count: 170)
        encoder.configure(payload: payload, callSign: "TEST",
                           carrierFrequency: 1500)

        var symbolCount = 0
        var audioBuffer = [Int16](repeating: 0, count: encoder.extendedLength)

        while encoder.produce(&audioBuffer) {
            symbolCount += 1
            if symbolCount > 20 { break }
        }

        // Ping: schmidl-cox + preamble + silence = 3 symbols
        XCTAssertLessThanOrEqual(symbolCount, 5)
    }
}
