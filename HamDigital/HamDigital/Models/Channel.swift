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

    init(
        id: UUID = UUID(),
        frequency: Int,
        callsign: String? = nil,
        messages: [Message] = [],
        lastActivity: Date = Date(),
        decodingBuffer: String = ""
    ) {
        self.id = id
        self.frequency = frequency
        self.callsign = callsign
        self.messages = messages
        self.lastActivity = lastActivity
        self.decodingBuffer = decodingBuffer
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
    /// Shows real-time decoding buffer if active, otherwise last message
    var previewText: String {
        // If currently decoding, show that (with newlines as spaces)
        if !decodingBuffer.isEmpty {
            return decodingBuffer
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        // Otherwise show last message (with newlines as spaces)
        if let lastContent = messages.last?.content {
            return lastContent
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
        }
        return ""
    }

    /// Time since last activity
    var timeSinceActivity: TimeInterval {
        Date().timeIntervalSince(lastActivity)
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
