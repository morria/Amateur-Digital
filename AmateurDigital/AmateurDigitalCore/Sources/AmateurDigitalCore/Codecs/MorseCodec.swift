//
//  MorseCodec.swift
//  AmateurDigitalCore
//
//  Morse code encoding and decoding via binary tree lookup
//

import Foundation

/// Represents a Morse code element (dit or dah)
public enum MorseElement: Equatable, CustomStringConvertible {
    case dit
    case dah

    public var description: String {
        switch self {
        case .dit: return "."
        case .dah: return "-"
        }
    }
}

/// Morse code codec for encoding text to dit/dah sequences and decoding back
///
/// Uses the International Morse Code standard (ITU-R M.1677-1).
/// Supports letters A-Z, digits 0-9, common punctuation, and prosigns.
///
/// Timing (in dit units, PARIS standard):
/// - Dit: 1 unit
/// - Dah: 3 units
/// - Intra-character gap: 1 unit
/// - Inter-character gap: 3 units
/// - Word gap: 7 units
public struct MorseCodec {

    // MARK: - Morse Table

    /// Character to Morse element mapping (ITU standard)
    public static let morseTable: [(character: Character, elements: [MorseElement])] = [
        // Letters
        ("A", [.dit, .dah]),
        ("B", [.dah, .dit, .dit, .dit]),
        ("C", [.dah, .dit, .dah, .dit]),
        ("D", [.dah, .dit, .dit]),
        ("E", [.dit]),
        ("F", [.dit, .dit, .dah, .dit]),
        ("G", [.dah, .dah, .dit]),
        ("H", [.dit, .dit, .dit, .dit]),
        ("I", [.dit, .dit]),
        ("J", [.dit, .dah, .dah, .dah]),
        ("K", [.dah, .dit, .dah]),
        ("L", [.dit, .dah, .dit, .dit]),
        ("M", [.dah, .dah]),
        ("N", [.dah, .dit]),
        ("O", [.dah, .dah, .dah]),
        ("P", [.dit, .dah, .dah, .dit]),
        ("Q", [.dah, .dah, .dit, .dah]),
        ("R", [.dit, .dah, .dit]),
        ("S", [.dit, .dit, .dit]),
        ("T", [.dah]),
        ("U", [.dit, .dit, .dah]),
        ("V", [.dit, .dit, .dit, .dah]),
        ("W", [.dit, .dah, .dah]),
        ("X", [.dah, .dit, .dit, .dah]),
        ("Y", [.dah, .dit, .dah, .dah]),
        ("Z", [.dah, .dah, .dit, .dit]),
        // Digits
        ("0", [.dah, .dah, .dah, .dah, .dah]),
        ("1", [.dit, .dah, .dah, .dah, .dah]),
        ("2", [.dit, .dit, .dah, .dah, .dah]),
        ("3", [.dit, .dit, .dit, .dah, .dah]),
        ("4", [.dit, .dit, .dit, .dit, .dah]),
        ("5", [.dit, .dit, .dit, .dit, .dit]),
        ("6", [.dah, .dit, .dit, .dit, .dit]),
        ("7", [.dah, .dah, .dit, .dit, .dit]),
        ("8", [.dah, .dah, .dah, .dit, .dit]),
        ("9", [.dah, .dah, .dah, .dah, .dit]),
        // Punctuation
        (".", [.dit, .dah, .dit, .dah, .dit, .dah]),
        (",", [.dah, .dah, .dit, .dit, .dah, .dah]),
        ("?", [.dit, .dit, .dah, .dah, .dit, .dit]),
        ("'", [.dit, .dah, .dah, .dah, .dah, .dit]),
        ("!", [.dah, .dit, .dah, .dit, .dah, .dah]),
        ("/", [.dah, .dit, .dit, .dah, .dit]),
        ("(", [.dah, .dit, .dah, .dah, .dit]),
        (")", [.dah, .dit, .dah, .dah, .dit, .dah]),
        ("&", [.dit, .dah, .dit, .dit, .dit]),
        (":", [.dah, .dah, .dah, .dit, .dit, .dit]),
        (";", [.dah, .dit, .dah, .dit, .dah, .dit]),
        ("=", [.dah, .dit, .dit, .dit, .dah]),
        ("+", [.dit, .dah, .dit, .dah, .dit]),
        ("-", [.dah, .dit, .dit, .dit, .dit, .dah]),
        ("_", [.dit, .dit, .dah, .dah, .dit, .dah]),
        ("\"", [.dit, .dah, .dit, .dit, .dah, .dit]),
        ("$", [.dit, .dit, .dit, .dah, .dit, .dit, .dah]),
        ("@", [.dit, .dah, .dah, .dit, .dah, .dit]),
    ]

    /// Prosigns (procedural signals) - sent without inter-character gap
    public static let prosignTable: [(name: String, elements: [MorseElement])] = [
        ("AR", [.dit, .dah, .dit, .dah, .dit]),       // End of message
        ("AS", [.dit, .dah, .dit, .dit, .dit]),        // Wait
        ("BT", [.dah, .dit, .dit, .dit, .dah]),        // Break / new paragraph (=)
        ("CT", [.dah, .dit, .dah, .dit, .dah]),        // Commence transmission
        ("KN", [.dah, .dit, .dah, .dah, .dit]),        // Invitation to specific station
        ("SK", [.dit, .dit, .dit, .dah, .dit, .dah]),  // End of contact
        ("SN", [.dit, .dit, .dit, .dah, .dit]),        // Understood (= &)
        ("SOS", [.dit, .dit, .dit, .dah, .dah, .dah, .dit, .dit, .dit]),
    ]

