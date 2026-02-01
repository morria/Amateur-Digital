//
//  ContentView.swift
//  DigiModes
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var showingSettings = false
    @State private var navigateToCompose: Channel?

    var body: some View {
        NavigationStack {
            ChannelListView()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ModePickerView()
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            navigateToCompose = viewModel.getOrCreateComposeChannel()
                        } label: {
                            Image(systemName: "square.and.pencil")
                        }

                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
            .navigationDestination(item: $navigateToCompose) { channel in
                ChannelDetailView(channel: channel)
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ChatViewModel())
}
