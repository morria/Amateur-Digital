//
//  Station.swift
//  DigiModesCore
//

import Foundation

public struct Station: Identifiable, Codable, Equatable {
    public let id: UUID
    public var callsign: String
    public var name: String
    public var qth: String  // Location
    public var grid: String // Maidenhead grid square

    public init(
        id: UUID = UUID(),
        callsign: String = "",
        name: String = "",
        qth: String = "",
        grid: String = ""
    ) {
        self.id = id
        self.callsign = callsign
        self.name = name
        self.qth = qth
        self.grid = grid
    }

    public static let placeholder = Station(
        callsign: "N0CALL",
        name: "Your Name",
        qth: "Your City, ST",
        grid: "DM79"
    )
}
