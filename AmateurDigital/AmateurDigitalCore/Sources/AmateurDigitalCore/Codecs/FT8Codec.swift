//
//  FT8Codec.swift
//  AmateurDigitalCore
//
//  FT8 77-bit message packing/unpacking and CRC-14 computation.
//  Implements the WSJT-X 2.0+ protocol from packjt77.f90.
//
//  Supports:
//    - Type 1 (i3=1): Standard messages — CALL1 CALL2 GRID/REPORT
//    - Type 0.0 (i3=0,n3=0): Free text — 13 chars from 42-char alphabet
//    - Type 0.5 (i3=0,n3=5): Telemetry — 71-bit hex payload
//    - CRC-14 computation (polynomial 0x2757)
//

import Foundation

// MARK: - Message Types

/// Structured representation of a decoded FT8 message.
public enum FT8MessageType: Equatable {
    /// Standard message: two callsigns plus grid or report.
    /// call1/call2 may have /R suffix for rover. report is nil for grid-only messages.
    case standard(call1: String, call2: String, grid: String?, report: Int?)

    /// Shorthand responses: RRR, RR73, 73 (no grid or report)
    case standardAck(call1: String, call2: String, ack: String)

    /// CQ call with optional directed CQ (e.g., "CQ DX", "CQ 100") and grid
    case cq(modifier: String?, caller: String, grid: String?)

    /// Free text: up to 13 characters from the 42-char FT8 alphabet
    case freeText(String)

    /// Telemetry: 71 bits packed as three hex values (23+24+24 bits)
    case telemetry(hex1: UInt32, hex2: UInt32, hex3: UInt32)
}

/// A decoded FT8 message with the original 77-bit payload.
public struct FT8Message: Equatable {
    public let type: FT8MessageType
    public let raw77: [UInt8]
    public let displayText: String

    public init(type: FT8MessageType, raw77: [UInt8], displayText: String) {
        self.type = type
        self.raw77 = raw77
        self.displayText = displayText
    }
}

// MARK: - FT8Codec

public struct FT8Codec {

    // MARK: - Constants

    /// Number of special token values (DE=0, QRZ=1, CQ=2, CQ nnn, CQ xxxx)
    static let NTOKENS: UInt32 = 2_063_592

    /// 22-bit hash space for non-standard callsigns
    static let MAX22: UInt32 = 4_194_304

    /// Maximum grid4 value (18*18*10*10 = 32400)
    static let MAXGRID4: UInt32 = 32400

    /// 42-character FT8 free-text alphabet
    public static let freeTextAlphabet = " 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ+-./?".map { $0 }

