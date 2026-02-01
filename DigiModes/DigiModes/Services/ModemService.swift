//
//  ModemService.swift
//  DigiModes
//
//  Digital mode modulation/demodulation service
//  Bridges between iOS audio and DigiModesCore library
//

import Foundation
import AVFoundation

#if canImport(DigiModesCore)
import DigiModesCore
#endif

/// Protocol for receiving decoded characters from ModemService
protocol ModemServiceDelegate: AnyObject {
    /// Called when a character is decoded
    func modemService(
        _ service: ModemService,
        didDecode character: Character,
        onChannel frequency: Double
    )

    /// Called when signal detection changes
    func modemService(
        _ service: ModemService,
        signalDetected: Bool,
        onChannel frequency: Double
    )
}

/// ModemService handles encoding and decoding of digital mode signals
///
/// Bridges between iOS audio (AVAudioPCMBuffer) and the DigiModesCore library.
/// Currently supports RTTY with multi-channel decoding.
///
/// When DigiModesCore is not available, this service operates in placeholder mode.
@MainActor
class ModemService: ObservableObject {

    // MARK: - Published Properties

    @Published var activeMode: DigitalMode = .rtty
    @Published var isDecoding: Bool = false
    @Published var signalStrength: Float = 0

    /// Active channels being monitored (frequency in Hz)
    @Published var channelFrequencies: [Double] = []

    // MARK: - Delegate

    weak var delegate: ModemServiceDelegate?

    // MARK: - RTTY Modem

    #if canImport(DigiModesCore)
    private var rttyModem: RTTYModem?
    private var multiChannelDemodulator: MultiChannelRTTYDemodulator?
    #endif

    /// Audio format for processing (48kHz mono Float32)
    private let processingFormat: AVAudioFormat?

    /// Whether DigiModesCore is available
    var isModemAvailable: Bool {
        #if canImport(DigiModesCore)
        return rttyModem != nil
        #else
        return false
        #endif
    }

    // MARK: - Initialization

    init() {
        // Create processing format
        self.processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        )

