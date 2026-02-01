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
        let visibleChannels = viewModel.channels.filter { $0.hasContent }
        Group {
            if visibleChannels.isEmpty {
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
                    } else if let error = viewModel.audioError {
                        // Audio error
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(visibleChannels.sorted { $0.frequency < $1.frequency }) { channel in
                        NavigationLink(value: channel) {
                            ChannelRowView(channel: channel)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationDestination(for: Channel.self) { channel in
            ChannelDetailView(channel: channel)
        }
    }
}

#Preview {
    NavigationStack {
        ChannelListView()
            .environmentObject(ChatViewModel())
    }
}
