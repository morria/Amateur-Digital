//
//  BaudotCodec.swift
//  DigiModesCore
//
//  Baudot/ITA2 encoding and decoding for RTTY
//

import Foundation

/// Baudot (ITA2) codec for RTTY encoding/decoding
///
/// Baudot is a 5-bit character encoding used in RTTY. It uses two "shift" states:
/// - LTRS (Letters): Alphabetic characters
/// - FIGS (Figures): Numbers and punctuation
///
/// Special codes:
/// - 0x1F (11111): LTRS shift
/// - 0x1B (11011): FIGS shift
/// - 0x00 (00000): Null/Blank
/// - 0x04 (00100): Space
/// - 0x02 (00010): Line Feed
/// - 0x08 (01000): Carriage Return
public final class BaudotCodec {

    public enum ShiftState {
        case letters
        case figures
    }

    // MARK: - Baudot Tables (ITA2)

    /// Letters shift table (LTRS mode)
    /// Index is the 5-bit Baudot code, value is the ASCII character
    public static let lettersTable: [Character?] = [
        nil,   // 0x00 - Null
        "E",   // 0x01
        "\n",  // 0x02 - Line Feed
        "A",   // 0x03
        " ",   // 0x04 - Space
        "S",   // 0x05
        "I",   // 0x06
        "U",   // 0x07
        "\r",  // 0x08 - Carriage Return
        "D",   // 0x09
        "R",   // 0x0A
        "J",   // 0x0B
        "N",   // 0x0C
        "F",   // 0x0D
        "C",   // 0x0E
        "K",   // 0x0F
        "T",   // 0x10
        "Z",   // 0x11
        "L",   // 0x12
        "W",   // 0x13
        "H",   // 0x14
        "Y",   // 0x15
        "P",   // 0x16
        "Q",   // 0x17
        "O",   // 0x18
        "B",   // 0x19
        "G",   // 0x1A
        nil,   // 0x1B - FIGS shift
        "M",   // 0x1C
        "X",   // 0x1D
        "V",   // 0x1E
        nil    // 0x1F - LTRS shift
    ]

    /// Figures shift table (FIGS mode)
    /// Index is the 5-bit Baudot code, value is the ASCII character
    public static let figuresTable: [Character?] = [
        nil,   // 0x00 - Null
        "3",   // 0x01
        "\n",  // 0x02 - Line Feed
        "-",   // 0x03
        " ",   // 0x04 - Space
        "'",   // 0x05 (or BELL on some systems)
        "8",   // 0x06
        "7",   // 0x07
        "\r",  // 0x08 - Carriage Return
        "$",   // 0x09 (ENQ on some systems)
        "4",   // 0x0A
        "\u{07}", // 0x0B - Bell
        ",",   // 0x0C
        "!",   // 0x0D (or !)
        ":",   // 0x0E
        "(",   // 0x0F
        "5",   // 0x10
        "+",   // 0x11
        ")",   // 0x12
        "2",   // 0x13
        "#",   // 0x14 (or £)
        "6",   // 0x15
        "0",   // 0x16
        "1",   // 0x17
        "9",   // 0x18
        "?",   // 0x19
        "&",   // 0x1A
        nil,   // 0x1B - FIGS shift
        ".",   // 0x1C
        "/",   // 0x1D
        ";",   // 0x1E
        nil    // 0x1F - LTRS shift
    ]

    // MARK: - Reverse lookup tables (ASCII to Baudot)

    public static let asciiToLetters: [Character: UInt8] = {
        var dict: [Character: UInt8] = [:]
        for (code, char) in lettersTable.enumerated() {
            if let char = char {
                dict[char] = UInt8(code)
            }
        }
        return dict
    }()

    public static let asciiToFigures: [Character: UInt8] = {
        var dict: [Character: UInt8] = [:]
        for (code, char) in figuresTable.enumerated() {
            if let char = char {
                dict[char] = UInt8(code)
            }
        }
        return dict
    }()

    // MARK: - Special codes

    public static let shiftToLetters: UInt8 = 0x1F  // 11111
    public static let shiftToFigures: UInt8 = 0x1B  // 11011
    public static let nullCode: UInt8 = 0x00
    public static let spaceCode: UInt8 = 0x04

    // MARK: - Instance state

    public private(set) var currentShift: ShiftState = .letters

    public init(initialShift: ShiftState = .letters) {
        self.currentShift = initialShift
    }

    /// Reset the codec state to letters shift
    public func reset() {
        currentShift = .letters
    }

    // MARK: - Decoding (Baudot to ASCII)

    /// Decode a single 5-bit Baudot code to a character
    /// Returns nil if the code is a shift character (state change only)
    public func decode(_ code: UInt8) -> Character? {
        let code = code & 0x1F  // Ensure 5-bit value

        // Handle shift codes
        if code == Self.shiftToLetters {
            currentShift = .letters
            return nil
        } else if code == Self.shiftToFigures {
            currentShift = .figures
            return nil
        }

        // Look up character in appropriate table
        let table = currentShift == .letters ? Self.lettersTable : Self.figuresTable
        return table[Int(code)]
    }

    /// Decode an array of Baudot codes to a string
    public func decode(_ codes: [UInt8]) -> String {
        var result = ""
        for code in codes {
            if let char = decode(code) {
                result.append(char)
            }
        }
        return result
    }

    // MARK: - Encoding (ASCII to Baudot)

    /// Encode a single character to Baudot code(s)
    /// May return multiple codes if a shift is required
    public func encode(_ char: Character) -> [UInt8] {
        let upperChar = Character(char.uppercased())

        // Check if character is in current shift table
        if currentShift == .letters, let code = Self.asciiToLetters[upperChar] {
            return [code]
        } else if currentShift == .figures, let code = Self.asciiToFigures[upperChar] {
            return [code]
        }

        // Need to switch shift
        if let code = Self.asciiToLetters[upperChar] {
            currentShift = .letters
            return [Self.shiftToLetters, code]
        } else if let code = Self.asciiToFigures[upperChar] {
            currentShift = .figures
            return [Self.shiftToFigures, code]
        }

        // Character not in Baudot - return space
        return [Self.spaceCode]
    }

    /// Encode a string to Baudot codes
    public func encode(_ string: String) -> [UInt8] {
        var result: [UInt8] = []
        for char in string {
            result.append(contentsOf: encode(char))
        }
        return result
    }

    /// Encode a string with automatic LTRS prefix (standard practice)
    public func encodeWithPreamble(_ string: String, preambleCount: Int = 2) -> [UInt8] {
        var result: [UInt8] = Array(repeating: Self.shiftToLetters, count: preambleCount)
        currentShift = .letters
        result.append(contentsOf: encode(string))
        return result
    }
}
