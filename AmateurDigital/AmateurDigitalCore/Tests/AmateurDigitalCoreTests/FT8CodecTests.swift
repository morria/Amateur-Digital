//
//  FT8CodecTests.swift
//  AmateurDigitalCoreTests
//
//  Tests for the FT8 77-bit message codec.
//

import XCTest
@testable import AmateurDigitalCore

final class FT8CodecTests: XCTestCase {

    // MARK: - Callsign Encoding (pack28 / unpack28)

    func testPack28StandardCallsigns() {
        // Standard callsigns should round-trip through pack28/unpack28
        // Note: N0CALL has 4-letter suffix which is non-standard in FT8 (max 3 suffix letters)
        let callsigns = ["K1ABC", "W9XYZ", "KA1ABC", "W1AW", "G4ABC", "PA9XYZ", "KH7Z"]
        for call in callsigns {
            guard let n28 = FT8Codec.pack28(call) else {
                XCTFail("Failed to pack callsign: \(call)")
                continue
            }
            guard let unpacked = FT8Codec.unpack28(n28) else {
                XCTFail("Failed to unpack callsign \(call) from n28=\(n28)")
                continue
            }
            XCTAssertEqual(unpacked, call, "Round-trip failed for \(call)")
        }
    }

    func testPack28SpecialTokens() {
        XCTAssertEqual(FT8Codec.pack28("DE"), 0)
        XCTAssertEqual(FT8Codec.pack28("QRZ"), 1)
        XCTAssertEqual(FT8Codec.pack28("CQ"), 2)
    }

    func testUnpack28SpecialTokens() {
        XCTAssertEqual(FT8Codec.unpack28(0), "DE")
        XCTAssertEqual(FT8Codec.unpack28(1), "QRZ")
        XCTAssertEqual(FT8Codec.unpack28(2), "CQ")
    }

    func testPack28CQWithFrequency() {
        // CQ nnn (frequency)
        guard let n28 = FT8Codec.pack28("CQ 100") else {
            XCTFail("Failed to pack CQ 100")
            return
        }
        XCTAssertEqual(n28, 3 + 100)

        guard let unpacked = FT8Codec.unpack28(n28) else {
            XCTFail("Failed to unpack CQ 100")
            return
        }
        XCTAssertEqual(unpacked, "CQ_100")
    }

    func testPack28CQDirected() {
        // CQ xxxx (directed CQ like CQ DX, CQ TEST, CQ FD)
        let directedCQs = ["CQ DX", "CQ TEST", "CQ FD", "CQ NA"]
        for cq in directedCQs {
            guard let n28 = FT8Codec.pack28(cq) else {
                XCTFail("Failed to pack: \(cq)")
                continue
            }
            guard let unpacked = FT8Codec.unpack28(n28) else {
                XCTFail("Failed to unpack: \(cq)")
                continue
            }
            // Unpacked uses underscore: "CQ_DX"
            let expected = cq.replacingOccurrences(of: "CQ ", with: "CQ_")
            XCTAssertEqual(unpacked, expected, "Round-trip failed for \(cq)")
        }
    }

    func testPack28RangeValidation() {
        // Packed callsign should be in range [NTOKENS+MAX22, 2^28)
        guard let n28 = FT8Codec.pack28("K1ABC") else {
            XCTFail("Failed to pack K1ABC")
            return
        }
        XCTAssertGreaterThanOrEqual(n28, FT8Codec.NTOKENS + FT8Codec.MAX22)
        XCTAssertLessThan(n28, 1 << 28)
    }

    func testPack28InvalidCallsigns() {
        // These should fail or produce hash codes
        XCTAssertNil(FT8Codec.pack28(""))
        XCTAssertNil(FT8Codec.pack28("A"))  // Too short
        XCTAssertNil(FT8Codec.pack28("1234567"))  // Too long, no letters
    }

