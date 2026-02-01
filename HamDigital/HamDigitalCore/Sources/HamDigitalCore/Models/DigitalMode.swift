//
//  DigitalMode.swift
//  DigiModesCore
//

import Foundation

public enum DigitalMode: String, CaseIterable, Identifiable, Codable {
    case rtty = "RTTY"
    case psk31 = "PSK31"
    case olivia = "Olivia"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rtty: return "RTTY (45.45 Baud)"
        case .psk31: return "PSK31"
        case .olivia: return "Olivia 8/250"
        }
    }

    public var description: String {
        switch self {
        case .rtty:
            return "Radio Teletype - Classic 5-bit Baudot code"
        case .psk31:
            return "Phase Shift Keying - Keyboard-to-keyboard QSOs"
        case .olivia:
            return "Olivia MFSK - Excellent weak signal performance"
        }
    }

    public var centerFrequency: Double {
        switch self {
        case .rtty: return 2125.0   // Standard RTTY mark frequency
        case .psk31: return 1000.0  // Typical PSK31 audio frequency
        case .olivia: return 1500.0 // Olivia center frequency
        }
    }
}
