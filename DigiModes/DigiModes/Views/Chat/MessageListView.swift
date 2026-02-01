//
//  MessageListView.swift
//  DigiModes
//
//  Note: This view is deprecated. Use ChannelDetailView instead.
//

import SwiftUI

struct MessageListView: View {
    let messages: [Message]
    @State private var dragOffset: CGFloat = 0
    @State private var showTimestamps: Bool = false

    // How far to drag before timestamps appear
    private let timestampRevealThreshold: CGFloat = 60

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(messages) { message in
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
                        // Only allow dragging left (negative x)
                        if value.translation.width < 0 {
                            dragOffset = value.translation.width / 3 // Dampen the drag
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
            .onChange(of: messages.count) { _, _ in
                // Auto-scroll to newest message
                if let lastMessage = messages.last {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

#Preview {
    MessageListView(messages: Channel.sampleChannels[0].messages)
}
