//
//  ChatView.swift
//  DigiModes
//
//  Note: This view is deprecated. Use ChannelDetailView instead.
//

import SwiftUI

struct ChatView: View {
    let channel: Channel

    var body: some View {
        VStack(spacing: 0) {
            MessageListView(messages: channel.messages)

            Divider()

            MessageInputView(channel: channel)
        }
        .background(Color(.systemBackground))
    }
}

#Preview {
    ChatView(channel: Channel.sampleChannels[0])
}
