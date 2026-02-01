//
//  DigitalMode.swift
//  DigiModes
//

import Foundation

enum DigitalMode: String, CaseIterable, Identifiable {
    case rtty = "RTTY"
    case psk31 = "PSK31"
    case olivia = "Olivia"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rtty: return "RTTY (45.45 Baud)"
        case .psk31: return "PSK31"
        case .olivia: return "Olivia 8/250"
        }
    }

    var description: String {
        switch self {
        case .rtty:
            return "Radio Teletype - Classic 5-bit Baudot code"
        case .psk31:
            return "Phase Shift Keying - Keyboard-to-keyboard QSOs"
        case .olivia:
            return "Olivia MFSK - Excellent weak signal performance"
        }
    }

    var centerFrequency: Double {
        switch self {
        case .rtty: return 2125.0   // Standard RTTY mark frequency
        case .psk31: return 1000.0  // Typical PSK31 audio frequency
        case .olivia: return 1500.0 // Olivia center frequency
        }
    }
}
