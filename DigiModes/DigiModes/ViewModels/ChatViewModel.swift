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
    @Published var isListening: Bool = false

    // MARK: - Services
    private let audioService: AudioService
    private let modemService: ModemService

    // MARK: - Constants
    private let defaultComposeFrequency = 1500

    /// Timeout for grouping characters into messages (seconds)
    private let messageGroupTimeout: TimeInterval = 2.0

    /// Last decode time per frequency
    private var lastDecodeTime: [Double: Date] = [:]

    /// Test audio processing state
    @Published var isProcessingTestAudio: Bool = false
    @Published var testAudioProgress: Double = 0

    // MARK: - Initialization
    init() {
        self.audioService = AudioService()
        self.modemService = ModemService()

        // Set up modem delegate
        modemService.delegate = self

        // Wire up audio input to modem
        audioService.onAudioInput = { [weak self] samples in
            self?.modemService.processRxSamples(samples)
        }

        // Start audio service
        Task {
            do {
                try await audioService.start()
                isListening = audioService.isListening
                print("[ChatViewModel] Audio service started, listening: \(isListening)")
            } catch {
                print("[ChatViewModel] Failed to start audio: \(error)")
            }
        }
    }

    // MARK: - Transmission State
    private var currentTransmissionChannelIndex: Int?
    private var currentTransmissionMessageIndex: Int?

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

    /// Stop current transmission
    func stopTransmission() {
        print("[ChatViewModel] Stopping transmission")
        audioService.stopPlayback()

        // Mark current message as failed
        if let channelIndex = currentTransmissionChannelIndex,
           let messageIndex = currentTransmissionMessageIndex,
           channelIndex < channels.count,
           messageIndex < channels[channelIndex].messages.count {
            channels[channelIndex].messages[messageIndex].transmitState = .failed
        }

        isTransmitting = false
        currentTransmissionChannelIndex = nil
        currentTransmissionMessageIndex = nil
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

    // MARK: - Test Audio Processing

    /// Process a test audio file through the demodulation pipeline
    /// - Parameter path: Path to the WAV file
    func processTestAudioFile(at path: String) {
        guard !isProcessingTestAudio else {
            print("[ChatViewModel] Already processing test audio")
            return
        }

        guard let samples = TestAudioLoader.loadWAV(from: path) else {
            print("[ChatViewModel] Failed to load test audio from: \(path)")
            return
        }

        processTestSamples(samples)
    }

    /// Process test samples through the demodulation pipeline
    /// Simulates real-time audio by processing in chunks
    private func processTestSamples(_ samples: [Float]) {
        isProcessingTestAudio = true
        testAudioProgress = 0

        // Process in chunks to simulate real-time audio input
        let chunkSize = 4096  // Same as AudioService input tap
        let totalChunks = (samples.count + chunkSize - 1) / chunkSize

        // Calculate delay between chunks to simulate real-time (48kHz)
        // 4096 samples at 48kHz = ~85ms per chunk
        let chunkDuration: TimeInterval = Double(chunkSize) / 48000.0

        Task {
            for chunkIndex in 0..<totalChunks {
                let start = chunkIndex * chunkSize
                let end = min(start + chunkSize, samples.count)
                let chunk = Array(samples[start..<end])

                // Process chunk through modem service
                modemService.processRxSamples(chunk)

                // Update progress
                testAudioProgress = Double(chunkIndex + 1) / Double(totalChunks)

                // Simulate real-time timing (can be adjusted for faster processing)
                try? await Task.sleep(for: .milliseconds(Int(chunkDuration * 1000 * 0.1)))  // 10x speed
            }

            // Flush any remaining buffered content
            for frequency in lastDecodeTime.keys {
                flushDecodedBuffer(for: frequency)
            }

            isProcessingTestAudio = false
            testAudioProgress = 1.0
            print("[ChatViewModel] Test audio processing complete")
        }
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

        // Track current transmission
        currentTransmissionChannelIndex = channelIndex
        currentTransmissionMessageIndex = messageIndex

        Task {
            // Mark as transmitting
            channels[channelIndex].messages[messageIndex].transmitState = .transmitting
            isTransmitting = true

            do {
                try await performTransmission(text: text)
                // Mark as sent (only if not cancelled)
                if isTransmitting {
                    channels[channelIndex].messages[messageIndex].transmitState = .sent
                }
            } catch AudioServiceError.playbackCancelled {
                print("[ChatViewModel] Transmission cancelled")
                // State already set by stopTransmission
            } catch {
                print("[ChatViewModel] Transmission failed: \(error)")
                channels[channelIndex].messages[messageIndex].transmitState = .failed
            }

            isTransmitting = false
            currentTransmissionChannelIndex = nil
            currentTransmissionMessageIndex = nil
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

    // MARK: - Channel Management for RX

    /// Get or create a channel at the given frequency
    private func getOrCreateChannel(at frequency: Double) -> Int {
        // Find existing channel within ±10 Hz
        if let index = channels.firstIndex(where: { abs($0.frequency - Int(frequency)) < 10 }) {
            return index
        }

        // Create new channel
        let newChannel = Channel(
            frequency: Int(frequency),
            callsign: nil,
            messages: [],
            lastActivity: Date()
        )
        channels.append(newChannel)
        return channels.count - 1
    }

    /// Flush accumulated decoded text to a message
    private func flushDecodedBuffer(for frequency: Double) {
        let channelIndex = getOrCreateChannel(at: frequency)
        let text = channels[channelIndex].decodingBuffer

        guard !text.isEmpty else { return }

        // Create received message
        let message = Message(
            content: text.trimmingCharacters(in: .whitespacesAndNewlines),
            direction: .received,
            mode: selectedMode,
            callsign: nil,  // TODO: Extract callsign from text
            transmitState: nil
        )

        channels[channelIndex].messages.append(message)
        channels[channelIndex].lastActivity = Date()

        // Clear buffer
        channels[channelIndex].decodingBuffer = ""
        lastDecodeTime[frequency] = nil

        print("[ChatViewModel] RX message on \(Int(frequency)) Hz: \(message.content)")
    }
}

// MARK: - ModemServiceDelegate

extension ChatViewModel: ModemServiceDelegate {
    nonisolated func modemService(
        _ service: ModemService,
        didDecode character: Character,
        onChannel frequency: Double
    ) {
        Task { @MainActor in
            handleDecodedCharacter(character, onChannel: frequency)
        }
    }

    nonisolated func modemService(
        _ service: ModemService,
        signalDetected: Bool,
        onChannel frequency: Double
    ) {
        Task { @MainActor in
            // When signal is lost, flush any buffered content
            if !signalDetected {
                flushDecodedBuffer(for: frequency)
            }
        }
    }

    /// Handle decoded character on main actor
    private func handleDecodedCharacter(_ character: Character, onChannel frequency: Double) {
        let channelIndex = getOrCreateChannel(at: frequency)
        let now = Date()

        // Check if we should flush previous content (timeout)
        if let lastTime = lastDecodeTime[frequency],
           now.timeIntervalSince(lastTime) > messageGroupTimeout {
            // Flush old buffer first, then start new
            let oldText = channels[channelIndex].decodingBuffer
            channels[channelIndex].decodingBuffer = String(character)
            if oldText.count > 1 {
                // Create message from old buffer (without the new char we just added)
                let trimmed = String(oldText.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    let message = Message(
                        content: trimmed,
                        direction: .received,
                        mode: selectedMode,
                        callsign: nil,
                        transmitState: nil
                    )
                    channels[channelIndex].messages.append(message)
                    print("[ChatViewModel] RX message on \(Int(frequency)) Hz: \(trimmed)")
                }
            }
        } else {
            // Accumulate character in channel's decoding buffer
            channels[channelIndex].decodingBuffer.append(character)
        }

        lastDecodeTime[frequency] = now
        channels[channelIndex].lastActivity = now
    }
}
