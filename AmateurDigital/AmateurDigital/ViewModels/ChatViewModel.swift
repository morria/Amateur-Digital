//
//  ChatViewModel.swift
//  DigiModes
//

import Foundation
import SwiftUI
import Combine
import AVFoundation
import UIKit

@MainActor
class ChatViewModel: ObservableObject {
    // MARK: - Published Properties

    /// Per-mode channel storage - each mode has its own independent channel list
    @Published private var channelsByMode: [DigitalMode: [Channel]] = [:]

    /// Computed property to access channels for the current mode
    /// This is the primary interface for views to access channels
    var channels: [Channel] {
        get { channelsByMode[selectedMode] ?? [] }
        set { channelsByMode[selectedMode] = newValue }
    }

    /// Get channels for a specific mode (used by ChannelListContainer)
    func channels(for mode: DigitalMode) -> [Channel] {
        channelsByMode[mode] ?? []
    }

    @Published var selectedMode: DigitalMode = .rtty {
        didSet {
            if oldValue != selectedMode {
                modemService.setMode(selectedMode)
                // Each mode has its own channel list via channelsByMode
            }
        }
    }
    @Published var isTransmitting: Bool = false
    @Published var isListening: Bool = false
    @Published var audioError: String?
    @Published var frequencyWarning: String?

    // MARK: - Services
    private let audioService: AudioService
    private let modemService: ModemService
    private var settingsCancellables = Set<AnyCancellable>()

    // MARK: - Constants
    private let defaultComposeFrequency = 1500

    /// Safe audio frequency range for USB transmission (Hz)
    /// Below 300 Hz risks being filtered by radio, above 2700 Hz exceeds USB passband
    static let minSafeFrequency = 400
    static let maxSafeFrequency = 2600

    /// Timeout for grouping incoming messages (seconds)
    /// Only create a new received message after this much silence
    private let messageGroupTimeout: TimeInterval = 60.0

    /// Per-mode decode tracking state
    /// Each mode maintains its own decode state independently

    /// Last decode time per frequency per mode (for detecting silence gaps)
    private var lastDecodeTimeByMode: [DigitalMode: [Double: Date]] = [:]

    /// Last time content was added to a received message per frequency per mode
    /// Used to determine when to start a new message vs append
    private var lastReceivedContentTimeByMode: [DigitalMode: [Double: Date]] = [:]

    /// Mode being used for current decoding buffer per frequency per mode
    private var decodingModeByMode: [DigitalMode: [Double: DigitalMode]] = [:]

    // Convenience accessors for current mode's decode state
    private var lastDecodeTime: [Double: Date] {
        get { lastDecodeTimeByMode[selectedMode] ?? [:] }
        set { lastDecodeTimeByMode[selectedMode] = newValue }
    }

    private var lastReceivedContentTime: [Double: Date] {
        get { lastReceivedContentTimeByMode[selectedMode] ?? [:] }
        set { lastReceivedContentTimeByMode[selectedMode] = newValue }
    }

    private var decodingMode: [Double: DigitalMode] {
        get { decodingModeByMode[selectedMode] ?? [:] }
        set { decodingModeByMode[selectedMode] = newValue }
    }

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

        // Watch for RTTY settings changes and reconfigure modem
        let settings = SettingsManager.shared
        Publishers.Merge4(
            settings.$rttyBaudRate.map { _ in () },
            settings.$rttyMarkFreq.map { _ in () },
            settings.$rttyShift.map { _ in () },
            settings.$psk31CenterFreq.map { _ in () }
        )
        .dropFirst()  // Skip initial values
        .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
        .sink { [weak self] _ in
            self?.modemService.reconfigureModem()
        }
        .store(in: &settingsCancellables)

        // Watch for squelch changes separately (lighter update)
        Publishers.Merge(
            settings.$rttySquelch.map { _ in () },
            settings.$psk31Squelch.map { _ in () }
        )
        .dropFirst()
        .debounce(for: .milliseconds(100), scheduler: RunLoop.main)
        .sink { [weak self] _ in
            self?.modemService.updateSquelch()
        }
        .store(in: &settingsCancellables)

