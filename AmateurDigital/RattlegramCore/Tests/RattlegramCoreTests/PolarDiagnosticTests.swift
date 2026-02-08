import XCTest
@testable import RattlegramCore

final class PolarDiagnosticTests: XCTestCase {
    /// Test that PolarSysEnc produces a systematic codeword:
    /// non-frozen positions should contain the original message bits.
    func testSystematicProperty() {
        let enc = PolarSysEnc()
        let frozen = frozen_2048_712  // mode 16: 680 data + 32 CRC = 712 info bits
        let level = 11
        let length = 1 << level  // 2048
        let infoBits = 712

        // Create a simple NRZ message
        var message = [Int8](repeating: 1, count: infoBits)
        message[0] = -1
        message[1] = 1
        message[2] = -1
        message[3] = -1
        message[10] = -1

        var code = [Int8](repeating: 0, count: length)
        enc.encode(&code, message, frozen, level)

        // Check systematic property: non-frozen positions should equal message
        var j = 0
        var mismatches = 0
        for i in 0..<length {
            let isFrozen = (frozen[i / 32] >> (i % 32)) & 1 != 0
            if !isFrozen {
                if j < infoBits {
                    if code[i] != message[j] {
                        mismatches += 1
                        if mismatches <= 5 {
                            print("Mismatch at code[\(i)] (msg[\(j)]): code=\(code[i]) msg=\(message[j])")
                        }
                    }
                    j += 1
                }
            }
        }
        XCTAssertEqual(mismatches, 0,
            "Systematic code should have message bits at non-frozen positions. Got \(mismatches) mismatches out of \(j)")
        XCTAssertEqual(j, infoBits, "Should have exactly \(infoBits) non-frozen positions")

        // Also check all code values are ±1
        for i in 0..<length {
            XCTAssertTrue(code[i] == 1 || code[i] == -1, "Code[\(i)] = \(code[i]), expected ±1")
        }
    }

    /// Test that the list decoder + non-systematic re-encode recovers the codeword.
    /// The list decoder recovers the u-vector; applying the non-systematic encoder
    /// to the u-vector should reproduce the original codeword.
    func testListDecoderNoiseless() {
        let sysEnc = PolarSysEnc()
        let nonSysEnc = PolarNonSysEnc()
        let frozen = frozen_2048_712
        let level = 11
        let length = 1 << level
        let infoBits = 712

        var message = [Int8](repeating: 1, count: infoBits)
        for i in stride(from: 0, to: infoBits, by: 3) {
            message[i] = -1
        }

        var code = [Int8](repeating: 0, count: length)
        sysEnc.encode(&code, message, frozen, level)

        // Decode: recovers the u-vector (NOT the message directly)
        let decoder = PolarListDecoder()
        var decoded = [SIMDVector](repeating: SIMDVector(), count: infoBits)
        decoder.decode(&decoded, code, frozen, level)

        // Re-encode path 0's u-vector through non-systematic encoder
        var uVector = [Int8](repeating: 0, count: infoBits)
        for i in 0..<infoBits {
            uVector[i] = decoded[i].v[0]
        }
        var reencoded = [Int8](repeating: 0, count: length)
        nonSysEnc.encode(&reencoded, uVector, frozen, level)

        // The re-encoded codeword should match the original
        var mismatches = 0
        for i in 0..<length {
            if reencoded[i] != code[i] {
                mismatches += 1
                if mismatches <= 5 {
                    print("Re-encode mismatch at \(i): reencoded=\(reencoded[i]) original=\(code[i])")
                }
            }
        }
        XCTAssertEqual(mismatches, 0,
            "Non-systematic re-encode of decoded u-vector should match original codeword. Got \(mismatches) mismatches")

        // Also verify: extracting non-frozen positions from re-encoded codeword gives original message
        var j = 0
        var msgMismatches = 0
        for i in 0..<length {
            let isFrozen = (frozen[i / 32] >> (i % 32)) & 1 != 0
            if !isFrozen && j < infoBits {
                if reencoded[i] != message[j] {
                    msgMismatches += 1
                }
                j += 1
            }
        }
        XCTAssertEqual(msgMismatches, 0,
            "Extracted message from re-encoded codeword should match original. Got \(msgMismatches) mismatches")
    }

    /// Test the full encoder-decoder wrapper round trip.
    func testWrapperRoundTrip() {
        let encoder = PolarEncoderWrapper()
        let decoder = PolarDecoderWrapper()
        let frozen = frozen_2048_712
        let dataBits = 680

        var msg = [UInt8](repeating: 0, count: 85)
        msg[0] = 0x48 // H

        var code = [Int8](repeating: 0, count: 2048)
        encoder.encode(&code, msg, frozen, dataBits)

        // Verify code is NRZ
        var nonNRZ = 0
        for c in code {
            if c != 1 && c != -1 { nonNRZ += 1 }
        }
        XCTAssertEqual(nonNRZ, 0, "Encoder should produce NRZ code values")

        // Try to decode
        var decoded = [UInt8](repeating: 0, count: 170)
        let result = decoder.decode(&decoded, code, frozen, dataBits)
        XCTAssertGreaterThanOrEqual(result, 0, "Decode should succeed for noiseless code")
        if result >= 0 {
            XCTAssertEqual(decoded[0], msg[0], "First byte should match")
        }
    }
}
