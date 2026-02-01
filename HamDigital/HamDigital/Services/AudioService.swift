//
//  AudioService.swift
//  DigiModes
//
//  Audio interface handling using AVAudioEngine for USB audio devices
//

import Foundation
@preconcurrency import AVFoundation

/// Callback for receiving audio input samples
typealias AudioInputCallback = ([Float]) -> Void

/// AudioService handles connection to external USB audio interfaces
/// and provides audio I/O for digital mode encoding/decoding.
/// Marked @unchecked Sendable as we handle thread safety via DispatchQueue.main.
class AudioService: ObservableObject, @unchecked Sendable {
    // MARK: - Published Properties
    @Published var isConnected: Bool = false
    @Published var inputDeviceName: String = "None"
    @Published var outputDeviceName: String = "None"
    @Published var sampleRate: Double = 48000.0
    @Published var isPlaying: Bool = false
    @Published var isListening: Bool = false

    // MARK: - Audio Engine
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    /// Audio format for playback (48kHz mono Float32)
    private var playbackFormat: AVAudioFormat?

    /// Continuation for async playback completion
    private var playbackContinuation: CheckedContinuation<Void, Error>?

    /// Callback for audio input samples
    var onAudioInput: AudioInputCallback?

    // MARK: - Initialization
    init() {
        setupNotifications()
    }

    deinit {
        stop()
    }

    // MARK: - Public Methods

    /// Start audio engine and configure for playback
    func start() async throws {
        // Configure audio session
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        try session.setActive(true)

        // Create audio engine
        let engine = AVAudioEngine()
        self.audioEngine = engine

        // Create player node for transmission
        let player = AVAudioPlayerNode()
        self.playerNode = player
        engine.attach(player)

        // Get output format and create mono format for our signals
        let outputFormat = engine.outputNode.outputFormat(forBus: 0)
        sampleRate = outputFormat.sampleRate

        // Create mono Float32 format at the engine's sample rate
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw AudioServiceError.formatError
        }
        self.playbackFormat = monoFormat

        // Connect player -> main mixer
        engine.connect(player, to: engine.mainMixerNode, format: monoFormat)

