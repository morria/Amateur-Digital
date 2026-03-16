//
//  JS8CallCodec.swift
//  AmateurDigitalCore
//
//  JS8Call message packing/unpacking and CRC-12 computation.
//  Handles the 68-character alphabet, 75-bit payload + 12-bit CRC = 87 info bits.
//

import Foundation

public struct JS8CallCodec {

    /// JS8Call's 68-character alphabet (6 bits per character, 12 chars = 72 bits).
    public static let alphabet = JS8CallConstants.alphabet

    // MARK: - CRC-12

    /// Compute CRC-12 as used by FT8/JS8Call.
    /// Polynomial 0xC06, init 0, no reflect, no final XOR.
    public static func crc12(_ bytes: [UInt8], count: Int) -> UInt16 {
        var crc: UInt16 = 0
        for i in 0..<count {
            crc ^= UInt16(bytes[i]) << 4
            for _ in 0..<8 {
                if crc & 0x800 != 0 {
                    crc = (crc << 1) ^ 0xC06
                } else {
                    crc = crc << 1
                }
                crc &= 0xFFF
            }
        }
        return crc & 0xFFF
    }

    // MARK: - Pack

    /// Pack a message string (up to 12 chars) and 3-bit frame type into 87 information bits.
    /// Returns nil if the message contains characters outside the alphabet.
    public static func pack(message: String, frameType: Int) -> [UInt8] {
        // Pad/truncate to 12 characters
        var msg = message
        while msg.count < 12 { msg.append(" ") }
        if msg.count > 12 { msg = String(msg.prefix(12)) }

        // Map characters to 6-bit values
        var charValues = [Int](repeating: 0, count: 12)
        for (i, ch) in msg.enumerated() {
            if let idx = alphabet.firstIndex(of: ch) {
                charValues[i] = alphabet.distance(from: alphabet.startIndex, to: idx)
            } else {
                // Map unknown chars to 0 ('0' character) - the Fortran does this with exit
                charValues[i] = 0
            }
        }

        // Pack into 75 bits: 72 data + 3 frame type
        var bits = [UInt8](repeating: 0, count: 75)
        var pos = 0
        for i in 0..<12 {
            let val = charValues[i]
            for b in stride(from: 5, through: 0, by: -1) {
                bits[pos] = UInt8((val >> b) & 1)
                pos += 1
            }
        }
        bits[72] = UInt8((frameType >> 2) & 1)
        bits[73] = UInt8((frameType >> 1) & 1)
        bits[74] = UInt8(frameType & 1)

        // Pack into bytes for CRC computation
        var bytes = [UInt8](repeating: 0, count: 11)
        for i in 0..<10 {
            var byte: UInt8 = 0
            for b in 0..<8 {
                let bitIdx = i * 8 + b
                if bitIdx < 75 {
                    byte = (byte << 1) | bits[bitIdx]
                } else {
                    byte = byte << 1
                }
            }
            bytes[i] = byte
        }
        bytes[9] = bytes[9] & 0xE0   // Mask byte 9 to top 3 bits
        bytes[10] = 0

        // Compute CRC-12 and XOR with 42 (JS8Call discriminator)
        var icrc = crc12(bytes, count: 11)
        icrc ^= 42

        // Build 87-bit information word: 72 payload + 3 type + 12 CRC
        var msgbits = [UInt8](repeating: 0, count: JS8CallConstants.KK)
        for i in 0..<72 { msgbits[i] = bits[i] }
        msgbits[72] = UInt8((frameType >> 2) & 1)
        msgbits[73] = UInt8((frameType >> 1) & 1)
        msgbits[74] = UInt8(frameType & 1)
        for i in 0..<12 {
            msgbits[75 + i] = UInt8((icrc >> (11 - i)) & 1)
        }

        return msgbits
    }

    // MARK: - Unpack

    /// Unpack 87 decoded bits into a message string and frame type.
    /// Returns nil if the CRC check fails.
    public static func unpack(_ bits: [UInt8]) -> (message: String, frameType: Int)? {
        guard bits.count >= JS8CallConstants.KK else { return nil }

        // Verify CRC
        guard verifyCRC(bits) else { return nil }

        // Extract frame type (bits 72-74)
        let frameType = Int(bits[72]) * 4 + Int(bits[73]) * 2 + Int(bits[74])

        // Extract 12 characters (bits 0-71, 6 bits each)
        var text = ""
        for i in 0..<12 {
            var val = 0
            for b in 0..<6 {
                val = (val << 1) + Int(bits[i * 6 + b])
            }
            if val < alphabet.count {
                text.append(alphabet[val])
            }
        }

        // Trim trailing spaces/dots
        while text.hasSuffix(" ") || text.hasSuffix(".") {
            text.removeLast()
        }

        return (text, frameType)
    }

    // MARK: - CRC Verification

    /// Verify the CRC-12 embedded in 87 decoded bits.
    public static func verifyCRC(_ bits: [UInt8]) -> Bool {
        guard bits.count >= JS8CallConstants.KK else { return false }

        // Pack first 75 bits into bytes
        var bytes = [UInt8](repeating: 0, count: 11)
        for i in 0..<10 {
            var byte: UInt8 = 0
            for b in 0..<8 {
                let bitIdx = i * 8 + b
                if bitIdx < 75 {
                    byte = (byte << 1) | bits[bitIdx]
                } else {
                    byte = byte << 1
                }
            }
            bytes[i] = byte
        }
        bytes[9] = bytes[9] & 0xE0
        bytes[10] = 0

        // Compute expected CRC
        var expectedCRC = crc12(bytes, count: 11)
        expectedCRC ^= 42

        // Extract received CRC from bits 75-86
        var receivedCRC: UInt16 = 0
        for i in 0..<12 {
            receivedCRC = (receivedCRC << 1) | UInt16(bits[75 + i])
        }

        return receivedCRC == expectedCRC
    }
}
