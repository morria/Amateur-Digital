//
//  ChatViewModel.swift
//  DigiModes
//

import Foundation
import SwiftUI
import Combine
import AVFoundation
import UIKit
import HamTextClassifier
import CallsignExtractor

#if canImport(AmateurDigitalCore)
import AmateurDigitalCore
#endif

#if canImport(ModeClassifierModel)
import ModeClassifierModel
#endif

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
    @Published var draftMessages: [UUID: String] = [:]
    @Published var inputLevel: Float = 0
    @Published private(set) var lastReadDates: [UUID: Date] = [:]

    // MARK: - Mode Detection
    @Published var modeDetectionResult: ModeDetectionResult?
    @Published var isModeDetectionActive: Bool = false
    private var modeDetector: ModeDetector?
    private var modeDetectionTimer: Timer?
    private let modeDetectionBuffer = AudioSampleBuffer()
    private let mlClassifier: ModeClassifierML? = try? ModeClassifierML()

    // MARK: - Services
    private let audioService: AudioService
    private let modemService: ModemService
    private let textClassifier: HamTextClassifier?
    private let callsignExtractor: CallsignExtractor?
    private var settingsCancellables = Set<AnyCancellable>()
    private var levelTimer: Timer?
    private var transmissionTimedOut = false

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
        self.textClassifier = try? HamTextClassifier()
        self.callsignExtractor = try? CallsignExtractor()

        // Set up modem delegate
        modemService.delegate = self

        // Wire up audio input to modem DSP queue (NOT main thread)
        audioService.onAudioInput = { [weak self] samples in
            self?.modemService.feedSamples(samples)
        }

        // Watch for RTTY settings changes and reconfigure modem
        let settings = SettingsManager.shared
        Publishers.MergeMany([
            settings.$rttyBaudRate.map { _ in () }.eraseToAnyPublisher(),
            settings.$rttyMarkFreq.map { _ in () }.eraseToAnyPublisher(),
            settings.$rttyShift.map { _ in () }.eraseToAnyPublisher(),
            settings.$psk31CenterFreq.map { _ in () }.eraseToAnyPublisher(),
            settings.$rttyPolarityInverted.map { _ in () }.eraseToAnyPublisher(),
            settings.$rttyFrequencyOffset.map { _ in () }.eraseToAnyPublisher(),
        ])
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
        levelTimer?.invalidate()
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
                startLevelTimer()
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
        levelTimer?.invalidate()
        levelTimer = nil
        inputLevel = 0

        // Re-enable idle timer when not listening
        UIApplication.shared.isIdleTimerDisabled = false
        print("[ChatViewModel] Audio service stopped, idle timer enabled")
    }

    /// Periodically read input level from audio service for UI display
    private func startLevelTimer() {
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.inputLevel = self?.audioService.inputLevel ?? 0
            }
        }
    }

    // MARK: - Mode Detection

    /// Start mode detection: begins listening for audio and periodically classifying the signal
    func startModeDetection() async {
        isModeDetectionActive = true
        modeDetector = ModeDetector(sampleRate: 48000)
        modeDetectionBuffer.clear()
        modeDetectionResult = nil

        // Ensure audio is running
        if !isListening {
            do {
                try await audioService.start()
                isListening = audioService.isListening
                audioError = nil
                if isListening {
                    UIApplication.shared.isIdleTimerDisabled = true
                }
            } catch {
                audioError = error.localizedDescription
                isModeDetectionActive = false
                return
            }
        }

        // Temporarily add our buffer collector to the audio callback
        let modemSvc = modemService
        let buffer = modeDetectionBuffer
        audioService.onAudioInput = { samples in
            // Still feed the modem DSP queue
            modemSvc.feedSamples(samples)
            // Also buffer for mode detection
            buffer.append(samples)
        }

        // Run detection every 1 second
        modeDetectionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.runModeDetection()
            }
        }
    }

    /// Stop mode detection and restore normal audio callback
    func stopModeDetection() {
        isModeDetectionActive = false
        modeDetectionTimer?.invalidate()
        modeDetectionTimer = nil
        modeDetector = nil

        // Restore the standard audio callback
        audioService.onAudioInput = { [weak self] samples in
            self?.modemService.feedSamples(samples)
        }

        modeDetectionBuffer.clear()
    }

    /// Run mode detection on the accumulated buffer
    private func runModeDetection() {
        guard let detector = modeDetector else { return }

        let samples = modeDetectionBuffer.snapshot()

        // Need at least 0.5 seconds
        guard samples.count >= 24000 else { return }

        let ml = mlClassifier

        // Run detection on background thread to avoid blocking UI
        Task.detached { [weak self] in
            var result = detector.detect(samples: samples)

            // If ML classifier is available, use it to re-rank based on trained GBM
            if let ml = ml {
                let features = result.features
                let featureDict: [String: Double] = [
                    "bandwidth": features.occupiedBandwidth,
                    "flatness": Double(features.spectralFlatness),
                    "num_peaks": Double(features.peaks.count),
                    "top_peak_power": Double(features.peaks.first?.powerAboveNoise ?? 0),
                    "top_peak_bw": features.peaks.first?.bandwidth3dB ?? 0,
                    "fsk_pairs": Double(features.fskPairs.count),
                    "fsk_valley_pairs": Double(features.fskPairs.filter { $0.hasValley }.count),
                    "envelope_cv": Double(features.envelopeStats.coefficientOfVariation),
                    "duty_cycle": Double(features.envelopeStats.dutyCycle),
                    "transition_rate": Double(features.envelopeStats.transitionRate),
                    "has_ook": features.envelopeStats.hasOnOffKeying ? 1.0 : 0.0,
                    "baud_rate": features.estimatedBaudRate,
                    "baud_confidence": Double(features.baudRateConfidence),
                ]

                let mlResult = ml.classify(features: featureDict)

                // Re-rank: build new ModeScore array from ML probabilities
                if !mlResult.probabilities.isEmpty {
                    var newRankings: [ModeScore] = []
                    for (mode, prob) in mlResult.probabilities {
                        // Find the matching DigitalMode from the existing rankings
                        if let existing = result.rankings.first(where: { $0.mode.rawValue.lowercased() == mode }) {
                            let mlEvidence = Evidence(
                                label: "ML classifier",
                                impact: Float(prob),
                                detail: "GBM model trained on 5800 signals: \(Int(prob * 100))% confidence"
                            )
                            var evidence = existing.evidence
                            evidence.insert(mlEvidence, at: 0)
                            // Blend: 70% ML, 30% hand-tuned
                            let blended = Float(prob) * 0.7 + existing.confidence * 0.3
                            newRankings.append(ModeScore(
                                mode: existing.mode,
                                confidence: blended,
                                explanation: "ML: \(mode) \(Int(prob * 100))%. \(existing.explanation)",
                                evidence: evidence
                            ))
                        }
                    }
                    // Add any modes not in ML output
                    for existing in result.rankings {
                        if !newRankings.contains(where: { $0.mode == existing.mode }) {
                            newRankings.append(existing)
                        }
                    }
                    newRankings.sort { $0.confidence > $1.confidence }

                    result = ModeDetectionResult(
                        rankings: newRankings,
                        noiseScore: result.noiseScore,
                        features: result.features,
                        audioDuration: result.audioDuration,
                        analysisTime: result.analysisTime
                    )
                }
            }

            let finalResult = result
            await MainActor.run { [weak self] in
                self?.modeDetectionResult = finalResult
            }
        }
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

        // RTTY is uppercase-only (Baudot limitation), PSK/Rattlegram preserve case
        let messageContent: String
        if selectedMode == .rtty {
            messageContent = content.uppercased()
        } else if selectedMode == .rattlegram {
            // Rattlegram supports full UTF-8 but is limited to 170 bytes
            let utf8 = Array(content.utf8.prefix(170))
            messageContent = String(bytes: utf8, encoding: .utf8) ?? String(content.prefix(170))
        } else {
            messageContent = content
        }

        let message = Message(
            content: messageContent,
            direction: .sent,
            mode: selectedMode,
            callsign: Station.myStation.callsign,
            transmitState: .queued
        )

        channels[index].messages.append(message)
        channels[index].lastActivity = Date()

        // User transmitted on this channel — it's definitely a legit conversation
        if channels[index].isLikelyLegitimate != true {
            channels[index].isLikelyLegitimate = true
            channels[index].classificationConfidence = 1.0
        }

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
        // Clean up tracking state for deleted channels
        for index in offsets {
            if index < channels.count {
                let frequency = Double(channels[index].frequency)
                lastDecodeTime[frequency] = nil
                lastReceivedContentTime[frequency] = nil
                decodingMode[frequency] = nil
            }
        }
        channels.remove(atOffsets: offsets)
    }

    func deleteChannel(_ channel: Channel) {
        let frequency = Double(channel.frequency)
        channels.removeAll { $0.id == channel.id }
        // Clean up per-frequency tracking state so new channels on this frequency start fresh
        lastDecodeTime[frequency] = nil
        lastReceivedContentTime[frequency] = nil
        decodingMode[frequency] = nil
        draftMessages[channel.id] = nil
        lastReadDates[channel.id] = nil
    }

    /// Clear all channels and reset decode state for the current mode
    func clearAllChannels() {
        for channel in channels {
            draftMessages[channel.id] = nil
            lastReadDates[channel.id] = nil
        }
        channelsByMode[selectedMode] = []
        lastDecodeTimeByMode[selectedMode] = [:]
        lastReceivedContentTimeByMode[selectedMode] = [:]
        decodingModeByMode[selectedMode] = [:]
    }

    /// Clear channels for a specific mode
    func clearChannels(for mode: DigitalMode) {
        // Clean up drafts and read dates for channels in this mode
        for channel in (channelsByMode[mode] ?? []) {
            draftMessages[channel.id] = nil
            lastReadDates[channel.id] = nil
        }
        channelsByMode[mode] = []
        lastDecodeTimeByMode[mode] = [:]
        lastReceivedContentTimeByMode[mode] = [:]
        decodingModeByMode[mode] = [:]
    }

    /// Mark a channel as read (clears unread badge)
    func markChannelAsRead(_ id: UUID) {
        lastReadDates[id] = Date()
    }

    /// Count of unread received messages for a channel
    func unreadCount(for channel: Channel) -> Int {
        guard let lastRead = lastReadDates[channel.id] else {
            return channel.messages.filter { $0.direction == .received }.count
        }
        return channel.messages.filter { $0.direction == .received && $0.timestamp > lastRead }.count
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
        case .cw:
            initialSquelch = Int(settings.cwSquelch * 100)
        case .olivia, .rattlegram, .js8call, .ft8:
            initialSquelch = 0
        }

        let newChannel = Channel(
            frequency: frequency,
            callsign: nil,
            messages: [],
            lastActivity: Date(),
            squelch: initialSquelch,
            cwWPM: settings.cwWPM,
            cwToneFrequency: settings.cwToneFrequency
        )
        channels.insert(newChannel, at: 0)
        return newChannel
    }

    // MARK: - Per-Channel RTTY Settings

    /// Set baud rate for a specific RTTY channel
    func setChannelBaudRate(_ baudRate: Double, for channelId: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == channelId }) else { return }
        channels[index].rttyBaudRate = baudRate
        modemService.setChannelBaudRate(baudRate, atFrequency: Double(channels[index].frequency))
    }

    /// Set polarity inversion for a specific RTTY channel
    func setChannelPolarity(inverted: Bool, for channelId: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == channelId }) else { return }
        channels[index].polarityInverted = inverted
        modemService.setChannelPolarity(inverted: inverted, atFrequency: Double(channels[index].frequency))
    }

    /// Set frequency offset for a specific RTTY channel
    func setChannelFrequencyOffset(_ offset: Int, for channelId: UUID) {
        guard let index = channels.firstIndex(where: { $0.id == channelId }) else { return }
        channels[index].frequencyOffset = offset
        modemService.setChannelFrequencyOffset(Double(offset), atFrequency: Double(channels[index].frequency))
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
            transmissionTimedOut = false

            // Timeout watchdog: force-stop if transmission hangs
            let watchdog = Task {
                try await Task.sleep(nanoseconds: 120_000_000_000) // 120 seconds
                transmissionTimedOut = true
                audioService.stopPlayback()
            }

            do {
                try await performTransmission(text: text, atFrequency: frequency)
                watchdog.cancel()
                // Mark as sent (only if not cancelled)
                if isTransmitting {
                    channels[channelIndex].messages[messageIndex].transmitState = .sent
                }
            } catch AudioServiceError.playbackCancelled {
                watchdog.cancel()
                if transmissionTimedOut {
                    // Timeout caused the cancellation
                    print("[ChatViewModel] Transmission timed out")
                    channels[channelIndex].messages[messageIndex].transmitState = .failed
                    channels[channelIndex].messages[messageIndex].errorMessage = String(localized: "Transmission timed out")
                } else {
                    print("[ChatViewModel] Transmission cancelled")
                    // State already set by stopTransmission
                }
            } catch {
                watchdog.cancel()
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

        // For JS8Call, wait until the next UTC period boundary before transmitting.
        // Other stations expect signals aligned to 15s/10s/6s/30s boundaries.
        if selectedMode == .js8call {
            let periodMs = modemService.js8callPeriodMs
            let msOfDay = Int(Date().timeIntervalSince1970 * 1000) % (86400 * 1000)
            let msIntoPeriod = msOfDay % periodMs
            let msUntilNext = periodMs - msIntoPeriod
            if msUntilNext > 100 && msUntilNext < periodMs {
                print("[ChatViewModel] JS8Call: waiting \(msUntilNext)ms for next period boundary")
                try await Task.sleep(nanoseconds: UInt64(msUntilNext) * 1_000_000)
            }
        }

        // Apply output gain from settings and play
        audioService.outputGain = Float(SettingsManager.shared.outputGain)
        try await audioService.playSamples(combinedSamples)
        print("[ChatViewModel] Playback complete")
    }

    // MARK: - Text Classification & Callsign Extraction

    /// Run CoreML classification and callsign extraction on a background thread.
    /// Gating logic prevents excessive inference (requires ≥5 chars, re-runs every 3 chars).
    private func classifyAndExtractAsync(at channelIndex: Int, for mode: DigitalMode) {
        let modeChannels = channelsByMode[mode] ?? []
        guard channelIndex < modeChannels.count else { return }

        let channel = modeChannels[channelIndex]
        let text = channel.previewText
        let length = text.count

        // Check gating conditions before dispatching background work
        let needsClassification = channel.isLikelyLegitimate != true
            && length >= 5
            && !(channel.isLikelyLegitimate == false && length > 48)
            && length >= channel.classifiedAtLength + 3
        let needsExtraction = channel.callsign == nil
            && channel.isLikelyLegitimate == true
            && length >= 5
            && length >= channel.extractedAtLength + 3

        guard needsClassification || needsExtraction else { return }

        let classifier = textClassifier
        let extractor = callsignExtractor

        Task.detached { [weak self] in
            var classifyResult: (isLegitimate: Bool, confidence: Double)?
            var extractResult: String?

            if needsClassification, let classifier {
                let result = classifier.classify(text)
                classifyResult = (result.isLegitimate, result.confidence)
            }

            let isLegitAfterClassify = classifyResult?.isLegitimate ?? (channel.isLikelyLegitimate == true)
            if (needsExtraction || (classifyResult != nil && isLegitAfterClassify)),
               channel.callsign == nil, let extractor {
                extractResult = extractor.extractCallsign(text)
            }

            guard classifyResult != nil || extractResult != nil else { return }

            let finalClassifyResult = classifyResult
            let finalExtractResult = extractResult
            await MainActor.run { [weak self] in
                guard let self else { return }
                var channels = self.channelsByMode[mode] ?? []
                guard channelIndex < channels.count else { return }

                if let result = finalClassifyResult {
                    channels[channelIndex].isLikelyLegitimate = result.isLegitimate
                    channels[channelIndex].classificationConfidence = result.confidence
                    channels[channelIndex].classifiedAtLength = length
                }
                if let callsign = finalExtractResult {
                    channels[channelIndex].callsign = callsign
                    print("[ChatViewModel] Extracted callsign \(callsign) on \(channels[channelIndex].frequency) Hz")
                } else if needsExtraction {
                    channels[channelIndex].extractedAtLength = length
                }
                self.channelsByMode[mode] = channels
            }
        }
    }

    // MARK: - Channel Management for RX

    /// Get or create a channel at the given frequency for a specific mode
    private func getOrCreateChannel(at frequency: Double, for mode: DigitalMode) -> Int {
        var modeChannels = channelsByMode[mode] ?? []

        // CW mode: single channel for all frequencies.
        // All signals go to one conversation; frequency is noted per-message.
        if mode == .cw && !modeChannels.isEmpty {
            return 0
        }

        if mode != .cw {
            // Other modes: separate channel per frequency (±10 Hz tolerance)
            if let index = modeChannels.firstIndex(where: { abs($0.frequency - Int(frequency)) < 10 }) {
                return index
            }
        }

        // Get initial squelch from global settings (convert 0.0-1.0 to 0-100)
        let settings = SettingsManager.shared
        let initialSquelch: Int
        switch mode {
        case .rtty:
            initialSquelch = Int(settings.rttySquelch * 100)
        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            initialSquelch = Int(settings.psk31Squelch * 100)
        case .cw:
            initialSquelch = Int(settings.cwSquelch * 100)
        case .olivia, .rattlegram, .js8call, .ft8:
            initialSquelch = 0
        }

        // Get initial RTTY settings from global settings
        let initialBaudRate = mode == .rtty ? settings.rttyBaudRate : 45.45
        let initialPolarity = mode == .rtty ? settings.rttyPolarityInverted : false
        let initialOffset = mode == .rtty ? settings.rttyFrequencyOffset : 0

        // Create new channel with initial settings from global settings
        let newChannel = Channel(
            frequency: Int(frequency),
            callsign: nil,
            messages: [],
            lastActivity: Date(),
            squelch: initialSquelch,
            rttyBaudRate: initialBaudRate,
            polarityInverted: initialPolarity,
            frequencyOffset: initialOffset,
            cwWPM: settings.cwWPM,
            cwToneFrequency: settings.cwToneFrequency
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

        // For CW single-channel mode, label messages with their frequency offset
        // so the user can see which signal each decode came from.
        // Shows offset from 700 Hz (standard CW sidetone), e.g. "+50 Hz", "-25 Hz".
        let messageCallsign: String?
        if mode == .cw {
            let offset = Int(frequency) - 700
            let sign = offset >= 0 ? "+" : ""
            messageCallsign = "\(sign)\(offset) Hz"
        } else {
            messageCallsign = nil
        }

        if canAppend,
           let lastMessageIndex = modeChannels[channelIndex].messages.indices.last {
            // Append to existing received message (only if same frequency for CW)
            let lastCallsign = modeChannels[channelIndex].messages[lastMessageIndex].callsign
            if mode == .cw && lastCallsign != messageCallsign {
                // Different frequency — start a new message instead of appending
                let message = Message(
                    content: trimmedText,
                    direction: .received,
                    mode: messageMode,
                    callsign: messageCallsign,
                    transmitState: nil
                )
                modeChannels[channelIndex].messages.append(message)
                print("[ChatViewModel] RX new freq on CW \(Int(frequency)) Hz: \(trimmedText)")
            } else {
                modeChannels[channelIndex].messages[lastMessageIndex].content += trimmedText
                print("[ChatViewModel] RX appended on \(Int(frequency)) Hz (\(messageMode.rawValue)): \(trimmedText)")
            }
        } else {
            // Create new received message
            let message = Message(
                content: trimmedText,
                direction: .received,
                mode: messageMode,
                callsign: messageCallsign,
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

        // Classify channel content and extract callsign (background thread)
        classifyAndExtractAsync(at: channelIndex, for: mode)
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

    nonisolated func modemService(
        _ service: ModemService,
        didDecodeMessage text: String,
        callSign: String?,
        bitFlips: Int,
        onChannel frequency: Double,
        mode: DigitalMode
    ) {
        Task { @MainActor in
            handleDecodedMessage(text, callSign: callSign, bitFlips: bitFlips, onChannel: frequency, mode: mode)
        }
    }

    /// Handle a complete decoded message (burst modes like Rattlegram)
    private func handleDecodedMessage(_ text: String, callSign: String?, bitFlips: Int, onChannel frequency: Double, mode: DigitalMode) {
        let channelIndex = getOrCreateChannel(at: frequency, for: mode)
        var modeChannels = channelsByMode[mode] ?? []
        guard channelIndex < modeChannels.count else { return }

        let now = Date()

        // Update channel callsign if we got one
        if let callSign = callSign, !callSign.isEmpty {
            modeChannels[channelIndex].callsign = callSign
        }

        // Create a complete message (no buffering needed for burst modes)
        let message = Message(
            content: text,
            direction: .received,
            mode: mode,
            callsign: callSign,
            transmitState: nil
        )
        modeChannels[channelIndex].messages.append(message)
        modeChannels[channelIndex].lastActivity = now
        channelsByMode[mode] = modeChannels

        // Update content tracking
        var updatedLastReceivedContentTime = lastReceivedContentTimeByMode[mode] ?? [:]
        updatedLastReceivedContentTime[frequency] = now
        lastReceivedContentTimeByMode[mode] = updatedLastReceivedContentTime

        print("[ChatViewModel] Rattlegram RX on \(Int(frequency)) Hz from \(callSign ?? "unknown"): \"\(text)\" (\(bitFlips) flips)")

        // Classify channel content and extract callsign (background thread)
        classifyAndExtractAsync(at: channelIndex, for: mode)
    }

    /// Check if current input level is above the noise floor threshold
    private var isAboveNoiseFloor: Bool {
        let threshold = SettingsManager.shared.noiseFloorThreshold
        guard threshold > -60 else { return true } // -60 = disabled
        let level = Double(audioService.inputLevel)
        let levelDb = 20 * log10(max(level, 0.001))
        return levelDb >= threshold
    }

    /// Handle decoded character on main actor
    /// The mode parameter specifies which decoder produced this character
    /// signalStrength is used for per-channel squelch filtering (0.0-1.0)
    private func handleDecodedCharacter(_ character: Character, onChannel frequency: Double, mode: DigitalMode, signalStrength: Float) {
        // Check noise floor threshold
        guard isAboveNoiseFloor else { return }

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
