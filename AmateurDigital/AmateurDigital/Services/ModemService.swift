//
//  ModemService.swift
//  AmateurDigital
//
//  Digital mode modulation/demodulation service
//  Bridges between iOS audio and AmateurDigitalCore library
//

import Foundation
import AVFoundation

#if canImport(AmateurDigitalCore)
import AmateurDigitalCore
#endif

/// Protocol for receiving decoded characters from ModemService
protocol ModemServiceDelegate: AnyObject {
    /// Called when a character is decoded
    /// - Parameters:
    ///   - service: The modem service
    ///   - character: The decoded character
    ///   - frequency: The channel frequency in Hz
    ///   - mode: The digital mode
    ///   - signalStrength: Signal strength (0.0-1.0), used for per-channel squelch
    func modemService(
        _ service: ModemService,
        didDecode character: Character,
        onChannel frequency: Double,
        mode: DigitalMode,
        signalStrength: Float
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

    #if canImport(AmateurDigitalCore)
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
        #if canImport(AmateurDigitalCore)
        return rttyModem != nil
        #else
        return false
        #endif
    }

    #if canImport(AmateurDigitalCore)
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

        #if canImport(AmateurDigitalCore)
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
        #if canImport(AmateurDigitalCore)
        // Rebuild RTTY modem and multi-channel demodulator with new config
        let rttyConfig = currentRTTYConfiguration
        rttyModem = RTTYModem(configuration: rttyConfig)
        rttyModem?.delegate = self
        let rttyFrequencies = stride(from: 900.0, through: 2500.0, by: 100.0).map { $0 }
        multiChannelDemodulator = MultiChannelRTTYDemodulator(
            frequencies: rttyFrequencies,
            configuration: rttyConfig
        )
        multiChannelDemodulator?.delegate = self
        multiChannelDemodulator?.setSquelch(Float(settings.rttySquelch))

        // Rebuild PSK modem and multi-channel demodulator with new config
        pskModem = PSKModem(configuration: currentPSKConfiguration)
        pskModem?.delegate = self
        multiChannelPSKDemodulator = MultiChannelPSKDemodulator.standardSubband(
            configuration: currentPSKConfiguration
        )
        multiChannelPSKDemodulator?.delegate = self
        multiChannelPSKDemodulator?.setSquelch(Float(settings.psk31Squelch))

