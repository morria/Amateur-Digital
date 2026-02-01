//
//  Message.swift
//  DigiModes
//

import Foundation

struct Message: Identifiable, Equatable {
    let id: UUID
    var content: String
    let timestamp: Date
    let direction: Direction
    let mode: DigitalMode
    let callsign: String?
    let signalReport: String?  // RST or SNR
    var transmitState: TransmitState?

    enum Direction: String, Codable {
        case received  // RX - decoded from audio
        case sent      // TX - transmitted by user
    }

    enum TransmitState: String, Codable {
        case queued       // Message waiting to be transmitted
        case transmitting // Currently being transmitted
        case sent         // Successfully transmitted
        case failed       // Transmission failed
    }

    init(
        id: UUID = UUID(),
        content: String,
        timestamp: Date = Date(),
        direction: Direction,
        mode: DigitalMode = .rtty,
        callsign: String? = nil,
        signalReport: String? = nil,
        transmitState: TransmitState? = nil
    ) {
        self.id = id
        self.content = content
        self.timestamp = timestamp
        self.direction = direction
        self.mode = mode
        self.callsign = callsign
        self.signalReport = signalReport
        self.transmitState = transmitState
    }
}

// MARK: - Sample Data for Development
extension Message {
    static let sampleMessages: [Message] = [
        Message(
            content: "CQ CQ CQ DE W1AW W1AW K",
            direction: .received,
            mode: .rtty,
            callsign: "W1AW"
        ),
        Message(
            content: "W1AW DE N0CALL N0CALL K",
            direction: .sent,
            mode: .rtty,
            callsign: "N0CALL"
        ),
        Message(
            content: "N0CALL DE W1AW GM UR RST 599 599 NAME IS HIRAM QTH NEWINGTON CT K",
            direction: .received,
            mode: .rtty,
            callsign: "W1AW",
            signalReport: "599"
        ),
        Message(
            content: "W1AW DE N0CALL R FB HIRAM UR RST 589 589 NAME IS JOHN QTH DENVER CO K",
            direction: .sent,
            mode: .rtty,
            callsign: "N0CALL",
            signalReport: "589"
        )
    ]
}
