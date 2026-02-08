//
//  ModeConfig.swift
//  Amateur Digital
//
//  Configuration for enabling/disabling digital modes
//

import Foundation

/// Configuration for which digital modes are enabled in the app.
/// Core modes (RTTY, PSK31) are always enabled.
/// Experimental modes can be toggled in Settings.
enum ModeConfig {
    /// Core modes that are always available
    static let coreModes: Set<DigitalMode> = [
        .rtty,
        .psk31,
    ]

    /// Experimental modes that can be toggled by the user
    static let experimentalModes: Set<DigitalMode> = [
        .bpsk63,
        .qpsk31,
        .qpsk63,
        .rattlegram,
    ]

    /// Check if a specific mode is enabled
    @MainActor static func isEnabled(_ mode: DigitalMode) -> Bool {
        if coreModes.contains(mode) { return true }

        let settings = SettingsManager.shared
        switch mode {
        case .bpsk63: return settings.enableBPSK63
        case .qpsk31: return settings.enableQPSK31
        case .qpsk63: return settings.enableQPSK63
        case .rattlegram: return settings.enableRattlegram
        default: return false
        }
    }

    /// Get all enabled modes (preserves CaseIterable order)
    @MainActor static var allEnabledModes: [DigitalMode] {
        DigitalMode.allCases.filter { isEnabled($0) }
    }

    /// Whether a mode is experimental
    static func isExperimental(_ mode: DigitalMode) -> Bool {
        experimentalModes.contains(mode)
    }
}