        // Start audio service
        Task {
            await startAudioService()
        }
    }

    deinit {
        // Ensure idle timer is re-enabled when view model is deallocated
        // Must dispatch to main thread since deinit may run on any thread
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    /// Start or restart the audio service
    func startAudioService() async {
        do {
            try await audioService.start()
            isListening = audioService.isListening
            audioError = nil

            // Prevent device from sleeping while listening
            if isListening {
                UIApplication.shared.isIdleTimerDisabled = true
                print("[ChatViewModel] Audio service started, listening: \(isListening), idle timer disabled")
            }
        } catch {
            let errorMsg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            audioError = errorMsg
            print("[ChatViewModel] Failed to start audio: \(errorMsg)")
        }
    }

    /// Stop listening (audio input) - called when returning to mode selection
    func stopListening() {
        audioService.stop()
        isListening = false

        // Re-enable idle timer when not listening
        UIApplication.shared.isIdleTimerDisabled = false
        print("[ChatViewModel] Audio service stopped, idle timer enabled")
    }

    // MARK: - Transmission State
    private var currentTransmissionChannelIndex: Int?
    private var currentTransmissionMessageIndex: Int?

    // MARK: - Public Methods

    /// Check if a frequency is within safe USB passband for transmission
    func isFrequencySafeForTransmission(_ frequency: Int) -> Bool {
        return frequency >= Self.minSafeFrequency && frequency <= Self.maxSafeFrequency
    }

    /// Get a warning message if frequency is outside safe range
    func frequencyWarningMessage(for frequency: Int) -> String? {
        if frequency < Self.minSafeFrequency {
            return String(localized: "Frequency \(frequency) Hz is too low. Signal may be filtered by radio. Use \(Self.minSafeFrequency)+ Hz.")
        } else if frequency > Self.maxSafeFrequency {
            return String(localized: "Frequency \(frequency) Hz exceeds USB passband. Use below \(Self.maxSafeFrequency) Hz.")
        }
        return nil
    }

    func sendMessage(_ content: String, toChannel channel: Channel) {
        guard let index = channels.firstIndex(where: { $0.id == channel.id }) else { return }

        // Validate frequency is within safe transmission range
        let freq = channels[index].frequency
        if let warning = frequencyWarningMessage(for: freq) {
            frequencyWarning = warning
            print("[ChatViewModel] Blocked transmission: \(warning)")
            return
        }
        frequencyWarning = nil

        // RTTY is uppercase-only (Baudot limitation), PSK-31 preserves case
        let messageContent = selectedMode == .rtty ? content.uppercased() : content

        let message = Message(
            content: messageContent,
            direction: .sent,
            mode: selectedMode,
            callsign: Station.myStation.callsign,
            transmitState: .queued
        )

        channels[index].messages.append(message)
        channels[index].lastActivity = Date()

        // Clear received content time so next incoming content starts a new message
        lastReceivedContentTime[Double(channels[index].frequency)] = nil

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

    /// Clear all channels and reset decode state for the current mode
    func clearAllChannels() {
        channelsByMode[selectedMode] = []
        lastDecodeTimeByMode[selectedMode] = [:]
        lastReceivedContentTimeByMode[selectedMode] = [:]
        decodingModeByMode[selectedMode] = [:]
    }

    /// Clear channels for a specific mode
    func clearChannels(for mode: DigitalMode) {
        channelsByMode[mode] = []
        lastDecodeTimeByMode[mode] = [:]
        lastReceivedContentTimeByMode[mode] = [:]
        decodingModeByMode[mode] = [:]
    }

    /// Get or create a compose channel for new messages
    /// Returns an existing empty channel (no messages or decoding buffer) to avoid
    /// stepping on existing conversations. Creates a new channel at 1500 Hz if needed.
    func getOrCreateComposeChannel() -> Channel {
        // First, look for an existing channel with no content
        if let emptyChannel = channels.first(where: { !$0.hasContent }) {
            return emptyChannel
        }

        // All channels have content - create a new one at default frequency
        // If 1500 Hz is taken, find the next available frequency
        var frequency = defaultComposeFrequency
        while channels.contains(where: { abs($0.frequency - frequency) < 10 }) {
            frequency += 200  // Step to next standard frequency spacing
        }

        // Get initial squelch from global settings (convert 0.0-1.0 to 0-100)
        let settings = SettingsManager.shared
        let initialSquelch: Int
        switch selectedMode {
        case .rtty:
            initialSquelch = Int(settings.rttySquelch * 100)
        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            initialSquelch = Int(settings.psk31Squelch * 100)
        case .olivia:
            initialSquelch = 0
        }

        let newChannel = Channel(
            frequency: frequency,
            callsign: nil,
            messages: [],
            lastActivity: Date(),
            squelch: initialSquelch
        )
        channels.insert(newChannel, at: 0)
        return newChannel
    }

    // MARK: - Private Methods

    private func transmitMessage(at messageIndex: Int, inChannelAt channelIndex: Int) {
        guard channelIndex < channels.count,
              messageIndex < channels[channelIndex].messages.count else { return }

        let text = channels[channelIndex].messages[messageIndex].content
        let frequency = channels[channelIndex].frequency

        // Track current transmission
        currentTransmissionChannelIndex = channelIndex
        currentTransmissionMessageIndex = messageIndex

        Task {
            // Mark as transmitting
            channels[channelIndex].messages[messageIndex].transmitState = .transmitting
            isTransmitting = true

            do {
                try await performTransmission(text: text, atFrequency: frequency)
                // Mark as sent (only if not cancelled)
                if isTransmitting {
                    channels[channelIndex].messages[messageIndex].transmitState = .sent
                }
            } catch AudioServiceError.playbackCancelled {
                print("[ChatViewModel] Transmission cancelled")
                // State already set by stopTransmission
            } catch {
                let errorDesc = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                print("[ChatViewModel] Transmission failed: \(errorDesc)")
                channels[channelIndex].messages[messageIndex].transmitState = .failed
                channels[channelIndex].messages[messageIndex].errorMessage = errorDesc
            }

            isTransmitting = false
            currentTransmissionChannelIndex = nil
            currentTransmissionMessageIndex = nil
        }
    }

    private func performTransmission(text: String, atFrequency frequency: Int) async throws {
        // Get TX preamble setting
        let preambleMs = SettingsManager.shared.txPreambleMs
        let freq = Double(frequency)

        // Encode text to audio samples via modem service at channel frequency
        let messageSamples = modemService.encodeTxSamples(text, atFrequency: freq)
        guard !messageSamples.isEmpty else {
            print("[ChatViewModel] Modem encoding failed - DigiModesCore may not be linked")
            throw AudioServiceError.encodingFailed
        }

        // Combine preamble + message into single buffer for gapless playback
        var combinedSamples: [Float]
        if preambleMs > 0, let preamble = modemService.generatePreamble(durationMs: preambleMs, atFrequency: freq) {
            combinedSamples = preamble + messageSamples
            print("[ChatViewModel] TX at \(frequency) Hz with \(preambleMs)ms preamble: \(preamble.count) + \(messageSamples.count) = \(combinedSamples.count) samples")
        } else {
            combinedSamples = messageSamples
            print("[ChatViewModel] Encoded \(text.count) chars at \(frequency) Hz -> \(combinedSamples.count) samples")
        }

        // Create audio buffer from combined samples
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        ),
        let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(combinedSamples.count)
        ) else {
            print("[ChatViewModel] Failed to create audio buffer")
            throw AudioServiceError.encodingFailed
        }

        buffer.frameLength = AVAudioFrameCount(combinedSamples.count)
        if let channelData = buffer.floatChannelData?[0] {
            for (index, sample) in combinedSamples.enumerated() {
                channelData[index] = sample
            }
        }

        // Apply output gain from settings
        audioService.outputGain = Float(SettingsManager.shared.outputGain)
        // Play the audio buffer
        try await audioService.playBuffer(buffer)
        print("[ChatViewModel] Playback complete")
    }

    // MARK: - Channel Management for RX

    /// Get or create a channel at the given frequency for a specific mode
    private func getOrCreateChannel(at frequency: Double, for mode: DigitalMode) -> Int {
        var modeChannels = channelsByMode[mode] ?? []

        // Find existing channel within ±10 Hz
        if let index = modeChannels.firstIndex(where: { abs($0.frequency - Int(frequency)) < 10 }) {
            return index
        }

        // Get initial squelch from global settings (convert 0.0-1.0 to 0-100)
        let settings = SettingsManager.shared
        let initialSquelch: Int
        switch mode {
        case .rtty:
            initialSquelch = Int(settings.rttySquelch * 100)
        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            initialSquelch = Int(settings.psk31Squelch * 100)
        case .olivia:
            initialSquelch = 0
        }

        // Create new channel with initial squelch from global settings
        let newChannel = Channel(
            frequency: Int(frequency),
            callsign: nil,
            messages: [],
            lastActivity: Date(),
            squelch: initialSquelch
        )
        modeChannels.append(newChannel)
        channelsByMode[mode] = modeChannels
        return modeChannels.count - 1
    }

    /// Flush accumulated decoded text to a message for a specific mode
    /// Appends to the last received message if within timeout and no sent message since
    private func flushDecodedBuffer(for frequency: Double, mode: DigitalMode) {
        let channelIndex = getOrCreateChannel(at: frequency, for: mode)
        var modeChannels = channelsByMode[mode] ?? []

        guard channelIndex < modeChannels.count else { return }

        let text = modeChannels[channelIndex].decodingBuffer

        guard !text.isEmpty else { return }

        // Trim whitespace and control characters
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: .controlCharacters)
        guard !trimmedText.isEmpty else {
            modeChannels[channelIndex].decodingBuffer = ""
            channelsByMode[mode] = modeChannels
            return
        }

        let now = Date()

        // Get mode-specific tracking data
        let modeLastReceivedContentTime = lastReceivedContentTimeByMode[mode] ?? [:]
        var modeDecodingMode = decodingModeByMode[mode] ?? [:]

        // Check if we can append to the last received message:
        // - Last message must be received (not sent by user)
        // - Must be within the timeout since last received content
        let canAppend: Bool
        if let lastMessageIndex = modeChannels[channelIndex].messages.indices.last,
           modeChannels[channelIndex].messages[lastMessageIndex].direction == .received {
            // Check time since last content was added (not message creation time)
            if let lastContentTime = modeLastReceivedContentTime[frequency] {
                canAppend = now.timeIntervalSince(lastContentTime) < messageGroupTimeout
            } else {
                // No previous content time, use message timestamp as fallback
                canAppend = now.timeIntervalSince(modeChannels[channelIndex].messages[lastMessageIndex].timestamp) < messageGroupTimeout
            }
        } else {
            canAppend = false
        }

        // Use the mode that was active during decoding
        let messageMode = modeDecodingMode[frequency] ?? mode

        if canAppend,
           let lastMessageIndex = modeChannels[channelIndex].messages.indices.last {
            // Append to existing received message
            modeChannels[channelIndex].messages[lastMessageIndex].content += trimmedText
            print("[ChatViewModel] RX appended on \(Int(frequency)) Hz (\(messageMode.rawValue)): \(trimmedText)")
        } else {
            // Create new received message
            let message = Message(
                content: trimmedText,
                direction: .received,
                mode: messageMode,
                callsign: nil,  // TODO: Extract callsign from text
                transmitState: nil
            )
            modeChannels[channelIndex].messages.append(message)
            print("[ChatViewModel] RX message on \(Int(frequency)) Hz (\(messageMode.rawValue)): \(trimmedText)")
        }

        // Clear the decoding mode after flushing
        modeDecodingMode[frequency] = nil
        decodingModeByMode[mode] = modeDecodingMode

        // Track when content was last added
        var updatedLastReceivedContentTime = lastReceivedContentTimeByMode[mode] ?? [:]
        updatedLastReceivedContentTime[frequency] = now
        lastReceivedContentTimeByMode[mode] = updatedLastReceivedContentTime

        modeChannels[channelIndex].lastActivity = now

        // Clear buffer
        modeChannels[channelIndex].decodingBuffer = ""
        channelsByMode[mode] = modeChannels

        var modeLastDecodeTime = lastDecodeTimeByMode[mode] ?? [:]
        modeLastDecodeTime[frequency] = nil
        lastDecodeTimeByMode[mode] = modeLastDecodeTime
    }
}

