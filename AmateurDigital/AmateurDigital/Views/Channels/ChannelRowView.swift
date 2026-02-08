//
//  ChannelRowView.swift
//  DigiModes
//
//  Single row in the channel list showing preview
//

import SwiftUI

struct ChannelRowView: View {
    let channel: Channel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Top row: callsign/frequency, classification indicator, and time
            HStack {
                if let callsign = channel.callsign {
                    Text(callsign)
                        .font(.headline)
                        .bold()
                    Text(channel.frequencyOffsetDisplay)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    Text(channel.frequencyOffsetDisplay)
                        .font(.headline)
                }

                if let isLegitimate = channel.isLikelyLegitimate {
                    if isLegitimate, (channel.classificationConfidence ?? 0) > 0.7 {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.subheadline)
                    } else {
                        Image(systemName: "questionmark.circle")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }

                Spacer()

                Text(timeAgoText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Preview text (latest tail of decoded text, up to 2 lines)
            if !channel.previewText.isEmpty {
                Text(channel.previewText)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }

    private var timeAgoText: String {
        let seconds = channel.timeSinceActivity

        if seconds < 60 {
            return "\(Int(seconds))s ago"
        } else if seconds < 3600 {
            return "\(Int(seconds / 60))m ago"
        } else {
            return "\(Int(seconds / 3600))h ago"
        }
    }
}

#Preview {
    List {
        ChannelRowView(channel: Channel.sampleChannels[0])
        ChannelRowView(channel: Channel.sampleChannels[1])
        ChannelRowView(channel: Channel.sampleChannels[2])
    }
}
