//
//  MessageBubbleView.swift
//  DigiModes
//

import SwiftUI

struct MessageBubbleView: View {
    let message: Message
    let revealedTimestamp: Bool

    private var isReceived: Bool {
        message.direction == .received
    }

    private var bubbleColor: Color {
        if isReceived {
            return Color(.systemGray5)
        }
        // Sent messages color based on transmit state
        switch message.transmitState {
        case .queued:
            return Color(.systemGray4)
        case .transmitting:
            return Color.orange
        case .sent, .none:
            return Color.blue
        case .failed:
            return Color.red
        }
    }

    private var textColor: Color {
        isReceived ? Color.primary : Color.white
    }

    @ViewBuilder
    private var statusIndicator: some View {
        if !isReceived, let state = message.transmitState, state != .sent {
            HStack(spacing: 4) {
                Spacer()
                switch state {
                case .queued:
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                case .transmitting:
                    ProgressView()
                        .scaleEffect(0.6)
                case .failed:
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption2)
                            .foregroundColor(.red)
                        if let error = message.errorMessage {
                            Text(error)
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                    }
                case .sent:
                    EmptyView()
                }
            }
            .padding(.trailing, 8)
        }
    }

    /// Whether this is a CW message with a frequency label (stored in callsign field)
    private var isCWFrequencyLabel: Bool {
        message.mode == .cw && isReceived && message.callsign?.hasSuffix("Hz") == true
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            // Callsign label for received messages (not shown for CW frequency labels —
            // CW shows frequency below the bubble instead)
            if isReceived, let callsign = message.callsign, !callsign.isEmpty, !isCWFrequencyLabel {
                HStack {
                    Text(callsign)
                        .font(.caption)
                        .bold()
                        .foregroundColor(.secondary)
                    Spacer()
                }
            }

            HStack(spacing: 8) {
                // Timestamp (revealed on swipe)
                if revealedTimestamp {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }

                if !isReceived && !revealedTimestamp {
                    Spacer(minLength: 60)
                }

                // Message bubble with optional CW frequency label below
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.content)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(bubbleColor)
                        .foregroundColor(textColor)
                        .clipShape(RoundedRectangle(cornerRadius: 18))
                        .contextMenu {
                            Button {
                                UIPasteboard.general.string = message.content
                            } label: {
                                Label("Copy", systemImage: "doc.on.doc")
                            }
                        }

                    // CW frequency offset — tiny gray text below the bubble
                    if isCWFrequencyLabel, let freqLabel = message.callsign {
                        Text(freqLabel)
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                            .padding(.leading, 14)
                    }
                }

                if isReceived && !revealedTimestamp {
                    Spacer(minLength: 60)
                }
            }

            statusIndicator
        }
    }
}

#Preview {
    VStack(spacing: 12) {
        MessageBubbleView(message: Message.sampleMessages[0], revealedTimestamp: false)
        MessageBubbleView(message: Message.sampleMessages[1], revealedTimestamp: false)

        Divider()
        Text("With timestamps revealed:").font(.caption)

        MessageBubbleView(message: Message.sampleMessages[0], revealedTimestamp: true)
        MessageBubbleView(message: Message.sampleMessages[1], revealedTimestamp: true)
    }
    .padding()
}
