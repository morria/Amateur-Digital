//
//  ModeSidebarView.swift
//  AmateurDigital
//
//  Vertical list of modes for iPad sidebar
//

import SwiftUI

struct ModeSidebarView: View {
    @Binding var selectedMode: DigitalMode?
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        List(ModeConfig.allEnabledModes, selection: $selectedMode) { mode in
            ModeRowView(mode: mode, settings: settings)
                .tag(mode)
        }
        .navigationTitle("Modes")
    }
}

// MARK: - Mode Row View

struct ModeRowView: View {
    let mode: DigitalMode
    @ObservedObject var settings: SettingsManager

    private var subtitleText: String {
        switch mode {
        case .rtty:
            if settings.rttyBaudRate == 45.45 {
                return String(localized: "45.45 Baud")
            } else {
                return String(localized: "\(Int(settings.rttyBaudRate)) Baud")
            }
        default:
            return mode.subtitle
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(mode.color.opacity(0.15))
                    .frame(width: 36, height: 36)

                Image(systemName: mode.iconName)
                    .font(.system(size: 16))
                    .foregroundColor(mode.color)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(mode.displayName)
                    .font(.body)
                    .fontWeight(.medium)

                Text(subtitleText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if mode.isPSKMode {
                Text("PSK")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(mode.color.opacity(0.15))
                    .foregroundColor(mode.color)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        ModeSidebarView(selectedMode: .constant(.rtty))
    }
}
