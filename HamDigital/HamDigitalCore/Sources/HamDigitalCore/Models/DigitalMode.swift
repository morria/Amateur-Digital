//
//  DigitalMode.swift
//  DigiModesCore
//

import Foundation

public enum DigitalMode: String, CaseIterable, Identifiable, Codable {
    case rtty = "RTTY"
    case psk31 = "PSK31"
    case bpsk63 = "BPSK63"
    case qpsk31 = "QPSK31"
    case qpsk63 = "QPSK63"
    case olivia = "Olivia"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .rtty: return "RTTY (45.45 Baud)"
        case .psk31: return "PSK31"
        case .bpsk63: return "BPSK63"
        case .qpsk31: return "QPSK31"
        case .qpsk63: return "QPSK63"
        case .olivia: return "Olivia 8/250"
        }
    }

    public var description: String {
        switch self {
        case .rtty:
            return "Radio Teletype - Classic 5-bit Baudot code"
        case .psk31:
            return "Phase Shift Keying - Keyboard-to-keyboard QSOs"
        case .bpsk63:
            return "BPSK at 62.5 baud - 2x speed of PSK31"
        case .qpsk31:
            return "Quadrature PSK - 2x throughput of PSK31"
        case .qpsk63:
            return "Quadrature PSK at 62.5 baud - 4x throughput"
        case .olivia:
            return "Olivia MFSK - Excellent weak signal performance"
        }
    }

    public var centerFrequency: Double {
        switch self {
        case .rtty: return 2125.0   // Standard RTTY mark frequency
        case .psk31: return 1000.0  // Typical PSK31 audio frequency
        case .bpsk63: return 1000.0 // Same as PSK31
        case .qpsk31: return 1000.0 // Same as PSK31
        case .qpsk63: return 1000.0 // Same as PSK31
        case .olivia: return 1500.0 // Olivia center frequency
        }
    }

    /// Whether this is a PSK mode
    public var isPSKMode: Bool {
        switch self {
        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            return true
        case .rtty, .olivia:
            return false
        }
    }

    /// Get PSK configuration for PSK modes, nil for non-PSK modes
    public var pskConfiguration: PSKConfiguration? {
        switch self {
        case .psk31: return .psk31
        case .bpsk63: return .bpsk63
        case .qpsk31: return .qpsk31
        case .qpsk63: return .qpsk63
        case .rtty, .olivia: return nil
        }
    }
}