    /// 37-character alphabet for callsign position 1 (space + alphanumeric)
    private static let a1 = Array(" 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// 36-character alphabet for callsign position 2 (alphanumeric, no space)
    private static let a2 = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    /// 10-character alphabet for callsign position 3 (digits only)
    private static let a3 = Array("0123456789")

    /// 27-character alphabet for callsign positions 4-6 (space + letters)
    private static let a4 = Array(" ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    // MARK: - CRC-14

    /// Compute CRC-14 as used by FT8 (WSJT-X).
    /// Polynomial 0x2757 (bit-level: 1 1001 1101 0101 11 = x^14 + x^13 + x^10 + x^9 + x^8 + x^6 + x^4 + x^2 + x + 1).
    /// Operates on the 77 message bits packed into 12 bytes (bits 78-96 zeroed for CRC computation).
    ///
    /// Input: array of 77 bit values (each 0 or 1).
    /// Returns: 14-bit CRC value.
    public static func crc14(messageBits: [UInt8]) -> UInt16 {
        // Pack 77 bits into 12 bytes, MSB first, remaining bits zeroed
        var bytes = bitsToBytes(messageBits, bitCount: 77, byteCount: 12)
        // Zero bits 78-96 (already zero from bitsToBytes padding)
        // Byte 9 has bits 72-79: mask top 5 bits, zero bottom 3
        bytes[9] = bytes[9] & 0xF8  // Keep bits 72-76, zero 77-79
        // Actually: bit 77 is the last message bit. Bits 78-79 in byte 9 should be 0.
        // bytes[10] and bytes[11] should be 0 (for the 14-bit CRC space)
        bytes[10] = 0
        bytes[11] = 0

        return augmentedCRC14(bytes)
    }

    /// Verify CRC-14 embedded in 91 decoded bits (77 message + 14 CRC).
    public static func verifyCRC14(_ bits91: [UInt8]) -> Bool {
        guard bits91.count >= 91 else { return false }

        let messageBits = Array(bits91[0..<77])
        let expectedCRC = crc14(messageBits: messageBits)

        // Extract received CRC from bits 77-90
        var receivedCRC: UInt16 = 0
        for i in 0..<14 {
            receivedCRC = (receivedCRC << 1) | UInt16(bits91[77 + i])
        }

        return receivedCRC == expectedCRC
    }

    /// Augmented CRC-14 computation on byte array (matching boost::augmented_crc<14, 0x2757>).
    /// The polynomial is 0x2757. The CRC register is 14 bits wide.
    private static func augmentedCRC14(_ data: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0

        for byte in data {
            crc ^= UInt16(byte) << 6  // Shift byte into top of 14-bit register
            for _ in 0..<8 {
                if crc & 0x2000 != 0 {  // Check bit 13 (MSB of 14-bit register)
                    crc = (crc << 1) ^ 0x2757
                } else {
                    crc = crc << 1
                }
                crc &= 0x3FFF  // Keep only 14 bits
            }
        }

        return crc & 0x3FFF
    }

    // MARK: - Pack (Encode)

    /// Pack a message string into 77 bits.
    /// Returns nil if the message cannot be packed.
    /// Supports: standard messages, CQ, free text.
    public static func pack77(message: String) -> [UInt8]? {
        let msg = message.uppercased().trimmingCharacters(in: .whitespaces)
        let words = splitMessage(msg)

        if words.isEmpty { return nil }

        // Try Type 0.5 (Telemetry)
        if let bits = packTelemetry(msg) { return bits }

        // Try Type 1 (Standard message) — includes CQ
        if let bits = packType1(words: words) { return bits }

        // Default to Type 0.0 (Free text)
        return packFreeText(msg)
    }

    /// Pack a Type 1 standard message.
    /// Format: n28a(28) + ipa(1) + n28b(28) + ipb(1) + ir(1) + igrid4(15) + i3(3) = 77
    private static func packType1(words: [String]) -> [UInt8]? {
        guard words.count >= 2 && words.count <= 4 else { return nil }

        // Parse call1 and call2
        let (bcall1, hasR1, hasP1) = parseCallWithSuffix(words[0])
        let (bcall2, hasR2, hasP2) = parseCallWithSuffix(words[1])

        // Validate: at least call2 must be a valid callsign
        // call1 can be CQ, DE, QRZ, or a callsign
        let isCQ = words[0].hasPrefix("CQ")
        let isDE = words[0] == "DE"
        let isQRZ = words[0] == "QRZ"

        guard let n28a = pack28(isCQ ? words[0] : bcall1) else { return nil }
        guard let n28b = pack28(bcall2) else { return nil }

        // Don't pack special tokens as call2
        if !isCQ && !isDE && !isQRZ {
            guard n28a >= NTOKENS + MAX22 || n28a < NTOKENS else { return nil }
        }
        guard n28b >= NTOKENS + MAX22 else { return nil }

        let ipa: UInt8 = (hasR1 || hasP1) ? 1 : 0
        let ipb: UInt8 = (hasR2 || hasP2) ? 1 : 0
        let i3: UInt8 = (hasP1 || hasP2) ? 2 : 1

        var ir: UInt8 = 0
        var igrid4: UInt32 = 0

        if words.count == 2 {
            // Two-word message: CALL1 CALL2 (no grid/report)
            ir = 0
            igrid4 = MAXGRID4 + 1  // "blank" report
        } else {
            // Parse the last word for grid, report, or ack
            let lastWord = words.last!

            // Check for "R" prefix on second-to-last word
            if words.count == 4 && words[2] == "R" {
                ir = 1
            }

            // Check special acknowledgements first (before grid, since RR73 looks like a grid)
            if lastWord == "RRR" {
                ir = 0
                igrid4 = MAXGRID4 + 2
            } else if lastWord == "RR73" {
                ir = 0
                igrid4 = MAXGRID4 + 3
            } else if lastWord == "73" {
                ir = 0
                igrid4 = MAXGRID4 + 4
            } else if isGrid4(lastWord) {
                // Grid locator
                if words.count == 4 && words[2] == "R" { ir = 1 }
                igrid4 = packGrid4(lastWord)
            } else if let report = parseReport(lastWord) {
                // Signal report like -11, +03, R-09, R+03
                if lastWord.hasPrefix("R") {
                    ir = 1
                }
                var irpt = report
                if irpt >= -50 && irpt <= -31 { irpt = irpt + 101 }
                igrid4 = MAXGRID4 + UInt32(irpt + 35)
            } else {
                return nil  // Unrecognized last word
            }
        }

        // Build 77 bits: n28a(28) + ipa(1) + n28b(28) + ipb(1) + ir(1) + igrid4(15) + i3(3)
        var bits = [UInt8](repeating: 0, count: 77)
        writeBits(&bits, offset: 0, value: n28a, width: 28)
        bits[28] = ipa
        writeBits(&bits, offset: 29, value: n28b, width: 28)
        bits[57] = ipb
        bits[58] = ir
        writeBits(&bits, offset: 59, value: igrid4, width: 15)
        writeBits(&bits, offset: 74, value: UInt32(i3), width: 3)

        return bits
    }

    /// Pack a free text message (Type 0.0).
    /// 13 characters from 42-char alphabet, packed into 71 bits + 6 bits (n3=0, i3=0).
    public static func packFreeText(_ msg: String) -> [UInt8]? {
        // Right-justify the message in 13 characters (matching Fortran adjustr)
        var text = msg
        if text.count > 13 { text = String(text.prefix(13)) }
        // Right-justify: pad with spaces on the left
        while text.count < 13 { text = " " + text }

        // Encode as base-42 big number using 128-bit arithmetic
        let value = packFreeTextValue(text)

        // Extract 71 bits from the 128-bit value
        var bits71 = [UInt8](repeating: 0, count: 71)
        var remaining = value
        for i in stride(from: 70, through: 0, by: -1) {
            let (q, r) = divmod128(remaining, by: 2)
            bits71[i] = UInt8(r)
            remaining = q
        }

        // Build 77 bits: 71 data + n3(3)=000 + i3(3)=000
        var bits = [UInt8](repeating: 0, count: 77)
        for i in 0..<71 { bits[i] = bits71[i] }
        // bits[71..76] all zero for n3=0, i3=0

        return bits
    }

    /// Pack telemetry (Type 0.5).
    /// 71 bits: 23-bit value + 24-bit value + 24-bit value.
    private static func packTelemetry(_ msg: String) -> [UInt8]? {
        let trimmed = msg.trimmingCharacters(in: .whitespaces)

        // Must be 1-18 hex characters
        guard trimmed.count >= 1 && trimmed.count <= 18 else { return nil }
        guard trimmed.allSatisfy({ $0.isHexDigit }) else { return nil }

        // Pad to 18 hex digits on the left
        let padded = String(repeating: "0", count: 18 - trimmed.count) + trimmed

        // Parse three 6-hex-digit groups
        let hex1Str = String(padded.prefix(6))
        let hex2Str = String(padded.dropFirst(6).prefix(6))
        let hex3Str = String(padded.dropFirst(12).prefix(6))

        guard let h1 = UInt32(hex1Str, radix: 16),
              let h2 = UInt32(hex2Str, radix: 16),
              let h3 = UInt32(hex3Str, radix: 16) else { return nil }

        // First value must fit in 23 bits
        guard h1 < (1 << 23) else { return nil }

        // Build 77 bits: h1(23) + h2(24) + h3(24) + n3(3)=101 + i3(3)=000
        var bits = [UInt8](repeating: 0, count: 77)
        writeBits(&bits, offset: 0, value: h1, width: 23)
        writeBits(&bits, offset: 23, value: h2, width: 24)
        writeBits(&bits, offset: 47, value: h3, width: 24)
        // n3 = 5 = 0b101
        bits[71] = 1
        bits[72] = 0
        bits[73] = 1
        // i3 = 0 = 0b000
        bits[74] = 0
        bits[75] = 0
        bits[76] = 0

        return bits
    }

    // MARK: - Unpack (Decode)

    /// Unpack 77 bits into a structured FT8 message.
    /// Returns nil if the message cannot be decoded.
    public static func unpack77(bits: [UInt8]) -> FT8Message? {
        guard bits.count >= 77 else { return nil }

        // Extract i3 and n3 from bits 74-76 and 71-73
        let i3 = Int(readBits(bits, offset: 74, width: 3))
        let n3 = Int(readBits(bits, offset: 71, width: 3))

        if i3 == 0 && n3 == 0 {
            return unpackFreeText(bits)
        } else if i3 == 0 && n3 == 5 {
            return unpackTelemetry(bits)
        } else if i3 == 1 || i3 == 2 {
            return unpackType1(bits, i3: i3)
        }

        return nil
    }

    /// Unpack a Type 1 or Type 2 standard message.
    private static func unpackType1(_ bits: [UInt8], i3: Int) -> FT8Message? {
        let n28a = readBits(bits, offset: 0, width: 28)
        let ipa = Int(bits[28])
        let n28b = readBits(bits, offset: 29, width: 28)
        let ipb = Int(bits[57])
        let ir = Int(bits[58])
        let igrid4 = readBits(bits, offset: 59, width: 15)

        guard var call1 = unpack28(n28a) else { return nil }
        guard var call2 = unpack28(n28b) else { return nil }

        // Translate CQ_ to CQ
        if call1.hasPrefix("CQ_") {
            call1 = "CQ " + call1.dropFirst(3)
        }

        // Add /R or /P suffix
        let suffix = i3 == 2 ? "/P" : "/R"
        if ipa == 1 && !call1.hasPrefix("CQ") && !call1.hasPrefix("<") {
            call1 = call1 + suffix
        }
        if ipb == 1 && !call2.hasPrefix("<") {
            call2 = call2 + suffix
        }

        let raw77 = Array(bits[0..<77])

        if igrid4 <= MAXGRID4 {
            // Grid locator
            guard let grid4 = unpackGrid4(igrid4) else { return nil }
            let displayGrid = ir == 1 ? "R \(grid4)" : grid4
            let displayText = "\(call1) \(call2) \(displayGrid)"

            // Determine if this is CQ
            if call1.hasPrefix("CQ") {
                let modifier = extractCQModifier(call1)
                let callerCall = call2.trimmingCharacters(in: .whitespaces)
                return FT8Message(
                    type: .cq(modifier: modifier, caller: callerCall, grid: grid4),
                    raw77: raw77,
                    displayText: displayText
                )
            }

            return FT8Message(
                type: .standard(call1: call1, call2: call2, grid: grid4, report: nil),
                raw77: raw77,
                displayText: displayText
            )
        } else {
            // Report, RRR, RR73, 73, or bare message
            let irpt = igrid4 - MAXGRID4

            if irpt == 1 {
                // Bare message (two calls, no grid/report)
                let displayText = "\(call1) \(call2)"
                if call1.hasPrefix("CQ") {
                    let modifier = extractCQModifier(call1)
                    return FT8Message(
                        type: .cq(modifier: modifier, caller: call2, grid: nil),
                        raw77: raw77,
                        displayText: displayText
                    )
                }
                return FT8Message(
                    type: .standard(call1: call1, call2: call2, grid: nil, report: nil),
                    raw77: raw77,
                    displayText: displayText
                )
            } else if irpt == 2 {
                let displayText = "\(call1) \(call2) RRR"
                return FT8Message(
                    type: .standardAck(call1: call1, call2: call2, ack: "RRR"),
                    raw77: raw77,
                    displayText: displayText
                )
            } else if irpt == 3 {
                let displayText = "\(call1) \(call2) RR73"
                return FT8Message(
                    type: .standardAck(call1: call1, call2: call2, ack: "RR73"),
                    raw77: raw77,
                    displayText: displayText
                )
            } else if irpt == 4 {
                let displayText = "\(call1) \(call2) 73"
                return FT8Message(
                    type: .standardAck(call1: call1, call2: call2, ack: "73"),
                    raw77: raw77,
                    displayText: displayText
                )
            } else if irpt >= 5 {
                // Numeric signal report
                var isnr = Int(irpt) - 35
                if isnr > 50 { isnr = isnr - 101 }
                let sign = isnr >= 0 ? "+" : "-"
                let rptStr = "\(sign)\(String(format: "%02d", abs(isnr)))"
                let prefix = ir == 1 ? "R" : ""
                let displayText = "\(call1) \(call2) \(prefix)\(rptStr)"

                return FT8Message(
                    type: .standard(call1: call1, call2: call2, grid: nil, report: isnr),
                    raw77: raw77,
                    displayText: displayText
                )
            }

            return nil
        }
    }

    /// Unpack free text (Type 0.0).
    private static func unpackFreeText(_ bits: [UInt8]) -> FT8Message? {
        // Extract 71-bit value into two parts (high 7 bits + low 64 bits)
        // We need more than 64 bits for the full range: 42^13 ~ 2^71.3
        var highBits: UInt64 = 0
        for i in 0..<7 {
            highBits = (highBits << 1) | UInt64(bits[i])
        }
        var lowBits: UInt64 = 0
        for i in 7..<71 {
            lowBits = (lowBits << 1) | UInt64(bits[i])
        }

        // Reconstruct: value = highBits * 2^64 + lowBits
        // But we need to divide by 42 repeatedly. Use multi-precision.
        var text = unpackFreeTextValue(highBits: highBits, lowBits: lowBits)
        text = String(text.drop(while: { $0 == " " }))  // Left-trim spaces

        if text.isEmpty { return nil }

        let raw77 = Array(bits[0..<77])
        return FT8Message(
            type: .freeText(text),
            raw77: raw77,
            displayText: text
        )
    }

    /// Unpack telemetry (Type 0.5).
    private static func unpackTelemetry(_ bits: [UInt8]) -> FT8Message? {
        let h1 = readBits(bits, offset: 0, width: 23)
        let h2 = readBits(bits, offset: 23, width: 24)
        let h3 = readBits(bits, offset: 47, width: 24)

        let hex1 = String(format: "%06X", h1)
        let hex2 = String(format: "%06X", h2)
        let hex3 = String(format: "%06X", h3)
        var displayText = hex1 + hex2 + hex3
        // Strip leading zeros (but keep at least one digit)
        while displayText.count > 1 && displayText.first == "0" {
            displayText.removeFirst()
        }

        let raw77 = Array(bits[0..<77])
        return FT8Message(
            type: .telemetry(hex1: h1, hex2: h2, hex3: h3),
            raw77: raw77,
            displayText: displayText
        )
    }

    // MARK: - 28-bit Callsign Encoding

    /// Pack a callsign or special token into a 28-bit integer.
    /// Returns nil if the callsign is invalid.
    public static func pack28(_ call: String) -> UInt32? {
        let c = call.uppercased().trimmingCharacters(in: .whitespaces)

        // Special tokens
        if c == "DE" { return 0 }
        if c == "QRZ" { return 1 }
        if c == "CQ" { return 2 }

        // CQ with frequency (CQ nnn) — e.g., CQ 100
        if c.hasPrefix("CQ ") || c.hasPrefix("CQ_") {
            let rest = String(c.dropFirst(3))
            let trimmed = rest.trimmingCharacters(in: .whitespaces)

            // CQ nnn (3-digit number)
            if trimmed.count >= 1 && trimmed.count <= 3 && trimmed.allSatisfy({ $0.isNumber }) {
                if let nqsy = Int(trimmed), nqsy >= 0 && nqsy <= 999 {
                    return UInt32(3 + nqsy)
                }
            }

            // CQ xxxx (1-4 letter directed CQ like CQ DX, CQ TEST, CQ FD)
            if trimmed.count >= 1 && trimmed.count <= 4 && trimmed.allSatisfy({ $0.isLetter }) {
                // Right-justify in 4 characters, encode base-27
                let padded = String(repeating: " ", count: 4 - trimmed.count) + trimmed
                var m: UInt32 = 0
                for ch in padded {
                    let j: UInt32
                    if ch >= "A" && ch <= "Z" {
                        j = UInt32(ch.asciiValue! - Character("A").asciiValue!) + 1
                    } else {
                        j = 0  // space
                    }
                    m = 27 * m + j
                }
                return 3 + 1000 + m
            }
        }

        // Check for standard callsign
        guard let callsign = normalizeCallsign(c) else { return nil }

        guard let i1 = a1.firstIndex(of: callsign[0]),
              let i2 = a2.firstIndex(of: callsign[1]),
              let i3 = a3.firstIndex(of: callsign[2]),
              let i4 = a4.firstIndex(of: callsign[3]),
              let i5 = a4.firstIndex(of: callsign[4]),
              let i6 = a4.firstIndex(of: callsign[5]) else { return nil }

        let idx1 = UInt32(a1.distance(from: a1.startIndex, to: i1))
        let idx2 = UInt32(a2.distance(from: a2.startIndex, to: i2))
        let idx3 = UInt32(a3.distance(from: a3.startIndex, to: i3))
        let idx4 = UInt32(a4.distance(from: a4.startIndex, to: i4))
        let idx5 = UInt32(a4.distance(from: a4.startIndex, to: i5))
        let idx6 = UInt32(a4.distance(from: a4.startIndex, to: i6))

        let n28 = 36*10*27*27*27 * idx1
                 + 10*27*27*27 * idx2
                 + 27*27*27 * idx3
                 + 27*27 * idx4
                 + 27 * idx5
                 + idx6
                 + NTOKENS + MAX22

        return n28 & 0x0FFF_FFFF  // Mask to 28 bits
    }

    /// Unpack a 28-bit integer into a callsign or special token.
    public static func unpack28(_ n28: UInt32) -> String? {
        if n28 < NTOKENS {
            // Special tokens
            if n28 == 0 { return "DE" }
            if n28 == 1 { return "QRZ" }
            if n28 == 2 { return "CQ" }

            if n28 <= 1002 {
                return String(format: "CQ_%03d", n28 - 3)
            }

            if n28 <= 532443 {
                var n = n28 - 1003
                let i1 = n / (27*27*27)
                n -= 27*27*27 * i1
                let i2 = n / (27*27)
                n -= 27*27 * i2
                let i3 = n / 27
                let i4 = n - 27 * i3

                var cq = String(a4[Int(i1)]) + String(a4[Int(i2)]) + String(a4[Int(i3)]) + String(a4[Int(i4)])
                cq = cq.trimmingCharacters(in: .whitespaces)
                return "CQ_" + cq
            }

            // Remaining tokens < NTOKENS are reserved
            return nil
        }

        let remainder = n28 - NTOKENS
        if remainder < MAX22 {
            // 22-bit hash — we can't resolve without a hash table
            return "<...>"
        }

        // Standard callsign
        var n = remainder - MAX22
        let i1 = n / (36*10*27*27*27)
        n -= 36*10*27*27*27 * i1
        let i2 = n / (10*27*27*27)
        n -= 10*27*27*27 * i2
        let i3 = n / (27*27*27)
        n -= 27*27*27 * i3
        let i4 = n / (27*27)
        n -= 27*27 * i4
        let i5 = n / 27
        let i6 = n - 27 * i5

        guard Int(i1) < a1.count, Int(i2) < a2.count, Int(i3) < a3.count,
              Int(i4) < a4.count, Int(i5) < a4.count, Int(i6) < a4.count else {
            return nil
        }

        let callsign = String(a1[Int(i1)]) + String(a2[Int(i2)]) + String(a3[Int(i3)])
                      + String(a4[Int(i4)]) + String(a4[Int(i5)]) + String(a4[Int(i6)])

        let result = callsign.trimmingCharacters(in: .whitespaces)

        // Validate: no embedded spaces
        if result.contains(" ") { return nil }

        return result
    }

    // MARK: - Grid Locator

    /// Pack a 4-character Maidenhead grid locator into a 15-bit integer.
    public static func packGrid4(_ grid: String) -> UInt32 {
        let chars = Array(grid.uppercased())
        guard chars.count == 4 else { return 0 }

        let j1 = UInt32(chars[0].asciiValue! - Character("A").asciiValue!)
        let j2 = UInt32(chars[1].asciiValue! - Character("A").asciiValue!)
        let j3 = UInt32(chars[2].asciiValue! - Character("0").asciiValue!)
        let j4 = UInt32(chars[3].asciiValue! - Character("0").asciiValue!)

        return j1 * 18 * 10 * 10 + j2 * 10 * 10 + j3 * 10 + j4
    }

    /// Unpack a 15-bit integer into a 4-character Maidenhead grid locator.
    public static func unpackGrid4(_ n: UInt32) -> String? {
        var remaining = n

        let j1 = remaining / (18 * 10 * 10)
        guard j1 <= 17 else { return nil }
        remaining -= j1 * 18 * 10 * 10

        let j2 = remaining / (10 * 10)
        guard j2 <= 17 else { return nil }
        remaining -= j2 * 10 * 10

        let j3 = remaining / 10
        guard j3 <= 9 else { return nil }

        let j4 = remaining - j3 * 10
        guard j4 <= 9 else { return nil }

        let c1 = Character(UnicodeScalar(UInt8(j1) + Character("A").asciiValue!))
        let c2 = Character(UnicodeScalar(UInt8(j2) + Character("A").asciiValue!))
        let c3 = Character(UnicodeScalar(UInt8(j3) + Character("0").asciiValue!))
        let c4 = Character(UnicodeScalar(UInt8(j4) + Character("0").asciiValue!))

        return String([c1, c2, c3, c4])
    }

    // MARK: - Free Text Multi-Precision Arithmetic

    /// Pack 13 characters into a 71-bit integer using base-42 encoding.
    /// The text must be right-justified (padded with spaces on the left).
    private static func packFreeTextValue(_ text: String) -> UInt128 {
        let chars = Array(text)
        var result = UInt128(high: 0, low: 0)

        for ch in chars {
            result = multiply128(result, by: 42)
            let idx: UInt64
            if let j = freeTextAlphabet.firstIndex(of: ch) {
                idx = UInt64(freeTextAlphabet.distance(from: freeTextAlphabet.startIndex, to: j))
            } else {
                idx = 0  // Unknown char maps to space
            }
            result = add128(result, UInt128(high: 0, low: idx))
        }

        return result
    }

    /// Unpack a 71-bit integer into 13 characters using base-42 decoding.
    private static func unpackFreeTextValue(highBits: UInt64, lowBits: UInt64) -> String {
        var value = UInt128(high: highBits, low: lowBits)
        var chars = [Character](repeating: " ", count: 13)

        for i in stride(from: 12, through: 0, by: -1) {
            let (quotient, remainder) = divmod128(value, by: 42)
            let idx = Int(remainder)
            if idx < freeTextAlphabet.count {
                chars[i] = freeTextAlphabet[idx]
            } else {
                chars[i] = " "
            }
            value = quotient
        }

        return String(chars)
    }

    // MARK: - Helpers

    /// Split a message into words (whitespace-separated, uppercase).
    /// Merges "CQ XXXX CALL ..." into "CQ_XXXX CALL ..." when word 3 is a valid callsign
    /// (matching WSJT-X split77 behavior).
    private static func splitMessage(_ msg: String) -> [String] {
        var words = msg.split(separator: " ", omittingEmptySubsequences: true).map(String.init)

        // If first word is CQ and there are 3+ words, check if word[2] is a valid callsign.
        // If so, merge word[0] and word[1] into "CQ_modifier" and shift remaining words.
        if words.count >= 3 && words[0] == "CQ" {
            let (baseCall, _, _) = parseCallWithSuffix(words[2])
            if normalizeCallsign(baseCall) != nil {
                words[0] = "CQ_" + words[1]
                words.remove(at: 1)
            }
        }

        return words
    }

    /// Check if a string is a valid 4-character Maidenhead grid locator.
    private static func isGrid4(_ s: String) -> Bool {
        let chars = Array(s.uppercased())
        guard chars.count == 4 else { return false }
        return chars[0] >= "A" && chars[0] <= "R"
            && chars[1] >= "A" && chars[1] <= "R"
            && chars[2] >= "0" && chars[2] <= "9"
            && chars[3] >= "0" && chars[3] <= "9"
    }

    /// Parse a callsign that may have /R or /P suffix.
    /// Returns (base callsign, hasR, hasP).
    private static func parseCallWithSuffix(_ call: String) -> (String, Bool, Bool) {
        if call.hasSuffix("/R") {
            return (String(call.dropLast(2)), true, false)
        }
        if call.hasSuffix("/P") {
            return (String(call.dropLast(2)), false, true)
        }
        return (call, false, false)
    }

    /// Parse a signal report string like "-11", "+03", "R-09", "R+03".
    /// Returns the numeric report value.
    private static func parseReport(_ s: String) -> Int? {
        var str = s
        if str.hasPrefix("R") { str = String(str.dropFirst()) }

        if str.hasPrefix("+") || str.hasPrefix("-") {
            return Int(str)
        }

        return nil
    }

    /// Normalize a callsign to a 6-character right-padded form for encoding.
    /// Standard callsigns have the format: [A-Z0-9][A-Z0-9][0-9][A-Z ][A-Z ][A-Z ]
    /// The area digit is the last digit in the callsign.
    static func normalizeCallsign(_ call: String) -> [Character]? {
        let c = Array(call)
        guard c.count >= 2 && c.count <= 6 else { return nil }

        // Find the call-area digit (last digit in the callsign)
        var iarea = -1
        for i in stride(from: c.count - 1, through: 1, by: -1) {
            if c[i].isNumber {
                iarea = i
                break
            }
        }
        guard iarea >= 1 && iarea <= 2 else { return nil }

        // Validate prefix: at least one letter before the area digit
        var hasLetter = false
        for i in 0..<iarea {
            if c[i].isLetter { hasLetter = true }
        }
        guard hasLetter else { return nil }

        // Validate suffix: only letters after the area digit
        let suffixLen = c.count - iarea - 1
        guard suffixLen >= 1 && suffixLen <= 3 else { return nil }
        for i in (iarea + 1)..<c.count {
            guard c[i].isLetter else { return nil }
        }

        // Right-pad to 6 characters, adjusting so digit is at position 2 (0-indexed)
        var result: [Character]
        if iarea == 1 {
            // One-character prefix: pad with space at front
            result = [" "] + c
        } else {
            // Two-character prefix
            result = c
        }
        while result.count < 6 { result.append(" ") }

        return Array(result.prefix(6))
    }

    /// Extract CQ modifier from a call1 string like "CQ", "CQ DX", "CQ_DX", "CQ_100".
    private static func extractCQModifier(_ call1: String) -> String? {
        if call1 == "CQ" { return nil }
        let rest = call1.dropFirst(3)  // drop "CQ " or "CQ_"
        let trimmed = rest.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Bit Manipulation

    /// Write a value into a bit array at the given offset (MSB first).
    static func writeBits(_ bits: inout [UInt8], offset: Int, value: UInt32, width: Int) {
        for i in 0..<width {
            let bitPos = width - 1 - i
            bits[offset + i] = UInt8((value >> bitPos) & 1)
        }
    }

    /// Read a value from a bit array at the given offset (MSB first).
    static func readBits(_ bits: [UInt8], offset: Int, width: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<width {
            value = (value << 1) | UInt32(bits[offset + i])
        }
        return value
    }

    /// Convert a bit array to bytes (MSB first), with specified output byte count.
    private static func bitsToBytes(_ bits: [UInt8], bitCount: Int, byteCount: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        for i in 0..<bitCount {
            if bits[i] == 1 {
                bytes[i / 8] |= UInt8(1 << (7 - (i % 8)))
            }
        }
        return bytes
    }

    // MARK: - 128-bit Arithmetic (for free-text packing)

    /// Simple 128-bit unsigned integer for free-text base-42 arithmetic.
    struct UInt128: Equatable {
        var high: UInt64
        var low: UInt64
    }

    /// Multiply a 128-bit value by a small integer.
    static func multiply128(_ a: UInt128, by b: UInt64) -> UInt128 {
        // multipliedFullWidth returns (high: UInt64, low: UInt64)
        let fullProduct = a.low.multipliedFullWidth(by: b)
        let highProduct = a.high &* b

        return UInt128(high: highProduct + fullProduct.high, low: fullProduct.low)
    }

    /// Add two 128-bit values.
    static func add128(_ a: UInt128, _ b: UInt128) -> UInt128 {
        let (low, overflow) = a.low.addingReportingOverflow(b.low)
        let high = a.high &+ b.high &+ (overflow ? 1 : 0)
        return UInt128(high: high, low: low)
    }

    /// Divide a 128-bit value by a small integer, returning quotient and remainder.
    static func divmod128(_ a: UInt128, by b: UInt64) -> (UInt128, UInt64) {
        // Division: treat as (high * 2^64 + low) / b
        let (hq, hr) = a.high.quotientAndRemainder(dividingBy: b)
        // Now divide (hr * 2^64 + low) by b
        let combined = (hr, a.low)
        let (lq, lr) = b.dividingFullWidth(combined)
        return (UInt128(high: hq, low: lq), lr)
    }

    /// Right-shift a 128-bit value.
    static func rightShift128(_ a: UInt128, by n: Int) -> UInt128 {
        if n >= 128 { return UInt128(high: 0, low: 0) }
        if n >= 64 {
            return UInt128(high: 0, low: a.high >> (n - 64))
        }
        if n == 0 { return a }
        let high = a.high >> n
        let low = (a.low >> n) | (a.high << (64 - n))
        return UInt128(high: high, low: low)
    }
}

// MARK: - Subscript helper for Character array indexing

private extension Array where Element == Character {
    subscript(safe index: Int) -> Character {
        guard index >= 0 && index < count else { return " " }
        return self[index]
    }
}
