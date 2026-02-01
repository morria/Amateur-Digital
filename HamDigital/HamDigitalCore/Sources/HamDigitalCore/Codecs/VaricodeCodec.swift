//
//  VaricodeCodec.swift
//  HamDigitalCore
//
//  Varicode encoding and decoding for PSK31
//

import Foundation

/// Varicode codec for PSK31 encoding/decoding
///
/// Varicode is a variable-length binary encoding optimized for text transmission.
/// Common characters (like 'e', ' ', 't') use fewer bits than rare characters.
/// Characters are separated by two or more zero bits (`00`).
///
/// Key properties:
/// - Variable length: 10-22 bits per character
/// - Character boundary: `00` (two zero bits) between characters
/// - No `00` within any character code
/// - Case-sensitive (unlike Baudot)
public final class VaricodeCodec {

    // MARK: - Varicode Table

    /// Varicode encodings for ASCII characters 0-127
    /// Each entry is (bit pattern, number of bits)
    /// Bit pattern is stored MSB first
    public static let varicodeTable: [(code: UInt32, bits: Int)] = [
        // Control characters (0x00-0x1F) - rarely used, long codes
        (0b1010101011, 10),     // 0x00 NUL
        (0b1011011011, 10),     // 0x01 SOH
        (0b1011101101, 10),     // 0x02 STX
        (0b1101110111, 10),     // 0x03 ETX
        (0b1011101011, 10),     // 0x04 EOT
        (0b1101011111, 10),     // 0x05 ENQ
        (0b1011101111, 10),     // 0x06 ACK
        (0b1011111101, 10),     // 0x07 BEL
        (0b1011111111, 10),     // 0x08 BS
        (0b11101111, 8),        // 0x09 TAB
        (0b11101, 5),           // 0x0A LF
        (0b1101101111, 10),     // 0x0B VT
        (0b1011011101, 10),     // 0x0C FF
        (0b11111, 5),           // 0x0D CR
        (0b1101110101, 10),     // 0x0E SO
        (0b1110101011, 10),     // 0x0F SI
        (0b1011110111, 10),     // 0x10 DLE
        (0b1011110101, 10),     // 0x11 DC1
        (0b1110101101, 10),     // 0x12 DC2
        (0b1110101111, 10),     // 0x13 DC3
        (0b1101011011, 10),     // 0x14 DC4
        (0b1101101011, 10),     // 0x15 NAK
        (0b1101101101, 10),     // 0x16 SYN
        (0b1101010111, 10),     // 0x17 ETB
        (0b1101111011, 10),     // 0x18 CAN
        (0b1101111101, 10),     // 0x19 EM
        (0b1110110111, 10),     // 0x1A SUB
        (0b1101010101, 10),     // 0x1B ESC
        (0b1101011101, 10),     // 0x1C FS
        (0b1110111011, 10),     // 0x1D GS
        (0b1011111011, 10),     // 0x1E RS
        (0b1101111111, 10),     // 0x1F US

        // Printable ASCII characters (0x20-0x7F)
        (0b1, 1),               // 0x20 SPACE - shortest code!
        (0b111111111, 9),       // 0x21 !
        (0b101011111, 9),       // 0x22 "
        (0b111110101, 9),       // 0x23 #
        (0b111011011, 9),       // 0x24 $
        (0b1011010101, 10),     // 0x25 %
        (0b1010111011, 10),     // 0x26 &
        (0b101111111, 9),       // 0x27 '
        (0b11111011, 8),        // 0x28 (
        (0b11110111, 8),        // 0x29 )
        (0b101101111, 9),       // 0x2A *
        (0b111011111, 9),       // 0x2B +
        (0b1110101, 7),         // 0x2C ,
        (0b110101, 6),          // 0x2D -
        (0b1010111, 7),         // 0x2E .
        (0b110101111, 9),       // 0x2F /
        (0b10110111, 8),        // 0x30 0
        (0b10111101, 8),        // 0x31 1
        (0b11101101, 8),        // 0x32 2
        (0b11111111, 8),        // 0x33 3
        (0b101110111, 9),       // 0x34 4
        (0b101011011, 9),       // 0x35 5
        (0b101101011, 9),       // 0x36 6
        (0b110101101, 9),       // 0x37 7
        (0b110101011, 9),       // 0x38 8
        (0b110110111, 9),       // 0x39 9
        (0b11110101, 8),        // 0x3A :
        (0b110111101, 9),       // 0x3B ;
        (0b111101101, 9),       // 0x3C <
        (0b1010101, 7),         // 0x3D =
        (0b111010111, 9),       // 0x3E >
        (0b1010101111, 10),     // 0x3F ?
        (0b1010111101, 10),     // 0x40 @
        (0b1111101, 7),         // 0x41 A
        (0b11101011, 8),        // 0x42 B
        (0b10101101, 8),        // 0x43 C
        (0b10110101, 8),        // 0x44 D
        (0b1110111, 7),         // 0x45 E
        (0b11011011, 8),        // 0x46 F
        (0b11111101, 8),        // 0x47 G
        (0b101010101, 9),       // 0x48 H
        (0b1111111, 7),         // 0x49 I
        (0b111111101, 9),       // 0x4A J
        (0b101111101, 9),       // 0x4B K
        (0b11010111, 8),        // 0x4C L
        (0b10111011, 8),        // 0x4D M
        (0b11011101, 8),        // 0x4E N
        (0b10101011, 8),        // 0x4F O
        (0b11010101, 8),        // 0x50 P
        (0b111011101, 9),       // 0x51 Q
        (0b10101111, 8),        // 0x52 R
        (0b1101111, 7),         // 0x53 S
        (0b1101101, 7),         // 0x54 T
        (0b101010111, 9),       // 0x55 U
        (0b110110101, 9),       // 0x56 V
        (0b101011101, 9),       // 0x57 W
        (0b101110101, 9),       // 0x58 X
        (0b101111011, 9),       // 0x59 Y
        (0b1010101101, 10),     // 0x5A Z
        (0b111110111, 9),       // 0x5B [
        (0b111101111, 9),       // 0x5C \
        (0b111111011, 9),       // 0x5D ]
        (0b1010111111, 10),     // 0x5E ^
        (0b101101101, 9),       // 0x5F _
        (0b1011011111, 10),     // 0x60 `
        (0b1011, 4),            // 0x61 a
        (0b1011111, 7),         // 0x62 b
        (0b101111, 6),          // 0x63 c
        (0b101101, 6),          // 0x64 d
        (0b11, 2),              // 0x65 e - second shortest!
        (0b111101, 6),          // 0x66 f
        (0b1011011, 7),         // 0x67 g
        (0b101011, 6),          // 0x68 h
        (0b1101, 4),            // 0x69 i
        (0b111101011, 9),       // 0x6A j
        (0b10111111, 8),        // 0x6B k
        (0b11011, 5),           // 0x6C l
        (0b111011, 6),          // 0x6D m
        (0b1111, 4),            // 0x6E n
        (0b111, 3),             // 0x6F o
        (0b111111, 6),          // 0x70 p
        (0b110111111, 9),       // 0x71 q
        (0b10101, 5),           // 0x72 r
        (0b10111, 5),           // 0x73 s
        (0b101, 3),             // 0x74 t
        (0b110111, 6),          // 0x75 u
        (0b1111011, 7),         // 0x76 v
        (0b1101011, 7),         // 0x77 w
        (0b11011111, 8),        // 0x78 x
        (0b1011101, 7),         // 0x79 y
        (0b111010101, 9),       // 0x7A z
        (0b1010110111, 10),     // 0x7B {
        (0b110111011, 9),       // 0x7C |
        (0b1010110101, 10),     // 0x7D }
        (0b1011010111, 10),     // 0x7E ~
        (0b1110110101, 10),     // 0x7F DEL
    ]

