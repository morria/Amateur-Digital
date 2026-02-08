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
    var rttyBaudRate: Double     // Per-channel RTTY baud rate (45.45, 50, 75)
    var polarityInverted: Bool   // Per-channel polarity inversion
    var frequencyOffset: Int     // Per-channel frequency offset in Hz (±50)
    var isLikelyLegitimate: Bool?          // nil = not yet classified
    var classificationConfidence: Double?   // 0.0-1.0
    var classifiedAtLength: Int = 0        // previewText length at last classification run
    var extractedAtLength: Int = 0         // previewText length at last callsign extraction run

    /// Default squelch threshold for new channels
    static let defaultSquelch = 0

    init(
        id: UUID = UUID(),
        frequency: Int,
        callsign: String? = nil,
        messages: [Message] = [],
        lastActivity: Date = Date(),
        decodingBuffer: String = "",
        squelch: Int = Channel.defaultSquelch,
        rttyBaudRate: Double = 45.45,
        polarityInverted: Bool = false,
        frequencyOffset: Int = 0,
        isLikelyLegitimate: Bool? = nil,
        classificationConfidence: Double? = nil
    ) {
        self.id = id
        self.frequency = frequency
        self.callsign = callsign
        self.messages = messages
        self.lastActivity = lastActivity
        self.decodingBuffer = decodingBuffer
        self.squelch = squelch
        self.rttyBaudRate = rttyBaudRate
        self.polarityInverted = polarityInverted
        self.frequencyOffset = frequencyOffset
        self.isLikelyLegitimate = isLikelyLegitimate
        self.classificationConfidence = classificationConfidence
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
    /// Shows the latest decoded content combining last message and real-time buffer
    var previewText: String {
        // Combine last message content with current decoding buffer
        var parts: [String] = []

        if let lastContent = messages.last?.content {
            let trimmed = lastContent.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                parts.append(trimmed)
            }
        }

        let bufferTrimmed = decodingBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bufferTrimmed.isEmpty {
            parts.append(bufferTrimmed)
        }

        guard !parts.isEmpty else { return "" }

        let combined = parts.joined(separator: " ")
        // Return a generous tail (last 300 chars) for up to 2 lines of display
        if combined.count > 300 {
            return String(combined.suffix(300))
        }
        return combined
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
