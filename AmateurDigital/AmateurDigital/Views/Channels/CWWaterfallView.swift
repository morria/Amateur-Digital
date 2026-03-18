//
//  CWWaterfallView.swift
//  Amateur Digital
//
//  Single-pane CW decode view where all signals appear in one scrolling stream.
//  Signals >= 50 Hz apart are considered different speakers and get different
//  colored backgrounds. Replaces the per-frequency channel list for CW mode.
//

import SwiftUI

struct CWWaterfallView: View {
    @EnvironmentObject var viewModel: ChatViewModel

    /// Group channels by frequency proximity (50 Hz threshold)
    private var speakerGroups: [SpeakerGroup] {
        let channels = viewModel.channels
            .filter { $0.hasContent }
            .sorted { $0.frequency < $1.frequency }

        var groups: [SpeakerGroup] = []

        for channel in channels {
            if let lastGroup = groups.last,
               abs(channel.frequency - lastGroup.centerFrequency) < 50 {
                // Merge into existing group
                groups[groups.count - 1].channels.append(channel)
            } else {
                // New speaker group
                groups.append(SpeakerGroup(channels: [channel]))
            }
        }

        return groups
    }

    /// All decoded segments sorted by time, with speaker color
    private var decodedSegments: [DecodedSegment] {
        let colors = speakerColors
        var segments: [DecodedSegment] = []

        for (groupIndex, group) in speakerGroups.enumerated() {
            let color = colors[groupIndex % colors.count]
            for channel in group.channels {
                // Add flushed messages
                for message in channel.messages where message.direction == .received {
                    if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        segments.append(DecodedSegment(
                            text: message.content,
                            frequency: channel.frequency,
                            callsign: channel.callsign,
                            color: color,
                            time: message.timestamp,
                            isLive: false
                        ))
                    }
                }
                // Add live decoding buffer
                if !channel.decodingBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    segments.append(DecodedSegment(
                        text: channel.decodingBuffer,
                        frequency: channel.frequency,
                        callsign: channel.callsign,
                        color: color,
                        time: channel.lastActivity,
                        isLive: true
                    ))
                }
            }
        }

        return segments.sorted { $0.time < $1.time }
    }

    private let speakerColors: [Color] = [
        .blue, .green, .orange, .purple, .pink, .teal, .red, .indigo, .mint, .cyan
    ]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if decodedSegments.isEmpty {
                        emptyState
                    } else {
                        ForEach(Array(decodedSegments.enumerated()), id: \.offset) { index, segment in
                            segmentView(segment)
                                .id(index)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: decodedSegments.count) { _, _ in
                // Auto-scroll to bottom
                if let last = decodedSegments.indices.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: DecodedSegment) -> some View {
        HStack(alignment: .top, spacing: 6) {
            // Frequency / callsign label
            VStack(alignment: .trailing, spacing: 0) {
                if let callsign = segment.callsign {
                    Text(callsign)
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundColor(segment.color)
                } else {
                    Text("\(segment.frequency) Hz")
                        .font(.caption2)
                        .foregroundColor(segment.color)
                }
            }
            .frame(width: 60, alignment: .trailing)

            // Decoded text with colored background
            Text(segment.text)
                .font(.system(.body, design: .monospaced))
                .foregroundColor(.primary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(segment.color.opacity(segment.isLive ? 0.20 : 0.10))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(segment.isLive ? segment.color.opacity(0.4) : .clear, lineWidth: 1)
                )
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "dot.radiowaves.right")
                .font(.system(size: 48))
                .foregroundColor(.secondary.opacity(0.5))
            Text("Listening for CW signals...")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("Decoded Morse code will appear here.\nDifferent stations are shown in different colors.")
                .font(.caption)
                .foregroundColor(.secondary.opacity(0.7))
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 100)
    }
}

// MARK: - Models

private struct SpeakerGroup {
    var channels: [Channel]
    var centerFrequency: Int {
        guard !channels.isEmpty else { return 0 }
        return channels.map(\.frequency).reduce(0, +) / channels.count
    }
}

private struct DecodedSegment {
    let text: String
    let frequency: Int
    let callsign: String?
    let color: Color
    let time: Date
    let isLive: Bool
}
