//
//  ChatViewModel.swift
//  DigiModes
//

import Foundation
import SwiftUI
import Combine

@MainActor
class ChatViewModel: ObservableObject {
    // MARK: - Published Properties
    @Published var channels: [Channel] = []
    @Published var selectedMode: DigitalMode = .rtty
    @Published var isTransmitting: Bool = false

    // MARK: - Services
    private let audioService: AudioService
    private let modemService: ModemService

    // MARK: - Constants
    private let defaultComposeFrequency = 1500

    // MARK: - Initialization
    init() {
        self.audioService = AudioService()
        self.modemService = ModemService()

        // Start audio service
        Task {
            do {
                try await audioService.start()
                print("[ChatViewModel] Audio service started")
            } catch {
                print("[ChatViewModel] Failed to start audio: \(error)")
            }
        }
    }

    // MARK: - Public Methods

    func sendMessage(_ content: String, toChannel channel: Channel) {
        guard let index = channels.firstIndex(where: { $0.id == channel.id }) else { return }

        let message = Message(
            content: content.uppercased(),
            direction: .sent,
            mode: selectedMode,
            callsign: Station.myStation.callsign,
            transmitState: .queued
        )

        channels[index].messages.append(message)
        channels[index].lastActivity = Date()

        // Start transmission
        transmitMessage(at: channels[index].messages.count - 1, inChannelAt: index)
    }

    func clearChannel(_ channel: Channel) {
        guard let index = channels.firstIndex(where: { $0.id == channel.id }) else { return }
        channels[index].messages.removeAll()
    }

    func deleteChannels(at offsets: IndexSet) {
        channels.remove(atOffsets: offsets)
    }

    func deleteChannel(_ channel: Channel) {
        channels.removeAll { $0.id == channel.id }
    }

    /// Get or create a compose channel at 1500 Hz
    /// Returns existing channel at 1500 Hz if one exists, otherwise creates a new one
    func getOrCreateComposeChannel() -> Channel {
        // First, look for an existing channel at the default frequency
        if let existingChannel = channels.first(where: { $0.frequency == defaultComposeFrequency }) {
            return existingChannel
        }

        // No channel at default frequency - create one
        let newChannel = Channel(
            frequency: defaultComposeFrequency,
            callsign: nil,
            messages: [],
            lastActivity: Date()
        )
        channels.insert(newChannel, at: 0)
        return newChannel
    }

    // MARK: - Private Methods

    private func transmitMessage(at messageIndex: Int, inChannelAt channelIndex: Int) {
        guard channelIndex < channels.count,
              messageIndex < channels[channelIndex].messages.count else { return }

        let text = channels[channelIndex].messages[messageIndex].content

        Task {
            // Mark as transmitting
            channels[channelIndex].messages[messageIndex].transmitState = .transmitting
            isTransmitting = true

            do {
                try await performTransmission(text: text)
                // Mark as sent
                channels[channelIndex].messages[messageIndex].transmitState = .sent
            } catch {
                print("[ChatViewModel] Transmission failed: \(error)")
                channels[channelIndex].messages[messageIndex].transmitState = .failed
            }

            isTransmitting = false
        }
    }

    private func performTransmission(text: String) async throws {
        // Encode text to audio samples via modem service
        if let buffer = modemService.encodeTxText(text) {
            print("[ChatViewModel] Encoded \(text.count) chars -> \(buffer.frameLength) samples")
            // Play the audio buffer
            try await audioService.playBuffer(buffer)
            print("[ChatViewModel] Playback complete")
        } else {
            print("[ChatViewModel] Modem encoding failed - DigiModesCore may not be linked")
            throw AudioServiceError.formatError
        }
    }
}
