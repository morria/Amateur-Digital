//
//  ChannelDetailView.swift
//  DigiModes
//
//  Full conversation view for a single channel
//

import SwiftUI

struct ChannelDetailView: View {
    let channelID: UUID
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var messageText = ""
    @State private var dragOffset: CGFloat = 0
    @State private var showTimestamps = false
    @FocusState private var isTextFieldFocused: Bool

    private let timestampRevealThreshold: CGFloat = 60

    /// Look up the current channel from viewModel to get live updates
    private var channel: Channel? {
        viewModel.channels.first { $0.id == channelID }
    }

    init(channel: Channel) {
        self.channelID = channel.id
    }

    var body: some View {
        if let channel = channel {
            VStack(spacing: 0) {
                // Message list
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 8) {
                            ForEach(channel.messages) { message in
                                MessageBubbleView(
                                    message: message,
                                    revealedTimestamp: showTimestamps
                                )
                                .id(message.id)
                                .offset(x: dragOffset)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                if value.translation.width < 0 {
                                    dragOffset = value.translation.width / 3
                                    showTimestamps = abs(dragOffset) > timestampRevealThreshold / 3
                                }
                            }
                            .onEnded { _ in
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    dragOffset = 0
                                    showTimestamps = false
                                }
                            }
                    )
                    .onChange(of: channel.messages.count) { _, _ in
                        if let lastMessage = channel.messages.last {
                            withAnimation(.easeOut(duration: 0.3)) {
                                proxy.scrollTo(lastMessage.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                // Input bar
                VStack(spacing: 0) {
                    if viewModel.isTransmitting {
                        HStack {
                            Circle()
                                .fill(Color.red)
                                .frame(width: 8, height: 8)
                            Text("TRANSMITTING")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.red)
                            Spacer()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.red.opacity(0.1))
                    }

                    HStack(spacing: 12) {
                        TextField("Enter message...", text: $messageText, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.system(.body, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray6))
                            .cornerRadius(20)
                            .lineLimit(1...5)
                            .focused($isTextFieldFocused)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled(true)

                        Button {
                            if viewModel.isTransmitting {
                                viewModel.stopTransmission()
                            } else {
                                sendMessage()
                            }
                        } label: {
                            Image(systemName: viewModel.isTransmitting ? "stop.fill" : "arrow.up.circle.fill")
                                .font(.system(size: 32))
                                .foregroundColor(
                                    viewModel.isTransmitting ? .red :
                                    (messageText.isEmpty ? .gray : .blue)
                                )
                        }
                        .disabled(messageText.isEmpty && !viewModel.isTransmitting)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle(channel.frequencyOffsetDisplay)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView("Channel Deleted", systemImage: "trash")
        }
    }

    private func sendMessage() {
        guard !messageText.isEmpty, let channel = channel else { return }
        viewModel.sendMessage(messageText, toChannel: channel)
        messageText = ""
        isTextFieldFocused = false
    }
}

#Preview {
    NavigationStack {
        ChannelDetailView(channel: Channel.sampleChannels[0])
            .environmentObject(ChatViewModel())
    }
}
