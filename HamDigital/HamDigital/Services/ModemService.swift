//
//  ModemService.swift
//  HamDigital
//
//  Digital mode modulation/demodulation service
//  Bridges between iOS audio and HamDigitalCore library
//

import Foundation
import AVFoundation

#if canImport(HamDigitalCore)
import HamDigitalCore
#endif

/// Protocol for receiving decoded characters from ModemService
protocol ModemServiceDelegate: AnyObject {
    /// Called when a character is decoded
    func modemService(
        _ service: ModemService,
        didDecode character: Character,
        onChannel frequency: Double,
        mode: DigitalMode
    )

    /// Called when signal detection changes
    func modemService(
        _ service: ModemService,
        signalDetected: Bool,
        onChannel frequency: Double,
        mode: DigitalMode
    )
}

/// ModemService handles encoding and decoding of digital mode signals
///
/// Bridges between iOS audio (AVAudioPCMBuffer) and the DigiModesCore library.
/// Currently supports RTTY with multi-channel decoding.
///
/// Uses settings from SettingsManager for baud rate, mark frequency, and shift.
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

    // MARK: - Settings

    private let settings = SettingsManager.shared

    // MARK: - RTTY Modem

    #if canImport(HamDigitalCore)
    private var rttyModem: RTTYModem?
    private var multiChannelDemodulator: MultiChannelRTTYDemodulator?

    // MARK: - PSK Modem (supports PSK31, BPSK63, QPSK31, QPSK63)

    private var pskModem: PSKModem?
    private var multiChannelPSKDemodulator: MultiChannelPSKDemodulator?
    #endif

    /// Audio format for processing (48kHz mono Float32)
    private let processingFormat: AVAudioFormat?

    /// Whether DigiModesCore is available
    var isModemAvailable: Bool {
        #if canImport(HamDigitalCore)
        return rttyModem != nil
        #else
        return false
        #endif
    }

    #if canImport(HamDigitalCore)
    /// Create RTTYConfiguration from current settings
    private var currentRTTYConfiguration: RTTYConfiguration {
        RTTYConfiguration(
            baudRate: settings.rttyBaudRate,
            markFrequency: settings.rttyMarkFreq,
            shift: settings.rttyShift,
            sampleRate: 48000.0
        )
    }

    /// Create PSKConfiguration for the current active mode
    private var currentPSKConfiguration: PSKConfiguration {
        let baseConfig: PSKConfiguration
        switch activeMode {
        case .psk31:
            baseConfig = .psk31
        case .bpsk63:
            baseConfig = .bpsk63
        case .qpsk31:
            baseConfig = .qpsk31
        case .qpsk63:
            baseConfig = .qpsk63
        default:
            baseConfig = .psk31
        }
        return baseConfig.withCenterFrequency(settings.psk31CenterFreq)
    }
    #endif

    // MARK: - Initialization

    init() {
        // Create processing format
        self.processingFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        )

        #if canImport(HamDigitalCore)
        // Create RTTY modem with settings from SettingsManager
        self.rttyModem = RTTYModem(configuration: currentRTTYConfiguration)
        setupMultiChannelDemodulator()

        // Create PSK modem (default to PSK31)
        self.pskModem = PSKModem(configuration: currentPSKConfiguration)
        setupMultiChannelPSKDemodulator()
        #else
        print("[ModemService] DigiModesCore not available - running in placeholder mode")
        // Setup default channel frequencies for placeholder mode
        channelFrequencies = [1275, 1445, 1615, 1785, 1955, 2125, 2295, 2465]
        #endif
    }

    /// Reconfigure modem with current settings (call when settings change)
    func reconfigureModem() {
        #if canImport(HamDigitalCore)
        rttyModem = RTTYModem(configuration: currentRTTYConfiguration)
        rttyModem?.delegate = self
        multiChannelDemodulator?.setSquelch(Float(settings.rttySquelch))

        pskModem = PSKModem(configuration: currentPSKConfiguration)
        pskModem?.delegate = self
        multiChannelPSKDemodulator?.setSquelch(Float(settings.psk31Squelch))
        #endif
    }

    /// Update squelch level for all demodulators
    func updateSquelch() {
        #if canImport(HamDigitalCore)
        multiChannelDemodulator?.setSquelch(Float(settings.rttySquelch))
        multiChannelPSKDemodulator?.setSquelch(Float(settings.psk31Squelch))
        #endif
    }

    // MARK: - Setup

    #if canImport(HamDigitalCore)
    private func setupMultiChannelDemodulator() {
        // Create demodulator covering common RTTY audio frequencies
        multiChannelDemodulator = MultiChannelRTTYDemodulator.standardSubband()
        multiChannelDemodulator?.delegate = self
        multiChannelDemodulator?.setSquelch(Float(settings.rttySquelch))
        channelFrequencies = multiChannelDemodulator?.channels.map { $0.frequency } ?? []
    }

    private func setupMultiChannelPSKDemodulator() {
        // Create demodulator covering common PSK audio frequencies
        multiChannelPSKDemodulator = MultiChannelPSKDemodulator.standardSubband(configuration: currentPSKConfiguration)
        multiChannelPSKDemodulator?.delegate = self
        multiChannelPSKDemodulator?.setSquelch(Float(settings.psk31Squelch))
    }
    #endif

    // MARK: - Mode Selection

    /// Switch active digital mode
    func setMode(_ mode: DigitalMode) {
        activeMode = mode
        print("[ModemService] Mode changed to \(mode.rawValue)")

        #if canImport(HamDigitalCore)
        // Update channel frequencies based on mode
        switch mode {
        case .rtty:
            channelFrequencies = multiChannelDemodulator?.channels.map { $0.frequency } ?? []
            rttyModem?.reset()
            multiChannelDemodulator?.reset()
        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            // Reconfigure PSK modem for the new mode
            pskModem = PSKModem(configuration: currentPSKConfiguration)
            pskModem?.delegate = self
            // Recreate multi-channel demodulator with new configuration
            multiChannelPSKDemodulator = MultiChannelPSKDemodulator.standardSubband(configuration: currentPSKConfiguration)
            multiChannelPSKDemodulator?.delegate = self
            multiChannelPSKDemodulator?.setSquelch(Float(settings.psk31Squelch))
            channelFrequencies = multiChannelPSKDemodulator?.channels.map { $0.frequency } ?? []
        case .olivia:
            // Not yet implemented
            break
        }
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
        guard let floatData = buffer.floatChannelData?[0] else {
            return
        }

        let frameCount = Int(buffer.frameLength)
        let samples = Array(UnsafeBufferPointer(start: floatData, count: frameCount))

        processRxSamples(samples)
    }

    /// Process raw Float array samples
    func processRxSamples(_ samples: [Float]) {
        #if canImport(HamDigitalCore)
        switch activeMode {
        case .rtty:
            if let multiDemod = multiChannelDemodulator {
                multiDemod.process(samples: samples)
                channelFrequencies = multiDemod.channels.map { $0.frequency }
            } else {
                rttyModem?.process(samples: samples)
            }
            signalStrength = rttyModem?.signalStrength ?? 0
            isDecoding = rttyModem?.isSignalDetected ?? false

        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            if let multiDemod = multiChannelPSKDemodulator {
                multiDemod.process(samples: samples)
                channelFrequencies = multiDemod.channels.map { $0.frequency }
            } else {
                pskModem?.process(samples: samples)
            }
            signalStrength = pskModem?.signalStrength ?? 0
            isDecoding = pskModem?.isSignalDetected ?? false

        case .olivia:
            // Not yet implemented
            break
        }
        #endif
    }

    // MARK: - Encoding (TX)

    /// Encode text for transmission
    ///
    /// Returns an audio buffer containing the encoded signal
    /// ready to be played through the audio output.
    ///
    /// - Parameter text: Text to encode
    /// - Returns: Audio buffer, or nil if encoding fails
    func encodeTxText(_ text: String) -> AVAudioPCMBuffer? {
        #if canImport(HamDigitalCore)
        var samples: [Float] = []

        switch activeMode {
        case .rtty:
            guard let modem = rttyModem else { return nil }
            samples = modem.encodeWithIdle(
                text: text,
                preambleMs: 100,
                postambleMs: 50
            )

        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            guard let modem = pskModem else { return nil }
            samples = modem.encodeWithEnvelope(
                text: text,
                preambleMs: 100,
                postambleMs: 50
            )

        case .olivia:
            // Not yet implemented
            return nil
        }

        return createBuffer(from: samples)
        #else
        return nil
        #endif
    }

    /// Encode text and return raw samples
    func encodeTxSamples(_ text: String) -> [Float] {
        #if canImport(HamDigitalCore)
        switch activeMode {
        case .rtty:
            return rttyModem?.encodeWithIdle(
                text: text,
                preambleMs: 100,
                postambleMs: 50
            ) ?? []

        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            return pskModem?.encodeWithEnvelope(
                text: text,
                preambleMs: 100,
                postambleMs: 50
            ) ?? []

        case .olivia:
            return []
        }
        #else
        return []
        #endif
    }

    /// Generate idle tone for carrier
    func generateIdleTone(duration: Double) -> AVAudioPCMBuffer? {
        #if canImport(HamDigitalCore)
        var samples: [Float] = []

        switch activeMode {
        case .rtty:
            guard let modem = rttyModem else { return nil }
            samples = modem.generateIdle(duration: duration)

        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            guard let modem = pskModem else { return nil }
            samples = modem.generateIdle(duration: duration)

        case .olivia:
            return nil
        }

        return createBuffer(from: samples)
        #else
        return nil
        #endif
    }

    // MARK: - Channel Management

    /// Tune to a specific frequency
    func tune(to frequency: Double) {
        #if canImport(HamDigitalCore)
        rttyModem?.tune(to: frequency)
        #endif
    }

    /// Add a channel to monitor
    func addChannel(at frequency: Double) {
        #if canImport(HamDigitalCore)
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
        #if canImport(HamDigitalCore)
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
        #if canImport(HamDigitalCore)
        rttyModem?.reset()
        multiChannelDemodulator?.reset()
        pskModem?.reset()
        multiChannelPSKDemodulator?.reset()
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

#if canImport(HamDigitalCore)
extension ModemService: MultiChannelRTTYDemodulatorDelegate {
    nonisolated func demodulator(
        _ demodulator: MultiChannelRTTYDemodulator,
        didDecode character: Character,
        onChannel channel: RTTYChannel
    ) {
        Task { @MainActor in
            delegate?.modemService(self, didDecode: character, onChannel: channel.frequency, mode: .rtty)
        }
    }

    nonisolated func demodulator(
        _ demodulator: MultiChannelRTTYDemodulator,
        signalDetected detected: Bool,
        onChannel channel: RTTYChannel
    ) {
        Task { @MainActor in
            delegate?.modemService(self, signalDetected: detected, onChannel: channel.frequency, mode: .rtty)
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
            delegate?.modemService(self, didDecode: character, onChannel: frequency, mode: .rtty)
        }
    }

    nonisolated func modem(
        _ modem: RTTYModem,
        signalDetected detected: Bool,
        atFrequency frequency: Double
    ) {
        Task { @MainActor in
            self.isDecoding = detected
            delegate?.modemService(self, signalDetected: detected, onChannel: frequency, mode: .rtty)
        }
    }
}

// MARK: - MultiChannelPSKDemodulatorDelegate

extension ModemService: MultiChannelPSKDemodulatorDelegate {
    nonisolated func demodulator(
        _ demodulator: MultiChannelPSKDemodulator,
        didDecode character: Character,
        onChannel channel: PSKChannel
    ) {
        Task { @MainActor in
            delegate?.modemService(self, didDecode: character, onChannel: channel.frequency, mode: self.activeMode)
        }
    }

    nonisolated func demodulator(
        _ demodulator: MultiChannelPSKDemodulator,
        signalDetected detected: Bool,
        onChannel channel: PSKChannel
    ) {
        Task { @MainActor in
            delegate?.modemService(self, signalDetected: detected, onChannel: channel.frequency, mode: self.activeMode)
        }
    }

    nonisolated func demodulator(
        _ demodulator: MultiChannelPSKDemodulator,
        didUpdateChannels updatedChannels: [PSKChannel]
    ) {
        Task { @MainActor in
            self.channelFrequencies = updatedChannels.map { $0.frequency }
        }
    }
}

// MARK: - PSKModemDelegate for Single-Channel Mode

extension ModemService: PSKModemDelegate {
    nonisolated func modem(
        _ modem: PSKModem,
        didDecode character: Character,
        atFrequency frequency: Double
    ) {
        Task { @MainActor in
            delegate?.modemService(self, didDecode: character, onChannel: frequency, mode: self.activeMode)
        }
    }

    nonisolated func modem(
        _ modem: PSKModem,
        signalDetected detected: Bool,
        atFrequency frequency: Double
    ) {
        Task { @MainActor in
            self.isDecoding = detected
            delegate?.modemService(self, signalDetected: detected, onChannel: frequency, mode: self.activeMode)
        }
    }
}
#endif
