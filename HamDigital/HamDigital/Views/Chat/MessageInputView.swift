//
//  MessageInputView.swift
//  DigiModes
//
//  Note: This view is deprecated. Use ChannelDetailView instead.
//

import SwiftUI

struct MessageInputView: View {
    let channel: Channel
    var onSend: (String) -> Void = { _ in }
    @State private var messageText = ""
    @FocusState private var isTextFieldFocused: Bool
    var isTransmitting: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            // Transmit status indicator
            if isTransmitting {
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

            // Input bar
            HStack(spacing: 12) {
                // Text input field
                TextField("Enter message...", text: $messageText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.systemGray6))
                    .cornerRadius(20)
                    .lineLimit(1...5)
                    .focused($isTextFieldFocused)
                    .textInputAutocapitalization(.characters) // Ham radio convention
                    .autocorrectionDisabled(true)

                // Transmit button
                Button {
                    transmitMessage()
                } label: {
                    Image(systemName: isTransmitting ? "stop.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(
                            isTransmitting ? .red :
                            (messageText.isEmpty ? .gray : .blue)
                        )
                }
                .disabled(messageText.isEmpty && !isTransmitting)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.systemBackground))
        }
    }

    private func transmitMessage() {
        guard !messageText.isEmpty else { return }

        onSend(messageText)
        messageText = ""
        isTextFieldFocused = false
    }
}

#Preview {
    VStack {
        Spacer()
        MessageInputView(channel: Channel.sampleChannels[0])
    }
}
