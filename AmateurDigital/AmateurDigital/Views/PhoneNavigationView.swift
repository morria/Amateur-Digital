//
//  PhoneNavigationView.swift
//  AmateurDigital
//
//  iPhone navigation using NavigationStack (unchanged from original behavior)
//

import SwiftUI

struct PhoneNavigationView: View {
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
                                if mode == .cw {
                                    // CW: single conversation — skip channel list,
                                    // go directly to the one shared CW channel.
                                    viewModel.selectedMode = .cw
                                    Task { await viewModel.startAudioService() }
                                    let channel = viewModel.getOrCreateComposeChannel()
                                    navigationPath.append(channel)
                                } else if mode == .ft8 {
                                    // FT8: dedicated QSO view with auto-sequencing
                                    viewModel.selectedMode = .ft8
                                    Task { await viewModel.startAudioService() }
                                    navigationPath.append("ft8qso")
                                } else {
                                    navigationPath.append(mode)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)

                    // Detect Mode button
                    Button {
                        navigationPath.append("modeDetection")
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "waveform.badge.magnifyingglass")
                                .font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Detect Mode")
                                    .font(.headline)
                                Text("Listen and identify the signal")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(.systemBackground))
                                .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 4)
                        )
                    }
                    .buttonStyle(.plain)
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
            .navigationDestination(for: String.self) { value in
                if value == "modeDetection" {
                    ModeDetectionView(navigationPath: $navigationPath)
                } else if value == "ft8qso" {
                    FT8QSOView(viewModel: FT8QSOViewModel(
                        theirCallsign: "",
                        theirGrid: "",
                        myCallsign: SettingsManager.shared.callsign,
                        myGrid: String(SettingsManager.shared.effectiveGrid.prefix(4))
                    ))
                }
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

#Preview {
    PhoneNavigationView()
        .environmentObject(ChatViewModel())
}
