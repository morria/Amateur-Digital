//
//  DigitalModeTests.swift
//  DigiModesCoreTests
//

import XCTest
@testable import HamDigitalCore

final class DigitalModeTests: XCTestCase {

    func testAllCases() {
        let allModes = DigitalMode.allCases
        XCTAssertEqual(allModes.count, 6)
        XCTAssertTrue(allModes.contains(.rtty))
        XCTAssertTrue(allModes.contains(.psk31))
        XCTAssertTrue(allModes.contains(.bpsk63))
        XCTAssertTrue(allModes.contains(.qpsk31))
        XCTAssertTrue(allModes.contains(.qpsk63))
        XCTAssertTrue(allModes.contains(.olivia))
    }

    func testRawValues() {
        XCTAssertEqual(DigitalMode.rtty.rawValue, "RTTY")
        XCTAssertEqual(DigitalMode.psk31.rawValue, "PSK31")
        XCTAssertEqual(DigitalMode.bpsk63.rawValue, "BPSK63")
        XCTAssertEqual(DigitalMode.qpsk31.rawValue, "QPSK31")
        XCTAssertEqual(DigitalMode.qpsk63.rawValue, "QPSK63")
        XCTAssertEqual(DigitalMode.olivia.rawValue, "Olivia")
    }

    func testDisplayNames() {
        XCTAssertEqual(DigitalMode.rtty.displayName, "RTTY (45.45 Baud)")
        XCTAssertEqual(DigitalMode.psk31.displayName, "PSK31")
        XCTAssertEqual(DigitalMode.bpsk63.displayName, "BPSK63")
        XCTAssertEqual(DigitalMode.qpsk31.displayName, "QPSK31")
        XCTAssertEqual(DigitalMode.qpsk63.displayName, "QPSK63")
        XCTAssertEqual(DigitalMode.olivia.displayName, "Olivia 8/250")
    }

    func testCenterFrequencies() {
        XCTAssertEqual(DigitalMode.rtty.centerFrequency, 2125.0)
        XCTAssertEqual(DigitalMode.psk31.centerFrequency, 1000.0)
        XCTAssertEqual(DigitalMode.bpsk63.centerFrequency, 1000.0)
        XCTAssertEqual(DigitalMode.qpsk31.centerFrequency, 1000.0)
        XCTAssertEqual(DigitalMode.qpsk63.centerFrequency, 1000.0)
        XCTAssertEqual(DigitalMode.olivia.centerFrequency, 1500.0)
    }

    func testIdentifiable() {
        XCTAssertEqual(DigitalMode.rtty.id, "RTTY")
        XCTAssertEqual(DigitalMode.psk31.id, "PSK31")
        XCTAssertEqual(DigitalMode.bpsk63.id, "BPSK63")
        XCTAssertEqual(DigitalMode.qpsk31.id, "QPSK31")
        XCTAssertEqual(DigitalMode.qpsk63.id, "QPSK63")
        XCTAssertEqual(DigitalMode.olivia.id, "Olivia")
    }

    func testCodable() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for mode in DigitalMode.allCases {
            let data = try encoder.encode(mode)
            let decoded = try decoder.decode(DigitalMode.self, from: data)
            XCTAssertEqual(decoded, mode)
        }
    }
}
