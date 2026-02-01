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
            // Top row: frequency offset and time
            HStack {
                Text(channel.frequencyOffsetDisplay)
                    .font(.headline)

                Spacer()

                Text(timeAgoText)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Preview text
            Text(channel.previewText)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
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
