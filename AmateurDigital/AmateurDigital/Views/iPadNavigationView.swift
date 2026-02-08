//
//  iPadNavigationView.swift
//  AmateurDigital
//
//  iPad three-column layout using NavigationSplitView
//

import SwiftUI

struct iPadNavigationView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var selectedMode: DigitalMode?
    @State private var selectedChannel: Channel?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showingSettings = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Sidebar: Mode selection (vertical list)
            ModeSidebarView(selectedMode: $selectedMode)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
        } content: {
            // Content: Channel list for selected mode
            if let mode = selectedMode {
                iPadChannelListView(mode: mode, selectedChannel: $selectedChannel)
            } else {
                ContentUnavailableView(
                    "Select a Mode",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Choose a digital mode from the sidebar to start listening.")
                )
            }
        } detail: {
            // Detail: Messages for selected channel
            if let channel = selectedChannel {
                ChannelDetailView(channel: channel)
            } else if selectedMode != nil {
                ContentUnavailableView(
                    "Select a Channel",
                    systemImage: "bubble.left.and.bubble.right",
                    description: Text("Choose a channel to view the conversation.")
                )
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "antenna.radiowaves.left.and.right",
                    description: Text("Select a mode and channel to begin.")
                )
            }
        }
        .navigationSplitViewStyle(.balanced)
        .sheet(isPresented: $showingSettings) {
            SettingsView(chatViewModel: viewModel, filterMode: selectedMode)
        }
        .onChange(of: selectedMode) { oldMode, newMode in
            // Clear channel selection when mode changes
            if oldMode != newMode {
                selectedChannel = nil
            }

            // Update viewModel mode and start/stop listening
            if let mode = newMode {
                if viewModel.selectedMode != mode {
                    viewModel.selectedMode = mode
                }
                if !viewModel.isListening {
                    Task {
                        await viewModel.startAudioService()
                    }
                }
            } else {
                viewModel.stopListening()
            }
        }
    }
}

// MARK: - iPad Channel List View

/// Channel list view adapted for iPad with selection binding
struct iPadChannelListView: View {
    let mode: DigitalMode
    @Binding var selectedChannel: Channel?
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var channelForSettings: Channel?
    @State private var showingSettings = false

    var body: some View {
        let visibleChannels = viewModel.channels.filter { $0.hasContent }
        Group {
            if visibleChannels.isEmpty {
                VStack(spacing: 16) {
                    if viewModel.isListening {
                        viewModel.selectedMode.iconImage
                            .font(.system(size: 48))
                            .foregroundColor(viewModel.selectedMode.color)
                        Text("Listening...")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text("No signals decoded yet. Monitoring for \(viewModel.selectedMode.displayName) transmissions.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    } else if let error = viewModel.audioError {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)
                        Text("Audio Error")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Button("Retry") {
                            Task {
                                await viewModel.startAudioService()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
                    } else {
                        viewModel.selectedMode.iconImage
                            .font(.system(size: 48))
                            .foregroundColor(viewModel.selectedMode.color.opacity(0.5))
                        Text("Starting...")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text("Initializing \(viewModel.selectedMode.displayName) decoder...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleChannels.sorted { $0.frequency < $1.frequency }, selection: $selectedChannel) { channel in
                    ChannelRowView(channel: channel)
                        .tag(channel)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                if selectedChannel?.id == channel.id {
                                    selectedChannel = nil
                                }
                                viewModel.deleteChannel(channel)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                channelForSettings = channel
                            } label: {
                                Label("Settings", systemImage: "slider.horizontal.3")
                            }
                            .tint(.gray)
                        }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(mode.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(mode.displayName)
                        .font(.headline)
                    Text(mode.subtitle)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            ToolbarItemGroup(placement: .topBarTrailing) {
                // Compose button
                Button {
                    let channel = viewModel.getOrCreateComposeChannel()
                    selectedChannel = channel
                } label: {
                    Image(systemName: "square.and.pencil")
                }

                Button {
                    viewModel.clearAllChannels()
                    selectedChannel = nil
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
        .sheet(item: $channelForSettings) { channel in
            ChannelSettingsSheet(channel: channel, viewModel: viewModel)
                .id(channel.id)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(chatViewModel: viewModel, filterMode: mode)
        }
    }
}

#Preview {
    iPadNavigationView()
        .environmentObject(ChatViewModel())
}