        #if canImport(DigiModesCore)
        // Create RTTY modem with standard configuration
        self.rttyModem = RTTYModem(configuration: .standard)
        setupMultiChannelDemodulator()
        #else
        print("[ModemService] DigiModesCore not available - running in placeholder mode")
        // Setup default channel frequencies for placeholder mode
        channelFrequencies = [1275, 1445, 1615, 1785, 1955, 2125, 2295, 2465]
        #endif
    }

    // MARK: - Setup

    #if canImport(DigiModesCore)
    private func setupMultiChannelDemodulator() {
        // Create demodulator covering common RTTY audio frequencies
        multiChannelDemodulator = MultiChannelRTTYDemodulator.standardSubband()
        multiChannelDemodulator?.delegate = self
        channelFrequencies = multiChannelDemodulator?.channels.map { $0.frequency } ?? []
    }
    #endif

    // MARK: - Mode Selection

    /// Switch active digital mode
    func setMode(_ mode: DigitalMode) {
        activeMode = mode
        print("[ModemService] Mode changed to \(mode.rawValue)")

        #if canImport(DigiModesCore)
        rttyModem?.reset()
        #endif
    }

    // MARK: - Decoding (RX)

    /// Process incoming audio buffer for decoding
    ///
    /// Call this method with audio from the microphone or radio input.
    /// Decoded characters are delivered via the delegate.
    ///
    /// - Parameter buffer: Audio buffer to process
    func processRxAudio(_ buffer: AVAudioPCMBuffer) {
        guard activeMode == .rtty else {
            // TODO: Add support for other modes
            return
        }

        guard let floatData = buffer.floatChannelData?[0] else {
            return
        }

        let frameCount = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: floatData, count: frameCount))

        processRxSamples(samples)
    }

    /// Process raw Float array samples
    func processRxSamples(_ samples: [Float]) {
        guard activeMode == .rtty else {
            return
        }

        #if canImport(DigiModesCore)
        if let multiDemod = multiChannelDemodulator {
            multiDemod.process(samples: samples)
            channelFrequencies = multiDemod.channels.map { $0.frequency }
        } else {
            rttyModem?.process(samples: samples)
        }

        signalStrength = rttyModem?.signalStrength ?? 0
        isDecoding = rttyModem?.isSignalDetected ?? false
        #endif
    }

    // MARK: - Encoding (TX)

    /// Encode text for transmission
    ///
    /// Returns an audio buffer containing the encoded RTTY signal
    /// ready to be played through the audio output.
    ///
    /// - Parameter text: Text to encode
    /// - Returns: Audio buffer, or nil if encoding fails
    func encodeTxText(_ text: String) -> AVAudioPCMBuffer? {
        guard activeMode == .rtty else {
            // TODO: Add support for other modes
            return nil
        }

        #if canImport(DigiModesCore)
        guard let modem = rttyModem else { return nil }

        let samples = modem.encodeWithIdle(
            text: text,
            preambleMs: 100,
            postambleMs: 50
        )

        return createBuffer(from: samples)
        #else
        return nil
        #endif
    }

    /// Encode text and return raw samples
    func encodeTxSamples(_ text: String) -> [Float] {
        #if canImport(DigiModesCore)
        return rttyModem?.encodeWithIdle(
            text: text,
            preambleMs: 100,
            postambleMs: 50
        ) ?? []
        #else
        return []
        #endif
    }

    /// Generate idle tone for carrier
    func generateIdleTone(duration: Double) -> AVAudioPCMBuffer? {
        #if canImport(DigiModesCore)
        guard let modem = rttyModem else { return nil }
        let samples = modem.generateIdle(duration: duration)
        return createBuffer(from: samples)
        #else
        return nil
        #endif
    }

    // MARK: - Channel Management

    /// Tune to a specific frequency
    func tune(to frequency: Double) {
        #if canImport(DigiModesCore)
        rttyModem?.tune(to: frequency)
        #endif
    }

    /// Add a channel to monitor
    func addChannel(at frequency: Double) {
        #if canImport(DigiModesCore)
        guard let multiDemod = multiChannelDemodulator else { return }
        multiDemod.addChannel(at: frequency)
        channelFrequencies = multiDemod.channels.map { $0.frequency }
        #else
        if !channelFrequencies.contains(frequency) {
            channelFrequencies.append(frequency)
            channelFrequencies.sort()
        }
        #endif
    }

    /// Remove a channel by frequency
    func removeChannel(at frequency: Double) {
        #if canImport(DigiModesCore)
        guard let multiDemod = multiChannelDemodulator else { return }
        if let channel = multiDemod.channel(at: frequency) {
            multiDemod.removeChannel(channel.id)
            channelFrequencies = multiDemod.channels.map { $0.frequency }
        }
        #else
        channelFrequencies.removeAll { abs($0 - frequency) < 1.0 }
        #endif
    }

    // MARK: - Control

    /// Reset modem state
    func reset() {
        #if canImport(DigiModesCore)
        rttyModem?.reset()
        multiChannelDemodulator?.reset()
        #endif
        signalStrength = 0
        isDecoding = false
    }

    // MARK: - Private Helpers

    /// Create AVAudioPCMBuffer from Float array
    private func createBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = processingFormat,
              let buffer = AVAudioPCMBuffer(
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
}

// MARK: - MultiChannelRTTYDemodulatorDelegate

#if canImport(DigiModesCore)
extension ModemService: MultiChannelRTTYDemodulatorDelegate {
    nonisolated func demodulator(
        _ demodulator: MultiChannelRTTYDemodulator,
        didDecode character: Character,
        onChannel channel: RTTYChannel
    ) {
        Task { @MainActor in
            delegate?.modemService(self, didDecode: character, onChannel: channel.frequency)
        }
    }

    nonisolated func demodulator(
        _ demodulator: MultiChannelRTTYDemodulator,
        signalDetected detected: Bool,
        onChannel channel: RTTYChannel
    ) {
        Task { @MainActor in
            delegate?.modemService(self, signalDetected: detected, onChannel: channel.frequency)
        }
    }

    nonisolated func demodulator(
        _ demodulator: MultiChannelRTTYDemodulator,
        didUpdateChannels updatedChannels: [RTTYChannel]
    ) {
        Task { @MainActor in
            self.channelFrequencies = updatedChannels.map { $0.frequency }
        }
    }
}

// MARK: - RTTYModemDelegate for Single-Channel Mode

extension ModemService: RTTYModemDelegate {
    nonisolated func modem(
        _ modem: RTTYModem,
        didDecode character: Character,
        atFrequency frequency: Double
    ) {
        Task { @MainActor in
            delegate?.modemService(self, didDecode: character, onChannel: frequency)
        }
    }

    nonisolated func modem(
        _ modem: RTTYModem,
        signalDetected detected: Bool,
        atFrequency frequency: Double
    ) {
        Task { @MainActor in
            self.isDecoding = detected
            delegate?.modemService(self, signalDetected: detected, onChannel: frequency)
        }
    }
}
#endif
