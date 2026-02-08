//
//  DigitalMode.swift
//  DigiModes
//

import Foundation
import SwiftUI

enum DigitalMode: String, CaseIterable, Identifiable {
    case rtty = "RTTY"
    case psk31 = "PSK31"
    case bpsk63 = "BPSK63"
    case qpsk31 = "QPSK31"
    case qpsk63 = "QPSK63"
    case olivia = "Olivia"
    case rattlegram = "Rattlegram"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .rtty: return "RTTY"
        case .psk31: return "PSK31"
        case .bpsk63: return "BPSK63"
        case .qpsk31: return "QPSK31"
        case .qpsk63: return "QPSK63"
        case .olivia: return "Olivia"
        case .rattlegram: return "Rattlegram"
        }
    }

    var subtitle: String {
        switch self {
        case .rtty: return "45.45 Baud"
        case .psk31: return "31.25 Baud"
        case .bpsk63: return "62.5 Baud"
        case .qpsk31: return "31.25 Baud"
        case .qpsk63: return "62.5 Baud"
        case .olivia: return "8/250"
        case .rattlegram: return "OFDM 170B/1s"
        }
    }

    var description: String {
        switch self {
        case .rtty:
            return String(localized: "Classic radio teletype using 5-bit Baudot code. Robust and widely used.")
        case .psk31:
            return String(localized: "Narrowband PSK for keyboard-to-keyboard chats. Very efficient.")
        case .bpsk63:
            return String(localized: "Faster PSK mode at 2x speed. Good for stronger signals.")
        case .qpsk31:
            return String(localized: "Four-phase PSK with 2x throughput. Better for good conditions.")
        case .qpsk63:
            return String(localized: "Fastest PSK variant at 4x throughput. Best signal required.")
        case .olivia:
            return String(localized: "Multi-tone MFSK with excellent weak signal performance.")
        case .rattlegram:
            return String(localized: "OFDM burst mode with polar codes. Sends up to 170 bytes in ~1 second.")
        }
    }

    var centerFrequency: Double {
        switch self {
        case .rtty: return 2125.0   // Standard RTTY mark frequency
        case .psk31: return 1000.0  // Typical PSK31 audio frequency
        case .bpsk63: return 1000.0 // Same as PSK31
        case .qpsk31: return 1000.0 // Same as PSK31
        case .qpsk63: return 1000.0 // Same as PSK31
        case .olivia: return 1500.0 // Olivia center frequency
        case .rattlegram: return 1500.0 // OFDM carrier frequency
        }
    }

    /// Whether this is a PSK mode
    var isPSKMode: Bool {
        switch self {
        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            return true
        case .rtty, .olivia, .rattlegram:
            return false
        }
    }

    /// SF Symbol icon for the mode
    var iconName: String {
        switch self {
        case .rtty:
            return "teletype"
        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            return "waveform.path"
        case .olivia:
            return "waveform"
        case .rattlegram:
            return "bolt.horizontal"
        }
    }

    /// Icon view — uses emoji for rattlegram, SF Symbol for others
    @ViewBuilder
    var iconImage: some View {
        if self == .rattlegram {
            Text("🐍")
        } else {
            Image(systemName: iconName)
        }
    }

    /// Color associated with the mode
    var color: Color {
        switch self {
        case .rtty:
            return .orange
        case .psk31:
            return .blue
        case .bpsk63:
            return .cyan
        case .qpsk31:
            return .purple
        case .qpsk63:
            return .indigo
        case .olivia:
            return .green
        case .rattlegram:
            return .teal
        }
    }
}
