//
//  Channel.swift
//  DigiModesCore
//
//  Represents a detected signal/conversation on a specific frequency
//

import Foundation

public struct Channel: Identifiable, Equatable, Hashable {
    public let id: UUID
    public var frequency: Int           // Audio frequency in Hz (300-3000)
    public var callsign: String?        // Parsed from decoded text, or nil
    public var messages: [Message]
    public var lastActivity: Date

    public init(
        id: UUID = UUID(),
        frequency: Int,
        callsign: String? = nil,
        messages: [Message] = [],
        lastActivity: Date = Date()
    ) {
        self.id = id
        self.frequency = frequency
        self.callsign = callsign
        self.messages = messages
        self.lastActivity = lastActivity
    }

    /// Display name: callsign if known, otherwise frequency
    public var displayName: String {
        callsign ?? "\(frequency) Hz"
    }

    /// Preview text for channel list (last message content)
    public var previewText: String {
        messages.last?.content ?? ""
    }

    /// Time since last activity
    public var timeSinceActivity: TimeInterval {
        Date().timeIntervalSince(lastActivity)
    }

    public static func == (lhs: Channel, rhs: Channel) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

// MARK: - Sample Data

extension Channel {
    public static let sampleChannels: [Channel] = [
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
