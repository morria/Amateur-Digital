//
//  Station.swift
//  DigiModes
//

import Foundation

struct Station: Identifiable {
    let id: UUID
    var callsign: String
    var name: String
    var qth: String  // Location
    var grid: String // Maidenhead grid square

    init(
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

    /// Returns the current station info from SettingsManager
    @MainActor
    static var myStation: Station {
        let settings = SettingsManager.shared
        return Station(
            callsign: settings.callsign,
            name: settings.operatorName,
            qth: settings.effectiveQTH,
            grid: settings.effectiveGrid
        )
    }
}