    /// Reverse lookup: bit pattern -> ASCII character
    /// Built at initialization for fast decoding
    private static let reverseTable: [UInt32: UInt8] = {
        var table: [UInt32: UInt8] = [:]
        for (ascii, entry) in varicodeTable.enumerated() {
            table[entry.code] = UInt8(ascii)
        }
        return table
    }()

    // MARK: - Decoder State

    /// Accumulated bits for current character being decoded
    private var bitAccumulator: UInt32 = 0

    /// Number of bits in accumulator
    private var bitCount: Int = 0

    /// Count of consecutive zero bits (for detecting character boundaries)
    private var zeroCount: Int = 0

    // MARK: - Initialization

    public init() {}

    /// Reset the codec state
    public func reset() {
        bitAccumulator = 0
        bitCount = 0
        zeroCount = 0
    }

    // MARK: - Encoding

    /// Encode a single character to Varicode bits
    /// - Parameter char: ASCII character to encode
    /// - Returns: Array of bits (true = 1, false = 0), or nil if character not encodable
    public func encode(_ char: Character) -> [Bool]? {
        guard let ascii = char.asciiValue, ascii < 128 else {
            return nil
        }

        let entry = Self.varicodeTable[Int(ascii)]
        var bits: [Bool] = []

        // Extract bits from MSB to LSB
        for i in stride(from: entry.bits - 1, through: 0, by: -1) {
            let bit = (entry.code >> i) & 1
            bits.append(bit == 1)
        }

        // Append two zero bits as character separator
        bits.append(false)
        bits.append(false)

        return bits
    }

