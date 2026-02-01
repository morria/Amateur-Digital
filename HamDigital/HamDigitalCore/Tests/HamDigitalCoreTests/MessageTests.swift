//
//  MessageTests.swift
//  DigiModesCoreTests
//

import XCTest
@testable import HamDigitalCore

final class MessageTests: XCTestCase {

    func testMessageCreation() {
        let message = Message(
            content: "CQ CQ CQ DE W1AW",
            direction: .received,
            mode: .rtty,
            callsign: "W1AW"
        )

        XCTAssertEqual(message.content, "CQ CQ CQ DE W1AW")
        XCTAssertEqual(message.direction, .received)
        XCTAssertEqual(message.mode, .rtty)
        XCTAssertEqual(message.callsign, "W1AW")
        XCTAssertNil(message.signalReport)
    }

    func testMessageWithSignalReport() {
        let message = Message(
            content: "UR RST 599",
            direction: .received,
            mode: .rtty,
            callsign: "W1AW",
            signalReport: "599"
        )

        XCTAssertEqual(message.signalReport, "599")
    }

    func testMessageEquality() {
        let id = UUID()
        let timestamp = Date()

        let message1 = Message(
            id: id,
            content: "TEST",
            timestamp: timestamp,
            direction: .sent,
            mode: .rtty
        )

        let message2 = Message(
            id: id,
            content: "TEST",
            timestamp: timestamp,
            direction: .sent,
            mode: .rtty
        )

        XCTAssertEqual(message1, message2)
    }

    func testMessageCodable() throws {
        let original = Message(
            content: "CQ CQ",
            direction: .sent,
            mode: .psk31,
            callsign: "N0CALL",
            signalReport: "589"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Message.self, from: data)

        XCTAssertEqual(decoded.content, original.content)
        XCTAssertEqual(decoded.direction, original.direction)
        XCTAssertEqual(decoded.mode, original.mode)
        XCTAssertEqual(decoded.callsign, original.callsign)
        XCTAssertEqual(decoded.signalReport, original.signalReport)
    }

    func testSampleMessagesExist() {
        XCTAssertFalse(Message.sampleMessages.isEmpty)
        XCTAssertEqual(Message.sampleMessages.count, 4)
    }

    func testSampleMessagesHaveMixedDirections() {
        let received = Message.sampleMessages.filter { $0.direction == .received }
        let sent = Message.sampleMessages.filter { $0.direction == .sent }

        XCTAssertFalse(received.isEmpty)
        XCTAssertFalse(sent.isEmpty)
    }
}