// MARK: - ModemServiceDelegate

extension ChatViewModel: ModemServiceDelegate {
    nonisolated func modemService(
        _ service: ModemService,
        didDecode character: Character,
        onChannel frequency: Double,
        mode: DigitalMode,
        signalStrength: Float
    ) {
        Task { @MainActor in
            handleDecodedCharacter(character, onChannel: frequency, mode: mode, signalStrength: signalStrength)
        }
    }

    nonisolated func modemService(
        _ service: ModemService,
        signalDetected: Bool,
        onChannel frequency: Double,
        mode: DigitalMode
    ) {
        Task { @MainActor in
            // When signal is lost, flush any buffered content
            if !signalDetected {
                flushDecodedBuffer(for: frequency, mode: mode)
            }
        }
    }

    /// Handle decoded character on main actor
    /// The mode parameter specifies which decoder produced this character
    /// signalStrength is used for per-channel squelch filtering (0.0-1.0)
    private func handleDecodedCharacter(_ character: Character, onChannel frequency: Double, mode: DigitalMode, signalStrength: Float) {
        let channelIndex = getOrCreateChannel(at: frequency, for: mode)
        let now = Date()

        // Get the channel to check per-channel squelch
        let modeChannels = channelsByMode[mode] ?? []
        if channelIndex < modeChannels.count {
            let channel = modeChannels[channelIndex]
            // Per-channel squelch: channel.squelch is 0-100, signalStrength is 0.0-1.0
            // If squelch is 50, we need signalStrength >= 0.5 to decode
            let squelchThreshold = Float(channel.squelch) / 100.0
            if signalStrength < squelchThreshold {
                // Signal below per-channel squelch threshold, ignore this character
                return
            }
        }

        // Get mode-specific tracking data
        let modeLastDecodeTime = lastDecodeTimeByMode[mode] ?? [:]
        let modeDecodingMode = decodingModeByMode[mode] ?? [:]

        // Check if we should flush previous content (long silence or mode change)
        let shouldFlush: Bool
        if let lastTime = modeLastDecodeTime[frequency],
           now.timeIntervalSince(lastTime) > messageGroupTimeout {
            shouldFlush = true
        } else if let currentMode = modeDecodingMode[frequency], currentMode != mode {
            // Mode changed - flush previous content
            shouldFlush = true
        } else {
            shouldFlush = false
        }

        if shouldFlush {
            flushDecodedBuffer(for: frequency, mode: mode)
        }

        // Track the mode for this decoding session
        var updatedDecodingMode = decodingModeByMode[mode] ?? [:]
        updatedDecodingMode[frequency] = mode
        decodingModeByMode[mode] = updatedDecodingMode

        // Accumulate character in mode's channel decoding buffer
        var updatedModeChannels = channelsByMode[mode] ?? []
        if channelIndex < updatedModeChannels.count {
            updatedModeChannels[channelIndex].decodingBuffer.append(character)
            updatedModeChannels[channelIndex].lastActivity = now
            channelsByMode[mode] = updatedModeChannels
        }

        // Update last decode time
        var updatedLastDecodeTime = lastDecodeTimeByMode[mode] ?? [:]
        updatedLastDecodeTime[frequency] = now
        lastDecodeTimeByMode[mode] = updatedLastDecodeTime
    }
}