    func testPack28K1ABCValue() {
        // From call_to_c28.f90: K1ABC encodes to a specific value
        // callsign = " K1ABC" -> i1=index(' 0123..','K')-1=21
        // i2=index('0123..','1')-1=1, i3=index('0123..','A')-1=0 wait, a3 is just digits
        // Let me compute: i3=index('0123456789','A') -> invalid
        // Actually K1ABC: right-padded to 6 chars = " K1ABC" (iarea=2, so pad with space)
        // Wait: K has iarea at position 1 (digit '1' at index 1), so iarea=1 (0-indexed: iarea=1)
        // normalizeCallsign pads: [' ', 'K', '1', 'A', 'B', 'C']
        // a1[' '] -> 0, a2['K'] -> 20, a3['1'] -> 1, a4['A'] -> 1, a4['B'] -> 2, a4['C'] -> 3
        // n28 = 36*10*27*27*27*0 + 10*27*27*27*20 + 27*27*27*1 + 27*27*1 + 27*2 + 3 + NTOKENS + MAX22
        //     = 0 + 3936600 + 19683 + 729 + 54 + 3 + 2063592 + 4194304
        //     = 10214965
        guard let n28 = FT8Codec.pack28("K1ABC") else {
            XCTFail("Failed to pack K1ABC")
            return
        }
        // 10*27*27*27*20 + 27*27*27 + 27*27 + 27*2 + 3 = 3957069
        let callPart: UInt32 = 3_957_069
        let expected: UInt32 = callPart + FT8Codec.NTOKENS + FT8Codec.MAX22
        XCTAssertEqual(n28, expected)
    }

    // MARK: - Grid Locator

    func testPackUnpackGrid4() {
        let grids = ["FN42", "EN37", "IO91", "JO22", "AA00", "RR99"]
        for grid in grids {
            let packed = FT8Codec.packGrid4(grid)
            guard let unpacked = FT8Codec.unpackGrid4(packed) else {
                XCTFail("Failed to unpack grid: \(grid)")
                continue
            }
            XCTAssertEqual(unpacked, grid, "Grid round-trip failed for \(grid)")
        }
    }

    func testPackGrid4FN42() {
        // FN42: F=5, N=13, 4=4, 2=2
        // 5*18*10*10 + 13*10*10 + 4*10 + 2 = 9000 + 1300 + 40 + 2 = 10342
        let packed = FT8Codec.packGrid4("FN42")
        XCTAssertEqual(packed, 10342)
    }

    func testPackGrid4Range() {
        // All valid grids should produce values 0..<32400
        let packed = FT8Codec.packGrid4("AA00")
        XCTAssertEqual(packed, 0)

        let packedMax = FT8Codec.packGrid4("RR99")
        // 17*18*10*10 + 17*10*10 + 9*10 + 9 = 32399
        let expectedMax: UInt32 = 32399
        XCTAssertEqual(packedMax, expectedMax)
        XCTAssertLessThan(packedMax, FT8Codec.MAXGRID4)
    }

    // MARK: - CRC-14

    func testCRC14KnownValue() {
        // Test that CRC-14 produces a non-zero value for non-zero input
        let messageBits = [UInt8](repeating: 0, count: 77)
        let crc = FT8Codec.crc14(messageBits: messageBits)
        // All-zero message should produce zero CRC (augmented CRC property)
        XCTAssertEqual(crc, 0)
    }

    func testCRC14NonZeroMessage() {
        var messageBits = [UInt8](repeating: 0, count: 77)
        messageBits[0] = 1
        let crc = FT8Codec.crc14(messageBits: messageBits)
        XCTAssertNotEqual(crc, 0, "CRC should be non-zero for non-zero message")
    }

    func testCRC14Verify() {
        // Pack a message, compute CRC, verify it
        guard let bits = FT8Codec.pack77(message: "CQ K1ABC FN42") else {
            XCTFail("Failed to pack message")
            return
        }

        let crc = FT8Codec.crc14(messageBits: bits)

        // Build 91-bit message: 77 data + 14 CRC
        var bits91 = [UInt8](repeating: 0, count: 91)
        for i in 0..<77 { bits91[i] = bits[i] }
        for i in 0..<14 {
            bits91[77 + i] = UInt8((crc >> (13 - i)) & 1)
        }

        XCTAssertTrue(FT8Codec.verifyCRC14(bits91), "CRC verification should pass")

        // Flip a bit and verify CRC fails
        var corruptBits = bits91
        corruptBits[5] ^= 1
        XCTAssertFalse(FT8Codec.verifyCRC14(corruptBits), "CRC verification should fail for corrupted message")
    }

    func testCRC14MultipleMessages() {
        // Different messages should produce different CRCs
        let messages = ["CQ K1ABC FN42", "CQ W9XYZ EN37", "K1ABC W9XYZ -11"]
        var crcs = Set<UInt16>()
        for msg in messages {
            guard let bits = FT8Codec.pack77(message: msg) else {
                XCTFail("Failed to pack: \(msg)")
                continue
            }
            crcs.insert(FT8Codec.crc14(messageBits: bits))
        }
        XCTAssertEqual(crcs.count, messages.count, "Different messages should produce different CRCs")
    }