    /// Encode a string to Varicode bits
    /// - Parameter string: String to encode
    /// - Returns: Array of bits (true = 1, false = 0)
    public func encode(_ string: String) -> [Bool] {
        var bits: [Bool] = []

        for char in string {
            if let charBits = encode(char) {
                bits.append(contentsOf: charBits)
            }
        }

        return bits
    }

    /// Encode a string with idle preamble
    /// - Parameters:
    ///   - string: String to encode
    ///   - idleBits: Number of idle (zero) bits before message
    /// - Returns: Array of bits
    public func encodeWithPreamble(_ string: String, idleBits: Int = 32) -> [Bool] {
        var bits = [Bool](repeating: false, count: idleBits)
        bits.append(contentsOf: encode(string))
        return bits
    }

    // MARK: - Decoding

    /// Decode a single bit and return character if complete
    /// - Parameter bit: Input bit (true = 1, false = 0)
    /// - Returns: Decoded character if a complete character was received, nil otherwise
    public func decode(bit: Bool) -> Character? {
        if bit {
            // Received a 1 bit
            // If we had pending zeros (but fewer than 2), add them to the accumulator now
            for _ in 0..<zeroCount {
                bitAccumulator = bitAccumulator << 1
                bitCount += 1
            }
            zeroCount = 0

            // Add the 1 bit to accumulator
            bitAccumulator = (bitAccumulator << 1) | 1
            bitCount += 1
        } else {
            // Received a 0 bit
            zeroCount += 1

            if zeroCount >= 2 {
                // Two consecutive zeros = character boundary
                if bitCount > 0 {
                    // We have accumulated bits - decode them
                    let char = decodeAccumulator()
                    bitAccumulator = 0
                    bitCount = 0
                    // Reset zeroCount after decoding
                    zeroCount = 0
                    return char
                }
                // No accumulated bits - we're in idle, just continue
            }
            // Don't add zero to accumulator yet - wait to see if it's a separator
        }

        // Overflow protection
        if bitCount > 22 {
            bitAccumulator = 0
            bitCount = 0
            zeroCount = 0
        }

        return nil
    }

    /// Decode multiple bits and return all decoded characters
    /// - Parameter bits: Array of bits to decode
    /// - Returns: String of decoded characters
    public func decode(bits: [Bool]) -> String {
        var result = ""
        for bit in bits {
            if let char = decode(bit: bit) {
                result.append(char)
            }
        }
        return result
    }

    // MARK: - Private Helpers

    /// Attempt to decode the accumulated bits to a character
    private func decodeAccumulator() -> Character? {
        guard bitCount > 0 else { return nil }

        // Look up in reverse table
        if let ascii = Self.reverseTable[bitAccumulator] {
            return Character(UnicodeScalar(ascii))
        }

        return nil
    }
}

// MARK: - Convenience Extensions

extension VaricodeCodec {

    /// Get the bit length for a character
    /// - Parameter char: Character to check
    /// - Returns: Number of bits (including separator), or nil if not encodable
    public static func bitLength(for char: Character) -> Int? {
        guard let ascii = char.asciiValue, ascii < 128 else {
            return nil
        }
        return varicodeTable[Int(ascii)].bits + 2  // +2 for separator
    }

    /// Get the bit length for a string
    /// - Parameter string: String to check
    /// - Returns: Total number of bits needed
    public static func bitLength(for string: String) -> Int {
        var total = 0
        for char in string {
            if let length = bitLength(for: char) {
                total += length
            }
        }
        return total
    }
}
