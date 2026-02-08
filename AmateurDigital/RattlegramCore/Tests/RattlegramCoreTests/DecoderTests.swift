import XCTest
@testable import RattlegramCore

final class DecoderTests: XCTestCase {
    func testDecoderInit() {
        let decoder = Decoder(sampleRate: 48000)
        XCTAssertEqual(decoder.sampleRate, 48000)
        XCTAssertEqual(decoder.symbolLength, 7680)
        XCTAssertEqual(decoder.guardLength, 960)
        XCTAssertEqual(decoder.extendedLength, 8640)
    }

    func testDecoderInit8000() {
        let decoder = Decoder(sampleRate: 8000)
        XCTAssertEqual(decoder.symbolLength, 1280)
        XCTAssertEqual(decoder.guardLength, 160)
        XCTAssertEqual(decoder.extendedLength, 1440)
    }

    func testDecoderFeedSilence() {
        let decoder = Decoder(sampleRate: 8000)
        let silence = [Int16](repeating: 0, count: decoder.extendedLength)
        let ready = decoder.feed(silence, sampleCount: decoder.extendedLength)
        XCTAssertTrue(ready, "Feed should return true after extendedLength samples")

        let status = decoder.process()
        // Silence should not produce sync
        XCTAssertNotEqual(status, .sync)
        XCTAssertNotEqual(status, .done)
    }

    func testDecoderFeedNoise() {
        let decoder = Decoder(sampleRate: 8000)
        var noise = [Int16](repeating: 0, count: decoder.extendedLength)
        for i in 0..<noise.count {
            noise[i] = Int16.random(in: -1000...1000)
        }
        let ready = decoder.feed(noise, sampleCount: decoder.extendedLength)
        if ready {
            let status = decoder.process()
            // Random noise should not sync
            XCTAssertNotEqual(status, .done)
        }
    }
}