    // MARK: - Type 1 Standard Messages

    func testPackUnpackCQWithGrid() {
        guard let bits = FT8Codec.pack77(message: "CQ K1ABC FN42") else {
            XCTFail("Failed to pack CQ K1ABC FN42")
            return
        }
        XCTAssertEqual(bits.count, 77)

        // Verify i3 = 1
        let i3 = Int(FT8Codec.readBits(bits, offset: 74, width: 3))
        XCTAssertEqual(i3, 1, "CQ message should be Type 1")

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack CQ K1ABC FN42")
            return
        }
        XCTAssertEqual(msg.displayText, "CQ K1ABC FN42")

        if case .cq(let modifier, let caller, let grid) = msg.type {
            XCTAssertNil(modifier)
            XCTAssertEqual(caller, "K1ABC")
            XCTAssertEqual(grid, "FN42")
        } else {
            XCTFail("Expected CQ message type, got \(msg.type)")
        }
    }

    func testPackUnpackCQDirectedWithGrid() {
        guard let bits = FT8Codec.pack77(message: "CQ TEST K1ABC FN42") else {
            XCTFail("Failed to pack CQ TEST K1ABC FN42")
            return
        }

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack")
            return
        }

        XCTAssertEqual(msg.displayText, "CQ TEST K1ABC FN42")

        if case .cq(let modifier, let caller, let grid) = msg.type {
            XCTAssertEqual(modifier, "TEST")
            XCTAssertEqual(caller, "K1ABC")
            XCTAssertEqual(grid, "FN42")
        } else {
            XCTFail("Expected CQ message type")
        }
    }

    func testPackUnpackCQFDWithGrid() {
        guard let bits = FT8Codec.pack77(message: "CQ FD K1ABC FN42") else {
            XCTFail("Failed to pack CQ FD K1ABC FN42")
            return
        }

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack")
            return
        }

        XCTAssertEqual(msg.displayText, "CQ FD K1ABC FN42")
    }

    func testPackUnpackStandardWithGrid() {
        guard let bits = FT8Codec.pack77(message: "K1ABC W9XYZ EN37") else {
            XCTFail("Failed to pack K1ABC W9XYZ EN37")
            return
        }

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack K1ABC W9XYZ EN37")
            return
        }
        XCTAssertEqual(msg.displayText, "K1ABC W9XYZ EN37")

        if case .standard(let call1, let call2, let grid, let report) = msg.type {
            XCTAssertEqual(call1, "K1ABC")
            XCTAssertEqual(call2, "W9XYZ")
            XCTAssertEqual(grid, "EN37")
            XCTAssertNil(report)
        } else {
            XCTFail("Expected standard message type")
        }
    }

    func testPackUnpackStandardWithReport() {
        guard let bits = FT8Codec.pack77(message: "W9XYZ K1ABC -11") else {
            XCTFail("Failed to pack W9XYZ K1ABC -11")
            return
        }

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack W9XYZ K1ABC -11")
            return
        }
        XCTAssertEqual(msg.displayText, "W9XYZ K1ABC -11")

        if case .standard(let call1, let call2, let grid, let report) = msg.type {
            XCTAssertEqual(call1, "W9XYZ")
            XCTAssertEqual(call2, "K1ABC")
            XCTAssertNil(grid)
            XCTAssertEqual(report, -11)
        } else {
            XCTFail("Expected standard message type")
        }
    }

    func testPackUnpackStandardWithRReport() {
        guard let bits = FT8Codec.pack77(message: "K1ABC W9XYZ R-09") else {
            XCTFail("Failed to pack K1ABC W9XYZ R-09")
            return
        }

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack K1ABC W9XYZ R-09")
            return
        }
        XCTAssertEqual(msg.displayText, "K1ABC W9XYZ R-09")

        if case .standard(let call1, let call2, let grid, let report) = msg.type {
            XCTAssertEqual(call1, "K1ABC")
            XCTAssertEqual(call2, "W9XYZ")
            XCTAssertNil(grid)
            XCTAssertEqual(report, -9)
        } else {
            XCTFail("Expected standard message type")
        }
    }

    func testPackUnpackRRR() {
        guard let bits = FT8Codec.pack77(message: "W9XYZ K1ABC RRR") else {
            XCTFail("Failed to pack W9XYZ K1ABC RRR")
            return
        }

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack W9XYZ K1ABC RRR")
            return
        }
        XCTAssertEqual(msg.displayText, "W9XYZ K1ABC RRR")

        if case .standardAck(let call1, let call2, let ack) = msg.type {
            XCTAssertEqual(call1, "W9XYZ")
            XCTAssertEqual(call2, "K1ABC")
            XCTAssertEqual(ack, "RRR")
        } else {
            XCTFail("Expected standardAck message type")
        }
    }

    func testPackUnpackRR73() {
        guard let bits = FT8Codec.pack77(message: "K1ABC W9XYZ RR73") else {
            XCTFail("Failed to pack K1ABC W9XYZ RR73")
            return
        }

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack K1ABC W9XYZ RR73")
            return
        }
        XCTAssertEqual(msg.displayText, "K1ABC W9XYZ RR73")

        if case .standardAck(_, _, let ack) = msg.type {
            XCTAssertEqual(ack, "RR73")
        } else {
            XCTFail("Expected standardAck message type")
        }
    }

    func testPackUnpack73() {
        guard let bits = FT8Codec.pack77(message: "K1ABC W9XYZ 73") else {
            XCTFail("Failed to pack K1ABC W9XYZ 73")
            return
        }

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack K1ABC W9XYZ 73")
            return
        }
        XCTAssertEqual(msg.displayText, "K1ABC W9XYZ 73")

        if case .standardAck(_, _, let ack) = msg.type {
            XCTAssertEqual(ack, "73")
        } else {
            XCTFail("Expected standardAck message type")
        }
    }

    func testPackUnpackStandardWithPositiveReport() {
        guard let bits = FT8Codec.pack77(message: "K1ABC W9XYZ +03") else {
            XCTFail("Failed to pack K1ABC W9XYZ +03")
            return
        }

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack")
            return
        }
        XCTAssertEqual(msg.displayText, "K1ABC W9XYZ +03")

        if case .standard(_, _, _, let report) = msg.type {
            XCTAssertEqual(report, 3)
        } else {
            XCTFail("Expected standard message type")
        }
    }

    func testPackUnpackStandardWithRPositiveReport() {
        guard let bits = FT8Codec.pack77(message: "K1ABC W9XYZ R+03") else {
            XCTFail("Failed to pack")
            return
        }

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack")
            return
        }
        XCTAssertEqual(msg.displayText, "K1ABC W9XYZ R+03")
    }

    func testPackUnpackWithRoverSuffix() {
        guard let bits = FT8Codec.pack77(message: "K1ABC/R W9XYZ EN37") else {
            XCTFail("Failed to pack K1ABC/R W9XYZ EN37")
            return
        }

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack K1ABC/R W9XYZ EN37")
            return
        }
        XCTAssertEqual(msg.displayText, "K1ABC/R W9XYZ EN37")
    }

    func testPackUnpackWithRGrid() {
        // "W9XYZ K1ABC/R R FN42" — rover with R (roger) grid
        guard let bits = FT8Codec.pack77(message: "W9XYZ K1ABC/R R FN42") else {
            XCTFail("Failed to pack W9XYZ K1ABC/R R FN42")
            return
        }

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack")
            return
        }
        XCTAssertEqual(msg.displayText, "W9XYZ K1ABC/R R FN42")
    }

    // MARK: - Free Text

    func testPackUnpackFreeText() {
        guard let bits = FT8Codec.pack77(message: "TNX BOB 73 GL") else {
            XCTFail("Failed to pack free text")
            return
        }
        XCTAssertEqual(bits.count, 77)

        // Verify i3=0, n3=0
        let i3 = Int(FT8Codec.readBits(bits, offset: 74, width: 3))
        let n3 = Int(FT8Codec.readBits(bits, offset: 71, width: 3))
        XCTAssertEqual(i3, 0)
        XCTAssertEqual(n3, 0)

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack free text")
            return
        }

        if case .freeText(let text) = msg.type {
            XCTAssertEqual(text, "TNX BOB 73 GL")
        } else {
            XCTFail("Expected free text message type, got \(msg.type)")
        }
    }

    func testPackUnpackFreeTextShort() {
        guard let bits = FT8Codec.pack77(message: "HI") else {
            XCTFail("Failed to pack short free text")
            return
        }

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack")
            return
        }

        if case .freeText(let text) = msg.type {
            XCTAssertEqual(text, "HI")
        } else {
            XCTFail("Expected free text type")
        }
    }

    func testFreeTextAlphabet() {
        // Verify all 42 characters in the alphabet
        XCTAssertEqual(FT8Codec.freeTextAlphabet.count, 42)
        XCTAssertEqual(FT8Codec.freeTextAlphabet[0], " ")
        XCTAssertEqual(FT8Codec.freeTextAlphabet[1], "0")
        XCTAssertEqual(FT8Codec.freeTextAlphabet[10], "9")
        XCTAssertEqual(FT8Codec.freeTextAlphabet[11], "A")
        XCTAssertEqual(FT8Codec.freeTextAlphabet[36], "Z")
        XCTAssertEqual(FT8Codec.freeTextAlphabet[37], "+")
        XCTAssertEqual(FT8Codec.freeTextAlphabet[38], "-")
        XCTAssertEqual(FT8Codec.freeTextAlphabet[39], ".")
        XCTAssertEqual(FT8Codec.freeTextAlphabet[40], "/")
        XCTAssertEqual(FT8Codec.freeTextAlphabet[41], "?")
    }

    func testFreeTextMaxLength() {
        // 13-character message with non-hex chars to avoid telemetry detection
        guard let bits = FT8Codec.pack77(message: "HELLO WORLD  ") else {
            XCTFail("Failed to pack 13-char message")
            return
        }

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack")
            return
        }

        if case .freeText(let text) = msg.type {
            XCTAssertEqual(text, "HELLO WORLD")
        } else {
            XCTFail("Expected free text type")
        }
    }

    func testFreeTextWithSpecialChars() {
        guard let bits = FT8Codec.pack77(message: "TEST+1-2.3/4?") else {
            XCTFail("Failed to pack")
            return
        }

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack")
            return
        }

        if case .freeText(let text) = msg.type {
            XCTAssertEqual(text, "TEST+1-2.3/4?")
        } else {
            XCTFail("Expected free text type")
        }
    }

    // MARK: - Telemetry

    func testPackUnpackTelemetry() {
        guard let bits = FT8Codec.pack77(message: "123456789ABCDEF012") else {
            XCTFail("Failed to pack telemetry")
            return
        }
        XCTAssertEqual(bits.count, 77)

        // Verify i3=0, n3=5
        let i3 = Int(FT8Codec.readBits(bits, offset: 74, width: 3))
        let n3 = Int(FT8Codec.readBits(bits, offset: 71, width: 3))
        XCTAssertEqual(i3, 0)
        XCTAssertEqual(n3, 5)

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack telemetry")
            return
        }

        if case .telemetry(let hex1, let hex2, let hex3) = msg.type {
            XCTAssertEqual(hex1, 0x123456)
            XCTAssertEqual(hex2, 0x789ABC)
            XCTAssertEqual(hex3, 0xDEF012)
        } else {
            XCTFail("Expected telemetry type, got \(msg.type)")
        }
    }

    func testPackUnpackTelemetryShort() {
        // Short telemetry value
        guard let bits = FT8Codec.pack77(message: "1A2B") else {
            XCTFail("Failed to pack short telemetry")
            return
        }

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack")
            return
        }

        if case .telemetry(let hex1, let hex2, let hex3) = msg.type {
            // "1A2B" pads to "000000000000001A2B" -> 000000, 000000, 001A2B
            XCTAssertEqual(hex1, 0)
            XCTAssertEqual(hex2, 0)
            XCTAssertEqual(hex3, 0x001A2B)
        } else {
            XCTFail("Expected telemetry type")
        }
    }

    func testTelemetryMaxValue() {
        // First hex value must be < 2^23 (max is 0x7FFFFF)
        // 22 chars > 18 chars, should fail telemetry packing and fall through to free text
        let result = FT8Codec.pack77(message: "7FFFFFFFFFFFFFFFFFFFFF")
        // This is too long for telemetry but will be packed as free text (truncated to 13 chars)
        XCTAssertNotNil(result)

        // Valid max telemetry: 7FFFFF followed by FFFFFF FFFFFF
        guard let bits = FT8Codec.pack77(message: "7FFFFFFFFFFFFFFFFFFFF") else {
            // 21 chars > 18, also too long
            return
        }
        _ = bits

        // Exactly 18 hex digits with first 6 digits < 0x800000
        guard let validBits = FT8Codec.pack77(message: "7FFFFF123456789ABC") else {
            XCTFail("Should pack valid telemetry")
            return
        }
        let i3 = Int(FT8Codec.readBits(validBits, offset: 74, width: 3))
        let n3 = Int(FT8Codec.readBits(validBits, offset: 71, width: 3))
        XCTAssertEqual(i3, 0)
        XCTAssertEqual(n3, 5)
    }

    // MARK: - Round-Trip Tests (Full QSO Sequence)

    func testStandardQSORoundTrip() {
        // Standard FT8 QSO exchange
        let messages = [
            "CQ K1ABC FN42",
            "K1ABC W9XYZ EN37",
            "W9XYZ K1ABC -11",
            "K1ABC W9XYZ R-09",
            "W9XYZ K1ABC RRR",
            "K1ABC W9XYZ 73",
        ]

        for msg in messages {
            guard let bits = FT8Codec.pack77(message: msg) else {
                XCTFail("Failed to pack: \(msg)")
                continue
            }
            guard let decoded = FT8Codec.unpack77(bits: bits) else {
                XCTFail("Failed to unpack: \(msg)")
                continue
            }
            XCTAssertEqual(decoded.displayText, msg, "Round-trip failed for: \(msg)")
        }
    }

    func testShortCycleQSORoundTrip() {
        let messages = [
            "CQ K1ABC FN42",
            "K1ABC W9XYZ -09",
            "W9XYZ K1ABC R-11",
            "K1ABC W9XYZ RR73",
            "W9XYZ K1ABC 73",
        ]

        for msg in messages {
            guard let bits = FT8Codec.pack77(message: msg) else {
                XCTFail("Failed to pack: \(msg)")
                continue
            }
            guard let decoded = FT8Codec.unpack77(bits: bits) else {
                XCTFail("Failed to unpack: \(msg)")
                continue
            }
            XCTAssertEqual(decoded.displayText, msg, "Round-trip failed for: \(msg)")
        }
    }

    // MARK: - Callsign Normalization

    func testNormalizeCallsign() {
        // 1-char prefix: K1ABC -> " K1ABC"
        let k1abc = FT8Codec.normalizeCallsign("K1ABC")
        XCTAssertEqual(k1abc, [" ", "K", "1", "A", "B", "C"])

        // 2-char prefix: KA1ABC -> "KA1ABC"
        let ka1abc = FT8Codec.normalizeCallsign("KA1ABC")
        XCTAssertEqual(ka1abc, ["K", "A", "1", "A", "B", "C"])

        // Short suffix: W1AW -> " W1AW "
        let w1aw = FT8Codec.normalizeCallsign("W1AW")
        XCTAssertEqual(w1aw, [" ", "W", "1", "A", "W", " "])

        // 2-char prefix, 2-letter suffix: G4ABC -> error, G4 has digit at position 1
        // Actually G4ABC: prefix "G", digit "4", suffix "ABC" -> iarea=1
        let g4abc = FT8Codec.normalizeCallsign("G4ABC")
        XCTAssertEqual(g4abc, [" ", "G", "4", "A", "B", "C"])
    }

    func testNormalizeInvalidCallsigns() {
        // No letters before digit
        XCTAssertNil(FT8Codec.normalizeCallsign("1ABC"))
        // Wait, "1ABC" actually has the digit at position 0, but we need at least one letter before it
        // Actually iarea is the LAST digit, so for "1ABC", the last digit is '1' at index 0 -> iarea=0 -> invalid (< 1)

        // No digit at all
        XCTAssertNil(FT8Codec.normalizeCallsign("ABCDE"))

        // Too many suffix chars
        XCTAssertNil(FT8Codec.normalizeCallsign("K1ABCD"))  // 4 suffix chars
    }

    // MARK: - Report Range Tests

    func testReportRange() {
        // Reports from -30 to +30 should round-trip
        for report in stride(from: -30, through: 30, by: 1) {
            let sign = report >= 0 ? "+" : "-"
            let msg = "K1ABC W9XYZ \(sign)\(String(format: "%02d", abs(report)))"

            guard let bits = FT8Codec.pack77(message: msg) else {
                XCTFail("Failed to pack report \(report)")
                continue
            }
            guard let decoded = FT8Codec.unpack77(bits: bits) else {
                XCTFail("Failed to unpack report \(report)")
                continue
            }

            if case .standard(_, _, _, let decodedReport) = decoded.type {
                XCTAssertEqual(decodedReport, report, "Report round-trip failed for \(report)")
            } else {
                XCTFail("Expected standard type for report \(report)")
            }
        }
    }

    // MARK: - Bit Manipulation Tests

    func testWriteReadBits() {
        var bits = [UInt8](repeating: 0, count: 32)

        // Write 28-bit value
        FT8Codec.writeBits(&bits, offset: 0, value: 0x0ABCDEF0, width: 28)
        let read = FT8Codec.readBits(bits, offset: 0, width: 28)
        XCTAssertEqual(read, 0x0ABCDEF0)

        // Write 15-bit value
        FT8Codec.writeBits(&bits, offset: 0, value: 0x7FFF, width: 15)
        let read15 = FT8Codec.readBits(bits, offset: 0, width: 15)
        XCTAssertEqual(read15, 0x7FFF)

        // Write 3-bit value
        FT8Codec.writeBits(&bits, offset: 0, value: 5, width: 3)
        let read3 = FT8Codec.readBits(bits, offset: 0, width: 3)
        XCTAssertEqual(read3, 5)
    }

    // MARK: - 128-bit Arithmetic Tests

    func testMultiply128() {
        // Simple test: 100 * 42 = 4200
        let a = FT8Codec.UInt128(high: 0, low: 100)
        let result = FT8Codec.multiply128(a, by: 42)
        XCTAssertEqual(result.high, 0)
        XCTAssertEqual(result.low, 4200)
    }

    func testDivmod128() {
        // 4200 / 42 = 100 remainder 0
        let a = FT8Codec.UInt128(high: 0, low: 4200)
        let (q, r) = FT8Codec.divmod128(a, by: 42)
        XCTAssertEqual(q.high, 0)
        XCTAssertEqual(q.low, 100)
        XCTAssertEqual(r, 0)
    }

    func testMultiplyDivmodRoundTrip() {
        // (a * 42 + 15) / 42 should give (a, 15)
        let a = FT8Codec.UInt128(high: 0, low: 12345)
        let product = FT8Codec.multiply128(a, by: 42)
        let withRemainder = FT8Codec.add128(product, FT8Codec.UInt128(high: 0, low: 15))
        let (q, r) = FT8Codec.divmod128(withRemainder, by: 42)
        XCTAssertEqual(q.low, 12345)
        XCTAssertEqual(q.high, 0)
        XCTAssertEqual(r, 15)
    }

    func testLargeMultiply128() {
        // Test overflow into high bits
        let a = FT8Codec.UInt128(high: 0, low: UInt64.max)
        let result = FT8Codec.multiply128(a, by: 2)
        XCTAssertEqual(result.high, 1)
        XCTAssertEqual(result.low, UInt64.max - 1)
    }

    // MARK: - Edge Cases

    func testUnpack77TooShort() {
        let bits = [UInt8](repeating: 0, count: 50)
        XCTAssertNil(FT8Codec.unpack77(bits: bits))
    }

    func testPackEmptyMessage() {
        XCTAssertNil(FT8Codec.pack77(message: ""))
    }

    func testPackUnpackVariousCallsigns() {
        let testCases = [
            "CQ W1AW FN31",
            // Note: N0CALL is non-standard (4-letter suffix), not tested here
            "CQ KH7Z BL01",
            "CQ G4ABC IO91",
            "CQ PA9XYZ JO22",
        ]

        for msg in testCases {
            guard let bits = FT8Codec.pack77(message: msg) else {
                XCTFail("Failed to pack: \(msg)")
                continue
            }
            guard let decoded = FT8Codec.unpack77(bits: bits) else {
                XCTFail("Failed to unpack: \(msg)")
                continue
            }
            XCTAssertEqual(decoded.displayText, msg, "Round-trip failed for: \(msg)")
        }
    }

    func testPackUnpackCaseInsensitive() {
        // Input should be normalized to uppercase
        guard let bits = FT8Codec.pack77(message: "cq k1abc fn42") else {
            XCTFail("Failed to pack lowercase message")
            return
        }

        guard let msg = FT8Codec.unpack77(bits: bits) else {
            XCTFail("Failed to unpack")
            return
        }
        XCTAssertEqual(msg.displayText, "CQ K1ABC FN42")
    }
}
