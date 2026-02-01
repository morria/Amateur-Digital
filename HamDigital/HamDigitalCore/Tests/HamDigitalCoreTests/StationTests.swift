//
//  StationTests.swift
//  DigiModesCoreTests
//

import XCTest
@testable import HamDigitalCore

final class StationTests: XCTestCase {

    func testStationCreation() {
        let station = Station(
            callsign: "W1AW",
            name: "Hiram",
            qth: "Newington, CT",
            grid: "FN31"
        )

        XCTAssertEqual(station.callsign, "W1AW")
        XCTAssertEqual(station.name, "Hiram")
        XCTAssertEqual(station.qth, "Newington, CT")
        XCTAssertEqual(station.grid, "FN31")
    }

    func testStationDefaults() {
        let station = Station()

        XCTAssertEqual(station.callsign, "")
        XCTAssertEqual(station.name, "")
        XCTAssertEqual(station.qth, "")
        XCTAssertEqual(station.grid, "")
    }

    func testPlaceholderStation() {
        let placeholder = Station.placeholder

        XCTAssertEqual(placeholder.callsign, "N0CALL")
        XCTAssertEqual(placeholder.name, "Your Name")
        XCTAssertEqual(placeholder.qth, "Your City, ST")
        XCTAssertEqual(placeholder.grid, "DM79")
    }

    func testStationEquality() {
        let id = UUID()
        let station1 = Station(id: id, callsign: "W1AW", name: "Hiram", qth: "CT", grid: "FN31")
        let station2 = Station(id: id, callsign: "W1AW", name: "Hiram", qth: "CT", grid: "FN31")

        XCTAssertEqual(station1, station2)
    }

    func testStationCodable() throws {
        let original = Station(
            callsign: "K1ABC",
            name: "John",
            qth: "Boston, MA",
            grid: "FN42"
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Station.self, from: data)

        XCTAssertEqual(decoded.callsign, original.callsign)
        XCTAssertEqual(decoded.name, original.name)
        XCTAssertEqual(decoded.qth, original.qth)
        XCTAssertEqual(decoded.grid, original.grid)
    }

    func testStationMutability() {
        var station = Station(callsign: "N0CALL")

        station.callsign = "W1AW"
        station.name = "Hiram"
        station.qth = "Newington, CT"
        station.grid = "FN31"

        XCTAssertEqual(station.callsign, "W1AW")
        XCTAssertEqual(station.name, "Hiram")
        XCTAssertEqual(station.qth, "Newington, CT")
        XCTAssertEqual(station.grid, "FN31")
    }
}
