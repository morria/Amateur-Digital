//
//  ChannelListView.swift
//  DigiModes
//
//  List of all detected channels with navigation to detail
//

import SwiftUI

struct ChannelListView: View {
    @EnvironmentObject var viewModel: ChatViewModel

    var body: some View {
        Group {
            if viewModel.channels.isEmpty {
                VStack(spacing: 16) {
                    if viewModel.isListening {
                        // Actively listening
                        Image(systemName: "waveform")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Listening...")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text("No signals decoded yet. Monitoring audio input for RTTY transmissions.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    } else {
                        // Not listening yet
                        Image(systemName: "waveform.slash")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("Not Listening")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text("Audio service starting...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                List {
                    ForEach(viewModel.channels) { channel in
                        NavigationLink(value: channel) {
                            ChannelRowView(channel: channel)
                        }
                    }
                    .onDelete(perform: deleteChannels)
                }
                .listStyle(.plain)
            }
        }
        .navigationDestination(for: Channel.self) { channel in
            ChannelDetailView(channel: channel)
        }
    }

    private func deleteChannels(at offsets: IndexSet) {
        viewModel.deleteChannels(at: offsets)
    }
}

#Preview {
    NavigationStack {
        ChannelListView()
            .environmentObject(ChatViewModel())
    }
}
