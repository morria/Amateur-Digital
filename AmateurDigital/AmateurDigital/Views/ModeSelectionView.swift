//
//  ModeSelectionView.swift
//  AmateurDigital
//
//  Mode selection screen - the first view users see
//

import SwiftUI

struct ModeSelectionView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @ObservedObject private var settings = SettingsManager.shared
    @State private var navigationPath = NavigationPath()
    @State private var showingSettings = false

    private let columns = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        NavigationStack(path: $navigationPath) {
            ScrollView {
                VStack(spacing: 24) {
                    // Header
                    VStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .font(.system(size: 48))
                            .foregroundStyle(.blue.gradient)

                        Text("Select Mode")
                            .font(.largeTitle)
                            .fontWeight(.bold)

                        Text("Choose a digital mode to start listening")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.top, 20)

                    // Mode cards grid
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(ModeConfig.allEnabledModes) { mode in
                            ModeCard(mode: mode, isSelected: false) {
                                navigationPath.append(mode)
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    Spacer(minLength: 40)
                }
            }
            .background(Color(.systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(chatViewModel: viewModel, filterMode: nil)
            }
            .navigationDestination(for: DigitalMode.self) { mode in
                ChannelListContainer(mode: mode, navigationPath: $navigationPath)
            }
            .navigationDestination(for: Channel.self) { channel in
                ChannelDetailView(channel: channel)
            }
            .onAppear {
                // When returning to mode selection, stop listening
                viewModel.stopListening()
            }
        }
    }
}

// MARK: - Mode Card

struct ModeCard: View {
    let mode: DigitalMode
    let isSelected: Bool
    let onTap: () -> Void
    @ObservedObject private var settings = SettingsManager.shared

    /// Subtitle showing configured baud rate for modes with adjustable settings
    private var subtitleText: String {
        switch mode {
        case .rtty:
            // RTTY baud rate is configurable
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
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                // Icon and badge
                HStack {
                    ZStack {
                        Circle()
                            .fill(mode.color.opacity(0.15))
                            .frame(width: 50, height: 50)

                        mode.iconImage
                            .font(.system(size: 22))
                            .foregroundColor(mode.color)
                    }

                    Spacer()

                    if ModeConfig.isExperimental(mode) {
                        Text("BETA")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.orange.opacity(0.15))
                            .foregroundColor(.orange)
                            .clipShape(Capsule())
                    } else if mode.isPSKMode {
                        Text("PSK")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(mode.color.opacity(0.15))
                            .foregroundColor(mode.color)
                            .clipShape(Capsule())
                    }
                }

                // Title and subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.displayName)
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)

                    Text(subtitleText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Description
                Text(mode.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(isSelected ? mode.color : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Channel List Container

/// Container view that sets the mode and presents the channel list
struct ChannelListContainer: View {
    let mode: DigitalMode
    @Binding var navigationPath: NavigationPath
    @EnvironmentObject var viewModel: ChatViewModel
    @ObservedObject private var settings = SettingsManager.shared
    @State private var showingSettings = false

    /// Subtitle showing configured baud rate for modes with adjustable settings
    private var baudRateSubtitle: String {
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
        ChannelListView()
            .overlay(alignment: .bottomTrailing) {
                // Compose button - creates channel and navigates
                Button {
                    let channel = viewModel.getOrCreateComposeChannel()
                    navigationPath.append(channel)
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .frame(width: 56, height: 56)
                        .background(mode.color)
                        .clipShape(Circle())
                        .shadow(radius: 4)
                }
                .padding(.trailing, 20)
                .padding(.bottom, 20)
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text(mode.displayName)
                            .font(.headline)
                        Text(baudRateSubtitle)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        viewModel.clearAllChannels()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(viewModel.channels.filter { $0.hasContent }.isEmpty)

                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(chatViewModel: viewModel, filterMode: mode)
            }
            .onAppear {
                // Set the mode when this view appears
                if viewModel.selectedMode != mode {
                    viewModel.selectedMode = mode
                }
                // Start listening when entering this mode
                if !viewModel.isListening {
                    Task {
                        await viewModel.startAudioService()
                    }
                }
            }
    }
}

// MARK: - Previews

#Preview("Mode Selection") {
    ModeSelectionView()
        .environmentObject(ChatViewModel())
}

#Preview("Mode Card") {
    ModeCard(mode: .psk31, isSelected: false) {}
        .padding()
        .background(Color(.systemGroupedBackground))
}