        // Install input tap for receiving audio
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        // Install tap to capture audio input
        // Capture callback reference to avoid Sendable warning on self
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self = self else { return }
            self.handleInputBuffer(buffer)
        }

        // Start the engine
        try engine.start()

        isConnected = true
        isListening = true
        updateDeviceNames()

        print("[AudioService] Started with sample rate: \(sampleRate) Hz, listening for input")
    }

    /// Handle audio input from tap (nonisolated to satisfy Sendable requirement)
    private nonisolated func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        // Convert to mono Float array
        guard let channelData = buffer.floatChannelData else { return }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        // If stereo, mix to mono; if mono, use directly
        var samples = [Float](repeating: 0, count: frameLength)

        if channelCount == 1 {
            // Mono - copy directly
            for i in 0..<frameLength {
                samples[i] = channelData[0][i]
            }
        } else {
            // Stereo or more - mix to mono
            for i in 0..<frameLength {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += channelData[ch][i]
                }
                samples[i] = sum / Float(channelCount)
            }
        }

        // Call the callback on main thread
        DispatchQueue.main.async { [weak self] in
            self?.onAudioInput?(samples)
        }
    }

    /// Stop audio engine
    func stop() {
        // Remove input tap before stopping
        audioEngine?.inputNode.removeTap(onBus: 0)

        playerNode?.stop()
        audioEngine?.stop()
        audioEngine = nil
        playerNode = nil
        isConnected = false
        isPlaying = false
        isListening = false
        print("[AudioService] Stopped")
    }

    /// Play an audio buffer and wait for completion
    ///
    /// - Parameter buffer: The audio buffer to play
    /// - Throws: AudioServiceError if playback fails
    func playBuffer(_ buffer: AVAudioPCMBuffer) async throws {
        guard let player = playerNode, let engine = audioEngine, engine.isRunning else {
            throw AudioServiceError.notConnected
        }

        // Convert buffer to engine format if needed
        let playableBuffer: AVAudioPCMBuffer
        if let format = playbackFormat, buffer.format != format {
            guard let converted = convertBuffer(buffer, to: format) else {
                throw AudioServiceError.formatError
            }
            playableBuffer = converted
        } else {
            playableBuffer = buffer
        }

        isPlaying = true

        // Use async continuation to wait for playback completion
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.playbackContinuation = continuation

            player.scheduleBuffer(playableBuffer) { [weak self] in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    self.isPlaying = false
                    // Only resume if continuation hasn't been consumed by stopPlayback
                    if self.playbackContinuation != nil {
                        self.playbackContinuation?.resume(returning: ())
                        self.playbackContinuation = nil
                    }
                }
            }

            if !player.isPlaying {
                player.play()
            }
        }
    }

    /// Stop current playback immediately
    func stopPlayback() {
        playerNode?.stop()
        isPlaying = false

        // Cancel the waiting continuation
        if let continuation = playbackContinuation {
            continuation.resume(throwing: AudioServiceError.playbackCancelled)
            playbackContinuation = nil
        }
    }

    /// Play raw Float samples
    ///
    /// - Parameter samples: Array of audio samples to play
    /// - Throws: AudioServiceError if playback fails
    func playSamples(_ samples: [Float]) async throws {
        guard let format = playbackFormat else {
            throw AudioServiceError.notConnected
        }

        guard let buffer = createBuffer(from: samples, format: format) else {
            throw AudioServiceError.formatError
        }

        try await playBuffer(buffer)
    }

    /// Get current input audio buffer for decoding (future implementation)
    func getInputBuffer() -> AVAudioPCMBuffer? {
        // TODO: Implement input tap for RX audio
        return nil
    }

    // MARK: - Private Methods

    private func setupNotifications() {
        // Listen for audio route changes (device connected/disconnected)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleRouteChange),
            name: AVAudioSession.routeChangeNotification,
            object: nil
        )

        // Listen for audio engine configuration changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleConfigurationChange),
            name: .AVAudioEngineConfigurationChange,
            object: nil
        )
    }

    @objc private func handleRouteChange(_ notification: Notification) {
        print("[AudioService] Route change detected")
        updateDeviceNames()
    }

    @objc private func handleConfigurationChange(_ notification: Notification) {
        print("[AudioService] Configuration change detected")
        // Engine may need to be restarted with new configuration
        if let engine = audioEngine, !engine.isRunning {
            try? engine.start()
        }
    }

    private func updateDeviceNames() {
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute

        if let input = route.inputs.first {
            inputDeviceName = input.portName
        } else {
            inputDeviceName = "None"
        }

        if let output = route.outputs.first {
            outputDeviceName = output.portName
        } else {
            outputDeviceName = "None"
        }
    }

    /// Create AVAudioPCMBuffer from Float array
    private func createBuffer(from samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)

        if let channelData = buffer.floatChannelData?[0] {
            for (index, sample) in samples.enumerated() {
                channelData[index] = sample
            }
        }

        return buffer
    }

    /// Convert buffer to target format
    private func convertBuffer(_ buffer: AVAudioPCMBuffer, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: buffer.format, to: format) else {
            return nil
        }

        let outputFrameCapacity = AVAudioFrameCount(
            Double(buffer.frameLength) * format.sampleRate / buffer.format.sampleRate
        )

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: outputFrameCapacity
        ) else {
            return nil
        }

        var error: NSError?
        converter.convert(to: outputBuffer, error: &error) { inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }

        if let error = error {
            print("[AudioService] Conversion error: \(error)")
            return nil
        }

        return outputBuffer
    }
}

// MARK: - Errors

enum AudioServiceError: Error, LocalizedError {
    case notConnected
    case formatError
    case playbackFailed
    case playbackCancelled

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Audio service not connected"
        case .formatError:
            return "Audio format error"
        case .playbackFailed:
            return "Audio playback failed"
        case .playbackCancelled:
            return "Playback was cancelled"
        }
    }
}
