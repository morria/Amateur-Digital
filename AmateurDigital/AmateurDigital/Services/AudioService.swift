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
    @Published var inputLevel: Float = 0.0

    /// Output gain multiplier (1.0 = unity, 2.0 = +6dB, etc.)
    /// Increase if output level is too low for VOX
    var outputGain: Float = 1.0

    // MARK: - Audio Engine
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?

    /// Audio format for playback (48kHz mono Float32)
    private var playbackFormat: AVAudioFormat?

    /// Continuation for async playback completion
    private var playbackContinuation: CheckedContinuation<Void, Error>?

    /// Callback for audio input samples
    var onAudioInput: AudioInputCallback?

    /// Flag to track when audio engine is being reconfigured
    private var isReconfiguring: Bool = false

    /// Continuation to wait for reconfiguration to complete
    private var reconfigurationWaiters: [CheckedContinuation<Void, Never>] = []

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
        // Configure audio session for external audio devices (USB soundcards, headphones)
        let session = AVAudioSession.sharedInstance()
        // Use .allowBluetoothHFP for headsets, don't use .defaultToSpeaker so USB devices work
        try session.setCategory(.playAndRecord, mode: .default, options: [.allowBluetoothHFP, .allowBluetoothA2DP])
        try session.setPreferredSampleRate(48000)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        print("[AudioService] Audio session configured, current route: \(session.currentRoute)")

        // Create audio engine
        let engine = AVAudioEngine()
        self.audioEngine = engine

        // Create player node for transmission
        let player = AVAudioPlayerNode()
        self.playerNode = player
        engine.attach(player)

        // Get output format from the hardware
        let outputNode = engine.outputNode
        let hardwareFormat = outputNode.outputFormat(forBus: 0)
        sampleRate = hardwareFormat.sampleRate
        let outputChannels = hardwareFormat.channelCount

        print("[AudioService] Hardware output format: \(sampleRate) Hz, \(outputChannels) channels")
        print("[AudioService] Hardware format details: \(hardwareFormat)")

        // Create stereo Float32 format to match typical USB audio devices
        // Use non-interleaved format for AVAudioEngine compatibility
        guard let stereoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 2,
            interleaved: false
        ) else {
            throw AudioServiceError.formatError
        }
        self.playbackFormat = stereoFormat

        // Get the mixer's output format (this is what connects to outputNode)
        let mixerOutputFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        print("[AudioService] Mixer output format: \(mixerOutputFormat)")

        // Connect player -> main mixer with stereo format
        engine.connect(player, to: engine.mainMixerNode, format: stereoFormat)

        // Explicitly connect main mixer to output node to ensure the chain is complete
        // Use nil format to let the engine handle format conversion
        engine.connect(engine.mainMixerNode, to: outputNode, format: nil)

        // Ensure volumes are set correctly
        player.volume = 1.0
        engine.mainMixerNode.outputVolume = 1.0
        print("[AudioService] Player volume: \(player.volume), Mixer volume: \(engine.mainMixerNode.outputVolume)")

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
        do {
            try engine.start()
        } catch {
            print("[AudioService] Failed to start engine: \(error)")
            self.audioEngine = nil
            self.playerNode = nil
            throw error
        }

        isConnected = true
        isListening = true
        updateDeviceNames()

        print("[AudioService] Started with sample rate: \(sampleRate) Hz")
        print("[AudioService] Input: \(inputDeviceName), Output: \(outputDeviceName)")
    }

    /// Handle audio input from tap (nonisolated to satisfy Sendable requirement)
    private nonisolated func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        // Skip input processing while transmitting to avoid decoding our own signal
        if isPlaying { return }

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

        // Calculate RMS level for metering
        var sumOfSquares: Float = 0
        for sample in samples {
            sumOfSquares += sample * sample
        }
        let rmsLevel = sqrt(sumOfSquares / Float(samples.count))

        // Call the callback on main thread and update input level
        DispatchQueue.main.async { [weak self] in
            self?.inputLevel = rmsLevel
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
        // Wait for any in-progress reconfiguration to complete
        if isReconfiguring {
            print("[AudioService] Waiting for reconfiguration to complete...")
            await withCheckedContinuation { continuation in
                reconfigurationWaiters.append(continuation)
            }
        }

        guard let player = playerNode, let engine = audioEngine else {
            throw AudioServiceError.notConnected
        }
        guard engine.isRunning else {
            throw AudioServiceError.engineNotRunning
        }

        // Log current audio route before playing
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        print("[AudioService] Playing to output: \(route.outputs.map { "\($0.portName) (\($0.portType.rawValue))" })")

        // Convert buffer to engine format if needed
        let playableBuffer: AVAudioPCMBuffer
        if let format = playbackFormat, buffer.format != format {
            print("[AudioService] Converting buffer from \(buffer.format) to \(format)")
            guard let converted = convertBuffer(buffer, to: format) else {
                throw AudioServiceError.formatError
            }
            playableBuffer = converted
        } else {
            playableBuffer = buffer
        }

        print("[AudioService] Playing \(playableBuffer.frameLength) frames, format: \(playableBuffer.format)")
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

    /// Get current input audio buffer for decoding
    /// Note: Input is processed via the onAudioInput callback installed in start()
    func getInputBuffer() -> AVAudioPCMBuffer? {
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
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        print("[AudioService] Route change: \(reason.rawValue)")
        updateDeviceNames()

        // Reconfigure audio engine when new device connected
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable:
            Task { @MainActor in
                await self.reconfigureForRouteChange()
            }
        default:
            break
        }
    }

    @objc private func handleConfigurationChange(_ notification: Notification) {
        // Only reconfigure if the engine actually stopped
        // Configuration changes don't always require restart
        guard let engine = audioEngine, !engine.isRunning else {
            print("[AudioService] Configuration change detected but engine still running, ignoring")
            return
        }
        print("[AudioService] Configuration change detected, engine stopped - reconfiguring")
        Task { @MainActor in
            await self.reconfigureForRouteChange()
        }
    }

    /// Reconfigure audio engine after route or configuration change
    private func reconfigureForRouteChange() async {
        guard audioEngine != nil else { return }
        guard !isReconfiguring else { return }  // Avoid concurrent reconfiguration

        isReconfiguring = true
        print("[AudioService] Reconfiguring for new audio route...")

        stop()
        do {
            try await start()
            print("[AudioService] Reconfigured successfully")
        } catch {
            print("[AudioService] Reconfigure failed: \(error)")
        }

        isReconfiguring = false

        // Resume any waiters
        let waiters = reconfigurationWaiters
        reconfigurationWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
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

    /// Create AVAudioPCMBuffer from Float array with gain applied
    /// Outputs stereo (same signal on both channels) for USB soundcard compatibility
    private func createBuffer(from samples: [Float], format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            return nil
        }

        buffer.frameLength = AVAudioFrameCount(samples.count)

        let channelCount = Int(format.channelCount)
        guard let floatChannelData = buffer.floatChannelData else {
            return nil
        }

        // Fill all channels with the same signal (mono -> stereo)
        for (index, sample) in samples.enumerated() {
            // Apply output gain (clamp to prevent distortion)
            let gained = sample * outputGain
            let clampedSample = max(-1.0, min(1.0, gained))

            // Write to all channels (typically 2 for stereo)
            for channel in 0..<channelCount {
                floatChannelData[channel][index] = clampedSample
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
    case engineNotRunning
    case formatError
    case encodingFailed
    case playbackFailed
    case playbackCancelled
    case startupFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Audio not started"
        case .engineNotRunning:
            return "Audio engine stopped"
        case .formatError:
            return "Format error"
        case .encodingFailed:
            return "Encoding failed"
        case .playbackFailed:
            return "Playback failed"
        case .playbackCancelled:
            return "Cancelled"
        case .startupFailed(let reason):
            return "Audio failed: \(reason)"
        }
    }
}