        // Update channel frequencies for the active mode
        switch activeMode {
        case .rtty:
            channelFrequencies = multiChannelDemodulator?.channels.map { $0.frequency } ?? []
        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            channelFrequencies = multiChannelPSKDemodulator?.channels.map { $0.frequency } ?? []
        case .olivia:
            break
        }
        #endif
    }

    /// Update squelch level for all demodulators
    func updateSquelch() {
        #if canImport(AmateurDigitalCore)
        multiChannelDemodulator?.setSquelch(Float(settings.rttySquelch))
        multiChannelPSKDemodulator?.setSquelch(Float(settings.psk31Squelch))
        #endif
    }

    // MARK: - Setup

    #if canImport(AmateurDigitalCore)
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

        #if canImport(AmateurDigitalCore)
        // First, reset ALL modems to ensure clean state when switching modes
        // This prevents any lingering state from the previous mode
        resetAllModems()

        // Now configure the active mode
        switch mode {
        case .rtty:
            // RTTY uses the existing modem, just update channel frequencies
            channelFrequencies = multiChannelDemodulator?.channels.map { $0.frequency } ?? []

        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            // Create new PSK modem with the correct configuration for this variant
            pskModem = PSKModem(configuration: currentPSKConfiguration)
            pskModem?.delegate = self
            // Create new multi-channel demodulator with correct configuration
            multiChannelPSKDemodulator = MultiChannelPSKDemodulator.standardSubband(configuration: currentPSKConfiguration)
            multiChannelPSKDemodulator?.delegate = self
            multiChannelPSKDemodulator?.setSquelch(Float(settings.psk31Squelch))
            channelFrequencies = multiChannelPSKDemodulator?.channels.map { $0.frequency } ?? []

        case .olivia:
            // Not yet implemented
            channelFrequencies = []
        }
        #endif
    }

    /// Reset all modems to clean state
    private func resetAllModems() {
        #if canImport(AmateurDigitalCore)
        // Reset RTTY modems
        rttyModem?.reset()
        multiChannelDemodulator?.reset()

        // Reset PSK modems - setting to nil releases resources
        pskModem?.reset()
        multiChannelPSKDemodulator?.reset()
        #endif

        signalStrength = 0
        isDecoding = false
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
        #if canImport(AmateurDigitalCore)
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
        #if canImport(AmateurDigitalCore)
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
        return encodeTxSamples(text, atFrequency: nil)
    }

    /// Encode text at a specific frequency and return raw samples
    /// - Parameters:
    ///   - text: Text to encode
    ///   - frequency: Channel frequency in Hz, or nil to use default
    /// - Returns: Audio samples
    func encodeTxSamples(_ text: String, atFrequency frequency: Double?) -> [Float] {
        #if canImport(AmateurDigitalCore)
        switch activeMode {
        case .rtty:
            // Create a temporary modem at the specified frequency for TX
            // This avoids modifying the shared modem used for RX
            let config: RTTYConfiguration
            if let freq = frequency {
                config = currentRTTYConfiguration.withCenterFrequency(freq)
            } else {
                config = currentRTTYConfiguration
            }
            let txModem = RTTYModem(configuration: config)
            return txModem.encodeWithIdle(
                text: text,
                preambleMs: 100,
                postambleMs: 50
            )

        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            // Create a temporary modem at the specified frequency for TX
            let config: PSKConfiguration
            if let freq = frequency {
                config = currentPSKConfiguration.withCenterFrequency(freq)
            } else {
                config = currentPSKConfiguration
            }
            let txModem = PSKModem(configuration: config)
            return txModem.encodeWithEnvelope(
                text: text,
                preambleMs: 100,
                postambleMs: 50
            )

        case .olivia:
            return []
        }
        #else
        return []
        #endif
    }

    /// Generate idle tone for carrier
    func generateIdleTone(duration: Double) -> AVAudioPCMBuffer? {
        #if canImport(AmateurDigitalCore)
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

    /// Generate preamble samples for VOX keying
    ///
    /// Returns mode-appropriate idle/sync data to allow VOX to key before actual data:
    /// - RTTY: LTRS diddle characters (Baudot `11111` repeated) for receiver sync
    /// - PSK: Idle carrier (continuous phase) for phase lock
    /// - Olivia: Sync preamble (not yet implemented)
    ///
    /// - Parameters:
    ///   - durationMs: Preamble duration in milliseconds
    ///   - frequency: Channel frequency in Hz, or nil to use default
    /// - Returns: Audio samples for preamble, or nil if mode doesn't support it
    func generatePreamble(durationMs: Int, atFrequency frequency: Double? = nil) -> [Float]? {
        guard durationMs > 0 else { return nil }

        #if canImport(AmateurDigitalCore)
        let durationSeconds = Double(durationMs) / 1000.0

        switch activeMode {
        case .rtty:
            // Create a temporary modem at the specified frequency for TX
            let config: RTTYConfiguration
            if let freq = frequency {
                config = currentRTTYConfiguration.withCenterFrequency(freq)
            } else {
                config = currentRTTYConfiguration
            }
            let txModem = RTTYModem(configuration: config)
            // Generate LTRS diddles - these maintain receiver bit sync
            // and are non-printing if some are missed
            return txModem.generateIdle(duration: durationSeconds)

        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            // Create a temporary modem at the specified frequency for TX
            let config: PSKConfiguration
            if let freq = frequency {
                config = currentPSKConfiguration.withCenterFrequency(freq)
            } else {
                config = currentPSKConfiguration
            }
            let txModem = PSKModem(configuration: config)
            // Generate idle carrier for PSK phase lock
            return txModem.generateIdle(duration: durationSeconds)

        case .olivia:
            // Not yet implemented
            return nil
        }
        #else
        return nil
        #endif
    }

    // MARK: - Channel Management

    /// Tune to a specific frequency
    func tune(to frequency: Double) {
        #if canImport(AmateurDigitalCore)
        rttyModem?.tune(to: frequency)
        #endif
    }

    /// Add a channel to monitor
    func addChannel(at frequency: Double) {
        #if canImport(AmateurDigitalCore)
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
        #if canImport(AmateurDigitalCore)
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

    /// Reset modem state for current mode
    func reset() {
        resetAllModems()
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

#if canImport(AmateurDigitalCore)
extension ModemService: MultiChannelRTTYDemodulatorDelegate {
    nonisolated func demodulator(
        _ demodulator: MultiChannelRTTYDemodulator,
        didDecode character: Character,
        onChannel channel: RTTYChannel
    ) {
        let strength = channel.signalStrength
        Task { @MainActor in
            delegate?.modemService(self, didDecode: character, onChannel: channel.frequency, mode: .rtty, signalStrength: strength)
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
        let strength = modem.signalStrength
        Task { @MainActor in
            delegate?.modemService(self, didDecode: character, onChannel: frequency, mode: .rtty, signalStrength: strength)
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
        let strength = channel.signalStrength
        let frequency = channel.frequency
        Task { @MainActor in
            delegate?.modemService(self, didDecode: character, onChannel: frequency, mode: self.activeMode, signalStrength: strength)
        }
    }

    nonisolated func demodulator(
        _ demodulator: MultiChannelPSKDemodulator,
        signalDetected detected: Bool,
        onChannel channel: PSKChannel
    ) {
        let frequency = channel.frequency
        Task { @MainActor in
            delegate?.modemService(self, signalDetected: detected, onChannel: frequency, mode: self.activeMode)
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
        let strength = modem.signalStrength
        Task { @MainActor in
            delegate?.modemService(self, didDecode: character, onChannel: frequency, mode: self.activeMode, signalStrength: strength)
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