    // MARK: - Binary Tree for Decoding

    /// Node in the Morse binary tree
    final class TreeNode {
        var character: Character?
        var dit: TreeNode?
        var dah: TreeNode?

        init(character: Character? = nil) {
            self.character = character
        }
    }

    /// Root of the Morse decode tree
    private static let decodeTree: TreeNode = {
        let root = TreeNode()
        for (char, elements) in morseTable {
            var node = root
            for element in elements {
                switch element {
                case .dit:
                    if node.dit == nil { node.dit = TreeNode() }
                    node = node.dit!
                case .dah:
                    if node.dah == nil { node.dah = TreeNode() }
                    node = node.dah!
                }
            }
            node.character = char
        }
        return root
    }()

    /// Character to elements lookup dictionary
    private static let encodeDict: [Character: [MorseElement]] = {
        var dict = [Character: [MorseElement]]()
        for (char, elements) in morseTable {
            dict[char] = elements
        }
        return dict
    }()

    // MARK: - Encoding

    /// Encode a character to Morse elements
    /// - Parameter character: Character to encode (case-insensitive)
    /// - Returns: Array of MorseElements, or nil if character has no Morse representation
    public static func encode(_ character: Character) -> [MorseElement]? {
        let upper = Character(character.uppercased())
        return encodeDict[upper]
    }

    /// Encode a string to a sequence of Morse elements with timing
    /// Returns a flat array of "timing events" where:
    /// - positive values = key-down duration in dit units
    /// - negative values = key-up duration in dit units
    /// For example: "AB" → [1, -1, 3, -3, 3, -1, 1, -1, 1, -1, 1]
    public static func encodeToTimings(_ text: String) -> [Int] {
        var timings = [Int]()
        let chars = Array(text.uppercased())
        var firstChar = true

        for char in chars {
            if char == " " {
                // Word space: 7 dit units total gap
                if !timings.isEmpty {
                    if let last = timings.last, last < 0 {
                        // Replace trailing inter-char gap with word gap
                        timings[timings.count - 1] = -7
                    } else {
                        // No trailing gap yet — append word gap directly
                        timings.append(-7)
                    }
                }
                firstChar = true
                continue
            }

            guard let elements = encode(char) else { continue }

            // Inter-character gap (3 dit units) before this character
            if !firstChar {
                timings.append(-3)
            }
            firstChar = false

            for (i, element) in elements.enumerated() {
                // Intra-character gap (1 dit unit) between elements
                if i > 0 {
                    timings.append(-1)
                }

                switch element {
                case .dit: timings.append(1)
                case .dah: timings.append(3)
                }
            }
        }

        return timings
    }

    // MARK: - Decoding

    /// Decode state for building up characters from elements
    private var currentNode: TreeNode

    public init() {
        self.currentNode = Self.decodeTree
    }

    /// Feed a single Morse element and get a character if the sequence is complete
    /// Call `finishCharacter()` when an inter-character gap is detected
    public mutating func feed(_ element: MorseElement) {
        switch element {
        case .dit:
            if let next = currentNode.dit {
                currentNode = next
            } else {
                // Invalid sequence - reset
                currentNode = Self.decodeTree
            }
        case .dah:
            if let next = currentNode.dah {
                currentNode = next
            } else {
                // Invalid sequence - reset
                currentNode = Self.decodeTree
            }
        }
    }

    /// Complete the current character and return it
    /// Call this when an inter-character or word gap is detected
    /// - Returns: The decoded character, or nil if the sequence is invalid
    public mutating func finishCharacter() -> Character? {
        let char = currentNode.character
        currentNode = Self.decodeTree
        return char
    }

    /// Reset the decoder state
    public mutating func reset() {
        currentNode = Self.decodeTree
    }

    /// Check if there is a partial character being built
    public var hasPartialCharacter: Bool {
        currentNode !== Self.decodeTree
    }

    // MARK: - Static Decode

    /// Decode an array of elements to a character
    /// - Parameter elements: Array of dit/dah elements
    /// - Returns: The decoded character, or nil if the sequence is invalid
    public static func decode(_ elements: [MorseElement]) -> Character? {
        var node = decodeTree
        for element in elements {
            switch element {
            case .dit:
                guard let next = node.dit else { return nil }
                node = next
            case .dah:
                guard let next = node.dah else { return nil }
                node = next
            }
        }
        return node.character
    }

    /// Decode a dot/dash string like ".-" to a character
    /// - Parameter pattern: String of dots (.) and dashes (-)
    /// - Returns: The decoded character, or nil if invalid
    public static func decode(pattern: String) -> Character? {
        let elements = pattern.compactMap { ch -> MorseElement? in
            switch ch {
            case ".": return .dit
            case "-": return .dah
            default: return nil
            }
        }
        return decode(elements)
    }

    /// WPM to dit duration conversion (PARIS standard)
    /// - Parameter wpm: Words per minute
    /// - Returns: Dit duration in seconds
    public static func ditDuration(forWPM wpm: Double) -> Double {
        1.2 / wpm
    }

    /// Dit duration to WPM conversion
    /// - Parameter ditDuration: Dit duration in seconds
    /// - Returns: Words per minute
    public static func wpm(forDitDuration ditDuration: Double) -> Double {
        1.2 / ditDuration
    }
}
