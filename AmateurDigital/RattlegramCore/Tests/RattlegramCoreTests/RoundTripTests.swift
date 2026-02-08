import XCTest
@testable import RattlegramCore

final class RoundTripTests: XCTestCase {
    /// Encode a message then decode it, verifying round-trip integrity.
    func testRoundTrip8kHz() throws {
        let sampleRate = 8000
        try roundTrip(text: "HELLO", callSign: "TEST", sampleRate: sampleRate)
    }

    func testRoundTripLongerMessage() throws {
        let sampleRate = 8000
        try roundTrip(text: "CQ CQ CQ DE W1AW W1AW K", callSign: "W1AW",
                      sampleRate: sampleRate)
    }

    func testRoundTripMaxMode16() throws {
        // Mode 16: up to 85 bytes
        let text = String(repeating: "A", count: 80)
        try roundTrip(text: text, callSign: "N0CALL", sampleRate: 8000)
    }

    func testRoundTripMode15() throws {
        // Mode 15: 86-128 bytes
        let text = String(repeating: "B", count: 120)
        try roundTrip(text: text, callSign: "K1ABC", sampleRate: 8000)
    }

    private func roundTrip(text: String, callSign: String, sampleRate: Int) throws {
        let encoder = Encoder(sampleRate: sampleRate)
        let decoder = Decoder(sampleRate: sampleRate)

        // Prepare payload
        let utf8 = Array(text.utf8)
        var payload = [UInt8](repeating: 0, count: 170)
        for i in 0..<min(utf8.count, 170) {
            payload[i] = utf8[i]
        }

        encoder.configure(payload: payload, callSign: callSign,
                           carrierFrequency: 1500)

        // Collect all encoder output
        var allSamples = [Int16]()
        var audioBuffer = [Int16](repeating: 0, count: encoder.extendedLength)
        while encoder.produce(&audioBuffer) {
            allSamples.append(contentsOf: audioBuffer)
        }
        allSamples.append(contentsOf: audioBuffer) // final silence

        // Add some leading silence for the decoder to lock
        let leadingSilence = [Int16](repeating: 0, count: decoder.extendedLength * 2)
        var decoderInput = leadingSilence + allSamples

        // Add trailing silence
        decoderInput += [Int16](repeating: 0, count: decoder.extendedLength * 2)

        // Feed to decoder
        let extLen = decoder.extendedLength
        var offset = 0
        var synced = false
        var done = false
        var decodedText = ""
        var decodedCall = ""

        while offset + extLen <= decoderInput.count {
            let chunk = Array(decoderInput[offset..<(offset + extLen)])
            let ready = decoder.feed(chunk, sampleCount: extLen)
            offset += extLen

            if ready {
                let status = decoder.process()
                switch status {
                case .sync:
                    let info = decoder.staged()
                    decodedCall = info.callSign.trimmingCharacters(in: .whitespaces)
                    synced = true
                case .done:
                    var decodedPayload = [UInt8](repeating: 0, count: 170)
                    let result = decoder.fetch(&decodedPayload)
                    if result >= 0 {
                        var len = 0
                        while len < 170 && decodedPayload[len] != 0 { len += 1 }
                        decodedText = String(bytes: decodedPayload[0..<len], encoding: .utf8) ?? ""
                        done = true
                    }
                default:
                    break
                }
            }

            if done { break }
        }

        XCTAssertTrue(synced, "Decoder should detect sync for '\(text)'")
        XCTAssertTrue(done, "Decoder should complete for '\(text)'")
        XCTAssertEqual(decodedText, text, "Round-trip text mismatch")
        XCTAssertTrue(decodedCall.hasPrefix(callSign.trimmingCharacters(in: .whitespaces)),
                      "Call sign mismatch: expected '\(callSign)', got '\(decodedCall)'")
    }
}
