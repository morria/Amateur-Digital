//
//  Channel.swift
//  DigiModes
//
//  Represents a detected signal/conversation on a specific frequency
//

import Foundation

struct Channel: Identifiable, Equatable, Hashable {
    let id: UUID
    var frequency: Int           // Audio frequency in Hz (300-3000)
    var callsign: String?        // Parsed from decoded text, or nil
    var messages: [Message]
    var lastActivity: Date
    var decodingBuffer: String   // Currently being decoded (real-time)
    var squelch: Int             // Per-channel squelch threshold (0-100)

    /// Default squelch threshold for new channels
    static let defaultSquelch = 0

    init(
        id: UUID = UUID(),
        frequency: Int,
        callsign: String? = nil,
        messages: [Message] = [],
        lastActivity: Date = Date(),
        decodingBuffer: String = "",
        squelch: Int = Channel.defaultSquelch
    ) {
        self.id = id
        self.frequency = frequency
        self.callsign = callsign
        self.messages = messages
        self.lastActivity = lastActivity
        self.decodingBuffer = decodingBuffer
        self.squelch = squelch
    }

    /// Display name: callsign if known, otherwise frequency
    var displayName: String {
        callsign ?? "\(frequency) Hz"
    }

    /// Frequency offset from 1500 Hz center
    var frequencyOffsetDisplay: String {
        let offset = frequency - 1500
        let sign = offset >= 0 ? "+" : ""
        return "\(sign)\(offset) Hz"
    }

    /// Preview text for channel list
    /// Shows the tail (most recent 2 lines) of real-time decoding buffer or last message
    var previewText: String {
        let raw: String
        if !decodingBuffer.isEmpty {
            raw = decodingBuffer
        } else if let lastContent = messages.last?.content {
            raw = lastContent
        } else {
            return ""
        }

        // Split into lines, take the last 2 non-empty lines
        let lines = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let tail = lines.suffix(2)
        return tail.joined(separator: "\n")
    }

    /// Time since last activity
    var timeSinceActivity: TimeInterval {
        Date().timeIntervalSince(lastActivity)
    }

    /// Minimum printable characters required before channel appears in list.
    /// Filters out noise bursts that decode as 1-2 random characters.
    static let minimumVisibleCharacters = 3

    /// Count of printable (non-whitespace, non-control) characters across all content
    private var printableCharacterCount: Int {
        let bufferPrintable = decodingBuffer.filter { !$0.isWhitespace && !$0.isNewline }
        let messagePrintable = messages.reduce(0) { count, msg in
            count + msg.content.filter { !$0.isWhitespace && !$0.isNewline }.count
        }
        return bufferPrintable.count + messagePrintable
    }

    /// Whether the channel has enough content to display.
    /// Requires minimum printable characters to filter noise.
    var hasContent: Bool {
        printableCharacterCount >= Self.minimumVisibleCharacters
    }

    static func == (lhs: Channel, rhs: Channel) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Sample Data

extension Channel {
    static let sampleChannels: [Channel] = [
        Channel(
            frequency: 1450,
            callsign: "W1AW",
            messages: [
                Message(content: "CQ CQ CQ DE W1AW W1AW K", direction: .received, callsign: "W1AW"),
                Message(content: "W1AW DE N0CALL N0CALL K", direction: .sent, callsign: "N0CALL"),
                Message(content: "N0CALL DE W1AW GM UR RST 599 NAME HIRAM QTH CT K", direction: .received, callsign: "W1AW")
            ],
            lastActivity: Date().addingTimeInterval(-120) // 2 min ago
        ),
        Channel(
            frequency: 1820,
            callsign: "K1ABC",
            messages: [
                Message(content: "TU FER QSO 73 DE K1ABC K", direction: .received, callsign: "K1ABC")
            ],
            lastActivity: Date().addingTimeInterval(-300) // 5 min ago
        ),
        Channel(
            frequency: 1250,
            callsign: nil,  // Not yet parsed
            messages: [
                Message(content: "RYRYRYRYRYRYRYRYRYRYRYRY", direction: .received)
            ],
            lastActivity: Date().addingTimeInterval(-12) // 12 sec ago
        )
    ]
}
