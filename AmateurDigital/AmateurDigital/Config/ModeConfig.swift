//
//  ModeConfig.swift
//  Amateur Digital
//
//  Configuration for enabling/disabling digital modes
//

import Foundation

/// Configuration for which digital modes are enabled in the app.
/// Disabled modes won't appear in the mode picker or settings.
enum ModeConfig {
    /// Set of enabled digital modes
    static let enabledModes: Set<DigitalMode> = [
        .rtty,
        .psk31,
        // .bpsk63,   // Not yet ready
        // .qpsk31,   // Not yet ready
        // .qpsk63,   // Not yet ready
        // .olivia,   // Not yet implemented
    ]

    /// Check if a specific mode is enabled
    static func isEnabled(_ mode: DigitalMode) -> Bool {
        enabledModes.contains(mode)
    }

    /// Get all enabled modes (preserves CaseIterable order)
    static var allEnabledModes: [DigitalMode] {
        DigitalMode.allCases.filter { enabledModes.contains($0) }
    }
}
