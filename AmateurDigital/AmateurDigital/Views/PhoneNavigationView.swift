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

#Preview {
    PhoneNavigationView()
        .environmentObject(ChatViewModel())
}
