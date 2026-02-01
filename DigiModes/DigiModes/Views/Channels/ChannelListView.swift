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
                ContentUnavailableView {
                    Label("No Channels", systemImage: "waveform")
                } description: {
                    Text("Tap the compose button to start a new transmission.")
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
