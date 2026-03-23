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
@preconcurrency import AmateurDigitalCore
#endif

#if canImport(RattlegramCore)
import RattlegramCore
#endif

import Accelerate

// MARK: - Rattlegram Background Processor

#if canImport(RattlegramCore)
/// Processes Rattlegram audio on a dedicated background queue to avoid blocking the main thread.
/// The OFDM decoder (SchmidlCox correlator, FFT, polar codes) is CPU-intensive and would
/// freeze the UI if run on the main thread at 48kHz sample rate.
final class RattlegramProcessor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.amateurdigital.rattlegram", qos: .userInitiated)
    private var decoder: RattlegramCore.Decoder
    private var pendingCallSign: String?

    /// Pre-allocated buffer for Float→Int16 conversion (avoids per-call allocation)
    private var int16Buffer = [Int16]()
    private var scaledBuffer = [Float]()

    /// Called on main thread when a complete message is decoded
    var onMessage: ((_ text: String, _ callSign: String?, _ bitFlips: Int) -> Void)?
    /// Called on main thread when sync is detected or lost
    var onSyncChanged: ((_ synced: Bool) -> Void)?

    init(sampleRate: Int = 48000) {
        self.decoder = RattlegramCore.Decoder(sampleRate: sampleRate)
    }

    /// Feed audio samples for decoding. Runs on background queue.
    func feed(_ samples: [Float]) {
        queue.async { [self] in
            self.processOnQueue(samples)
        }
    }

    /// Reset the decoder state. Synchronous to ensure clean state before next feed.
    func reset() {
        queue.sync { [self] in
            self.decoder = RattlegramCore.Decoder(sampleRate: 48000)
            self.pendingCallSign = nil
        }
    }

    /// Whether a decoder instance exists
    var isAvailable: Bool { true }

    // MARK: - Private (runs on self.queue)

    private func processOnQueue(_ samples: [Float]) {
        let count = samples.count

        // Resize pre-allocated buffers if needed
        if int16Buffer.count < count {
            int16Buffer = [Int16](repeating: 0, count: count)
            scaledBuffer = [Float](repeating: 0, count: count)
        }

        // Float → Int16 using vDSP (much faster than per-element .map)
        samples.withUnsafeBufferPointer { srcPtr in
            scaledBuffer.withUnsafeMutableBufferPointer { scaledPtr in
                var scale: Float = 32768.0
                vDSP_vsmul(srcPtr.baseAddress!, 1, &scale, scaledPtr.baseAddress!, 1, vDSP_Length(count))
            }
            int16Buffer.withUnsafeMutableBufferPointer { dstPtr in
                scaledBuffer.withUnsafeBufferPointer { scaledPtr in
                    vDSP_vfix16(scaledPtr.baseAddress!, 1, dstPtr.baseAddress!, 1, vDSP_Length(count))
                }
            }
        }

        let ready = decoder.feed(Array(int16Buffer.prefix(count)), sampleCount: count)
        guard ready else { return }

        let status = decoder.process()
        switch status {
        case .sync:
            let info = decoder.staged()
            let cs = info.callSign.trimmingCharacters(in: .whitespaces)
            pendingCallSign = cs.isEmpty ? nil : cs
            print("[RattlegramProcessor] Sync from \(pendingCallSign ?? "unknown"), CFO: \(info.cfo) Hz, mode: \(info.mode)")
            let onSync = self.onSyncChanged
            DispatchQueue.main.async { onSync?(true) }

        case .done:
            var payload = [UInt8](repeating: 0, count: 170)
            let flips = decoder.fetch(&payload)
            if flips >= 0 {
                let text = String(bytes: payload.prefix(while: { $0 != 0 }), encoding: .utf8) ?? ""
                if !text.isEmpty {
                    let callSign = pendingCallSign
                    print("[RattlegramProcessor] Decoded: \"\(text)\" from \(callSign ?? "unknown"), \(flips) bit flips")
                    let onMsg = self.onMessage
                    let onSync = self.onSyncChanged
                    DispatchQueue.main.async {
                        onMsg?(text, callSign, flips)
                        onSync?(false)
                    }
                }
            }
            pendingCallSign = nil

        case .ping:
            let info = decoder.staged()
            let cs = info.callSign.trimmingCharacters(in: .whitespaces)
            if !cs.isEmpty {
                print("[RattlegramProcessor] Ping from \(cs)")
                let onMsg = self.onMessage
                let onSync = self.onSyncChanged
                DispatchQueue.main.async {
                    onMsg?("[PING]", cs, 0)
                    onSync?(false)
                }
            }

        case .fail, .nope:
            let onSync = self.onSyncChanged
            DispatchQueue.main.async { onSync?(false) }

        default:
            break
        }
    }
}
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

    /// Called when a complete message is decoded (burst modes like Rattlegram)
    func modemService(
        _ service: ModemService,
        didDecodeMessage text: String,
        callSign: String?,
        bitFlips: Int,
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
class ModemService: ObservableObject, @unchecked Sendable {

    // MARK: - Published Properties (written on main thread only)

    @Published var activeMode: DigitalMode = .rtty
    @Published var isDecoding: Bool = false
    @Published var signalStrength: Float = 0

    /// Active channels being monitored (frequency in Hz)
    @Published var channelFrequencies: [Double] = []

    // MARK: - DSP Queue

    /// Serial queue for all DSP processing. Modem objects are accessed only on this queue.
    let dspQueue = DispatchQueue(label: "com.amateurdigital.dsp", qos: .userInitiated)

    /// Shadow copy of activeMode for DSP queue (avoids data race on @Published)
    private var dspActiveMode: DigitalMode = .rtty

    /// Cached configs for lazy modem creation on DSP queue (set from main in setMode)
    #if canImport(AmateurDigitalCore)
    private var cachedRTTYConfig: RTTYConfiguration?
    private var cachedPSKConfig: PSKConfiguration?
    private var cachedCWConfig: CWConfiguration?
    private var cachedRTTYSquelch: Float = 0
    private var cachedPSKSquelch: Float = 0
    private var cachedCWToneFreq: Double = 700.0
    #endif

    /// Last values dispatched to main (avoids redundant @Published writes)
    private var lastDispatchedStrength: Float = 0
    private var lastDispatchedDecoding: Bool = false

    /// Accumulated decoded characters from modem callbacks, flushed after each process() call
    private var pendingChars: [(char: Character, freq: Double, mode: DigitalMode, strength: Float)] = []

    // MARK: - Delegate

    weak var delegate: ModemServiceDelegate?

    // MARK: - Settings

    private let settings = MainActor.assumeIsolated { SettingsManager.shared }

    // MARK: - RTTY Modem

    #if canImport(AmateurDigitalCore)
    private var rttyModem: RTTYModem?
    private var multiChannelDemodulator: MultiChannelRTTYDemodulator?
    private var dualRTTYDecoder: DualRTTYDecoder?

    // MARK: - PSK Modem (supports PSK31, BPSK63, QPSK31, QPSK63)

    private var pskModem: PSKModem?
    private var multiChannelPSKDemodulator: MultiChannelPSKDemodulator?

    // MARK: - CW Modem

    private var cwModem: CWModem?
    private var bayesianCWDecoder: BayesianCWDecoder?
    private var dualCWDecoder: DualCWDecoder?
    /// Which CW decoder is active on DSP queue: "classic", "bayesian", or "diversity"
    private var dspCWDecoderType: String = "classic"

    /// Which RTTY decoder type is active on DSP queue: "classic", "selective", or "diversity"
    private var dspRTTYDecoderType: String = "classic"

    // MARK: - JS8Call Modem

    private var js8callModem: JS8CallModem?

    // MARK: - FT8 Modem

    private var ft8Modem: FT8Modem?
    #endif

    // MARK: - Rattlegram Modem

    #if canImport(RattlegramCore)
    private var rattlegramProcessor: RattlegramProcessor?
    #endif

    /// JS8Call period in milliseconds (for UTC-aligned TX timing)
    var js8callPeriodMs: Int {
        #if canImport(AmateurDigitalCore)
        return (js8callModem?.currentConfiguration.submode.period ?? 15) * 1000
        #else
        return 15000
        #endif
    }

    /// Audio format for processing (48kHz mono Float32)
    private let processingFormat: AVAudioFormat?

    /// Whether a modem is available for the active mode
    var isModemAvailable: Bool {
        switch activeMode {
        case .rattlegram:
            #if canImport(RattlegramCore)
            return rattlegramProcessor != nil
            #else
            return false
            #endif
        case .cw:
            #if canImport(AmateurDigitalCore)
            return cwModem != nil || bayesianCWDecoder != nil || dualCWDecoder != nil
            #else
            return false
            #endif
        case .js8call:
            #if canImport(AmateurDigitalCore)
            return js8callModem != nil
            #else
            return false
            #endif
        case .ft8:
            #if canImport(AmateurDigitalCore)
            return ft8Modem != nil
            #else
            return false
            #endif
        default:
            #if canImport(AmateurDigitalCore)
            return rttyModem != nil
            #else
            return false
            #endif
        }
    }

    #if canImport(AmateurDigitalCore)
    /// Create CWConfiguration from current settings. Must be called on main thread.
    @MainActor private var currentCWConfiguration: CWConfiguration {
        CWConfiguration(
            toneFrequency: settings.cwToneFrequency,
            wpm: settings.cwWPM,
            sampleRate: 48000.0
        )
    }

    /// Create RTTYConfiguration from current settings. Must be called on main thread.
    @MainActor private var currentRTTYConfiguration: RTTYConfiguration {
        RTTYConfiguration(
            baudRate: settings.rttyBaudRate,
            markFrequency: settings.rttyMarkFreq,
            shift: settings.rttyShift,
            sampleRate: 48000.0
        )
    }

    /// Create PSKConfiguration for the current active mode. Must be called on main thread.
    @MainActor private var currentPSKConfiguration: PSKConfiguration {
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
        // Modems are created lazily when setMode() is called.
        // Don't create any modems during init to avoid:
        // 1. Processing audio before the user selects a mode
        // 2. Blocking app launch with heavy modem initialization
        #else
        print("[ModemService] DigiModesCore not available - running in placeholder mode")
        // Setup default channel frequencies for placeholder mode
        channelFrequencies = [1275, 1445, 1615, 1785, 1955, 2125, 2295, 2465]
        #endif

        #if canImport(RattlegramCore)
        self.rattlegramProcessor = RattlegramProcessor(sampleRate: 48000)
        setupRattlegramCallbacks()
        #endif
    }

    #if canImport(RattlegramCore)
    /// Wire up Rattlegram processor callbacks to delegate
    private func setupRattlegramCallbacks() {
        rattlegramProcessor?.onMessage = { [weak self] text, callSign, bitFlips in
            guard let self = self else { return }
            self.delegate?.modemService(
                self,
                didDecodeMessage: text,
                callSign: callSign,
                bitFlips: bitFlips,
                onChannel: 1500.0,
                mode: .rattlegram
            )
        }
        rattlegramProcessor?.onSyncChanged = { [weak self] synced in
            guard let self = self else { return }
            self.isDecoding = synced
        }
    }
    #endif

    /// Reconfigure modem with current settings (call when settings change).
    /// Only reconfigures the active mode's modem to avoid unnecessary work.
    @MainActor func reconfigureModem() {
        #if canImport(AmateurDigitalCore)
        let mode = activeMode

        // Capture settings on main thread
        let rttyConfig = currentRTTYConfiguration
        let pskConfig = currentPSKConfiguration
        let cwConfig = currentCWConfiguration
        let pskSquelch = Float(settings.psk31Squelch)
        let rttySquelch = Float(settings.rttySquelch)
        let polarityInverted = settings.rttyPolarityInverted
        let freqOffset = settings.rttyFrequencyOffset
        let cwDecoderType = settings.cwDecoderType
        let rttyDecoderType = settings.rttyDecoderType

        // Synchronize modem creation with DSP queue
        dspQueue.sync { [self] in
            switch mode {
            case .rtty:
                rttyModem = RTTYModem(configuration: rttyConfig)
                rttyModem?.delegate = self
                dspRTTYDecoderType = rttyDecoderType

                if rttyDecoderType == "diversity" {
                    multiChannelDemodulator = nil
                    dualRTTYDecoder = DualRTTYDecoder(configuration: rttyConfig)
                    dualRTTYDecoder?.delegate = self
                    dualRTTYDecoder?.squelchLevel = rttySquelch
                    if polarityInverted {
                        dualRTTYDecoder?.polarityInverted = true
                    }
                } else {
                    dualRTTYDecoder = nil
                    multiChannelDemodulator = MultiChannelRTTYDemodulator.standardSubband()
                    multiChannelDemodulator?.delegate = self
                    multiChannelDemodulator?.setSquelch(rttySquelch)

                    if polarityInverted || freqOffset != 0 {
                        for channel in multiChannelDemodulator?.channels ?? [] {
                            if polarityInverted {
                                multiChannelDemodulator?.setPolarity(inverted: true, forChannel: channel.id)
                            }
                            if freqOffset != 0 {
                                multiChannelDemodulator?.setFrequencyOffset(Double(freqOffset), forChannel: channel.id)
                            }
                        }
                    }
                }

            case .psk31, .bpsk63, .qpsk31, .qpsk63:
                pskModem = PSKModem(configuration: pskConfig)
                pskModem?.delegate = self
                multiChannelPSKDemodulator = MultiChannelPSKDemodulator.standardSubband(
                    configuration: pskConfig
                )
                multiChannelPSKDemodulator?.delegate = self
                multiChannelPSKDemodulator?.setSquelch(pskSquelch)

            case .cw:
                dspCWDecoderType = cwDecoderType
                if cwDecoderType == "diversity" {
                    cwModem = nil
                    bayesianCWDecoder = nil
                    dualCWDecoder = DualCWDecoder(configuration: cwConfig)
                    dualCWDecoder?.onCharacterDecoded = { [weak self] char, freq in
                        self?.pendingChars.append((char, freq, .cw, self?.dualCWDecoder?.signalStrength ?? 0))
                    }
                    dualCWDecoder?.onSignalDetected = { [weak self] detected, freq in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.isDecoding = detected
                            self.delegate?.modemService(self, signalDetected: detected, onChannel: freq, mode: .cw)
                        }
                    }
                } else if cwDecoderType == "bayesian" {
                    cwModem = nil
                    dualCWDecoder = nil
                    bayesianCWDecoder = BayesianCWDecoder(configuration: cwConfig)
                    bayesianCWDecoder?.onCharacterDecoded = { [weak self] char, freq in
                        self?.pendingChars.append((char, freq, .cw, self?.bayesianCWDecoder?.signalStrength ?? 0))
                    }
                    bayesianCWDecoder?.onSignalDetected = { [weak self] detected, freq in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.isDecoding = detected
                            self.delegate?.modemService(self, signalDetected: detected, onChannel: freq, mode: .cw)
                        }
                    }
                } else {
                    bayesianCWDecoder = nil
                    dualCWDecoder = nil
                    cwModem = CWModem(configuration: cwConfig)
                    cwModem?.delegate = self
                }

            case .js8call:
                js8callModem = JS8CallModem(configuration: .normal)
                js8callModem?.delegate = self

            case .ft8:
                ft8Modem = FT8Modem()
                ft8Modem?.delegate = self

            case .olivia, .rattlegram:
                break
            }
        }

        // Update @Published on main
        switch mode {
        case .rtty:
            if dualRTTYDecoder != nil {
                channelFrequencies = [dualRTTYDecoder!.centerFrequency]
            } else {
                channelFrequencies = multiChannelDemodulator?.channels.map { $0.frequency } ?? []
            }
        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            channelFrequencies = multiChannelPSKDemodulator?.channels.map { $0.frequency } ?? []
        case .cw:
            channelFrequencies = [settings.cwToneFrequency]
        case .js8call:
            channelFrequencies = [1000.0]
        case .ft8:
            channelFrequencies = [1500.0]
        case .olivia:
            break
        case .rattlegram:
            channelFrequencies = [1500.0]
        }
        #endif
    }

    /// Update squelch level for all demodulators. Must be called from main thread.
    @MainActor func updateSquelch() {
        #if canImport(AmateurDigitalCore)
        let rttySquelch = Float(settings.rttySquelch)
        let pskSquelch = Float(settings.psk31Squelch)
        dspQueue.async { [self] in
            multiChannelDemodulator?.setSquelch(rttySquelch)
            dualRTTYDecoder?.squelchLevel = rttySquelch
            multiChannelPSKDemodulator?.setSquelch(pskSquelch)
        }
        #endif
    }

    // MARK: - Setup

    #if canImport(AmateurDigitalCore)
    /// Set up multi-channel RTTY demodulator. Runs on dspQueue. Uses cached squelch.
    private func setupMultiChannelDemodulatorInternal() {
        multiChannelDemodulator = MultiChannelRTTYDemodulator.standardSubband()
        multiChannelDemodulator?.delegate = self
        multiChannelDemodulator?.setSquelch(cachedRTTYSquelch)
    }
    #endif

    // MARK: - Mode Selection

    /// Switch active digital mode. Must be called from main thread.
    @MainActor func setMode(_ mode: DigitalMode) {
        activeMode = mode
        print("[ModemService] Mode changed to \(mode.rawValue)")

        // Capture settings on main thread before dispatching to DSP queue
        #if canImport(AmateurDigitalCore)
        let rttyConfig = currentRTTYConfiguration
        let pskConfig = currentPSKConfiguration
        let cwConfig = currentCWConfiguration
        let pskSquelch = Float(settings.psk31Squelch)
        let rttySquelch = Float(settings.rttySquelch)
        let cwToneFreq = settings.cwToneFrequency
        let cwDecoderType = settings.cwDecoderType
        let rttyDecoderType = settings.rttyDecoderType
        #endif

        // Synchronize modem creation with DSP queue (blocks briefly to prevent races)
        dspQueue.sync { [self] in
            // Cache configs for lazy modem creation on DSP queue
            #if canImport(AmateurDigitalCore)
            cachedRTTYConfig = rttyConfig
            cachedPSKConfig = pskConfig
            cachedCWConfig = cwConfig
            cachedRTTYSquelch = rttySquelch
            cachedPSKSquelch = pskSquelch
            cachedCWToneFreq = cwToneFreq
            dspCWDecoderType = cwDecoderType
            dspRTTYDecoderType = rttyDecoderType
            #endif
            dspActiveMode = mode
            pendingChars.removeAll(keepingCapacity: true)

            #if canImport(AmateurDigitalCore)
            resetAllModemsInternal()

            switch mode {
            case .rtty:
                if rttyModem == nil {
                    rttyModem = RTTYModem(configuration: rttyConfig)
                }
                if rttyDecoderType == "diversity" {
                    // Diversity: run both classic + selective on primary frequency
                    dualRTTYDecoder = DualRTTYDecoder(configuration: rttyConfig)
                    dualRTTYDecoder?.delegate = self
                    dualRTTYDecoder?.squelchLevel = rttySquelch
                } else if multiChannelDemodulator == nil {
                    multiChannelDemodulator = MultiChannelRTTYDemodulator.standardSubband()
                    multiChannelDemodulator?.delegate = self
                    multiChannelDemodulator?.setSquelch(rttySquelch)
                }

            case .psk31, .bpsk63, .qpsk31, .qpsk63:
                pskModem = PSKModem(configuration: pskConfig)
                pskModem?.delegate = self
                multiChannelPSKDemodulator = MultiChannelPSKDemodulator.standardSubband(configuration: pskConfig)
                multiChannelPSKDemodulator?.delegate = self
                multiChannelPSKDemodulator?.setSquelch(pskSquelch)

            case .cw:
                if cwDecoderType == "diversity" {
                    dualCWDecoder = DualCWDecoder(configuration: cwConfig)
                    dualCWDecoder?.onCharacterDecoded = { [weak self] char, freq in
                        self?.pendingChars.append((char, freq, .cw, self?.dualCWDecoder?.signalStrength ?? 0))
                    }
                    dualCWDecoder?.onSignalDetected = { [weak self] detected, freq in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.isDecoding = detected
                            self.delegate?.modemService(self, signalDetected: detected, onChannel: freq, mode: .cw)
                        }
                    }
                } else if cwDecoderType == "bayesian" {
                    bayesianCWDecoder = BayesianCWDecoder(configuration: cwConfig)
                    bayesianCWDecoder?.onCharacterDecoded = { [weak self] char, freq in
                        self?.pendingChars.append((char, freq, .cw, self?.bayesianCWDecoder?.signalStrength ?? 0))
                    }
                    bayesianCWDecoder?.onSignalDetected = { [weak self] detected, freq in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.isDecoding = detected
                            self.delegate?.modemService(self, signalDetected: detected, onChannel: freq, mode: .cw)
                        }
                    }
                } else {
                    cwModem = CWModem(configuration: cwConfig)
                    cwModem?.delegate = self
                }

            case .olivia:
                break

            case .rattlegram:
                #if canImport(RattlegramCore)
                rattlegramProcessor?.reset()
                #endif

            case .js8call:
                js8callModem = JS8CallModem(configuration: .normal)
                js8callModem?.delegate = self

            case .ft8:
                ft8Modem = FT8Modem()
                ft8Modem?.delegate = self
            }
            #endif
        }

        // Update @Published on main thread
        #if canImport(AmateurDigitalCore)
        switch mode {
        case .rtty:
            if dualRTTYDecoder != nil {
                channelFrequencies = [dualRTTYDecoder!.centerFrequency]
            } else {
                channelFrequencies = multiChannelDemodulator?.channels.map { $0.frequency } ?? []
            }
        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            channelFrequencies = multiChannelPSKDemodulator?.channels.map { $0.frequency } ?? []
        case .cw:
            channelFrequencies = [settings.cwToneFrequency]
        case .olivia:
            channelFrequencies = []
        case .rattlegram:
            channelFrequencies = [1500.0]
        case .js8call:
            channelFrequencies = [1000.0]
        case .ft8:
            channelFrequencies = [1500.0]
        }
        #endif
    }

    /// Reset all modems to clean state
    /// Reset all modems. Must be called from dspQueue.
    private func resetAllModemsInternal() {
        #if canImport(AmateurDigitalCore)
        rttyModem?.reset()
        multiChannelDemodulator?.reset()
        dualRTTYDecoder?.reset()
        pskModem?.reset()
        multiChannelPSKDemodulator?.reset()
        cwModem?.reset()
        bayesianCWDecoder?.reset()
        dualCWDecoder?.reset()
        js8callModem?.reset()
        ft8Modem?.reset()
        #endif

        #if canImport(RattlegramCore)
        rattlegramProcessor?.reset()
        #endif

        lastDispatchedStrength = 0
        lastDispatchedDecoding = false
        DispatchQueue.main.async { [weak self] in
            self?.signalStrength = 0
            self?.isDecoding = false
        }
    }

    private func resetAllModems() {
        dspQueue.sync { [self] in
            resetAllModemsInternal()
        }
    }

    /// Ensure the modem for the active mode is created (lazy initialization).
    /// Called on every audio buffer to handle the case where audio starts
    /// before setMode() is called (e.g., during app launch).
    /// Ensure modem exists for current mode. Runs on dspQueue.
    /// Uses cached configs (set from main thread in setMode/reconfigureModem).
    private func ensureModemCreated() {
        #if canImport(AmateurDigitalCore)
        switch dspActiveMode {
        case .rtty:
            if rttyModem == nil, let config = cachedRTTYConfig {
                rttyModem = RTTYModem(configuration: config)
                if dspRTTYDecoderType == "diversity" {
                    dualRTTYDecoder = DualRTTYDecoder(configuration: config)
                    dualRTTYDecoder?.delegate = self
                    dualRTTYDecoder?.squelchLevel = cachedRTTYSquelch
                    let freq = config.markFrequency
                    DispatchQueue.main.async { [weak self] in self?.channelFrequencies = [freq] }
                } else {
                    multiChannelDemodulator = MultiChannelRTTYDemodulator.standardSubband()
                    multiChannelDemodulator?.delegate = self
                    multiChannelDemodulator?.setSquelch(cachedRTTYSquelch)
                    let freqs = multiChannelDemodulator?.channels.map { $0.frequency } ?? []
                    DispatchQueue.main.async { [weak self] in self?.channelFrequencies = freqs }
                }
            }
        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            if pskModem == nil, let config = cachedPSKConfig {
                pskModem = PSKModem(configuration: config)
                pskModem?.delegate = self
                multiChannelPSKDemodulator = MultiChannelPSKDemodulator.standardSubband(configuration: config)
                multiChannelPSKDemodulator?.delegate = self
                multiChannelPSKDemodulator?.setSquelch(cachedPSKSquelch)
                let freqs = multiChannelPSKDemodulator?.channels.map { $0.frequency } ?? []
                DispatchQueue.main.async { [weak self] in self?.channelFrequencies = freqs }
            }
        case .cw:
            if cwModem == nil && bayesianCWDecoder == nil && dualCWDecoder == nil, let config = cachedCWConfig {
                if dspCWDecoderType == "diversity" {
                    dualCWDecoder = DualCWDecoder(configuration: config)
                    dualCWDecoder?.onCharacterDecoded = { [weak self] char, freq in
                        self?.pendingChars.append((char, freq, .cw, self?.dualCWDecoder?.signalStrength ?? 0))
                    }
                    dualCWDecoder?.onSignalDetected = { [weak self] detected, freq in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.isDecoding = detected
                            self.delegate?.modemService(self, signalDetected: detected, onChannel: freq, mode: .cw)
                        }
                    }
                } else if dspCWDecoderType == "bayesian" {
                    bayesianCWDecoder = BayesianCWDecoder(configuration: config)
                    bayesianCWDecoder?.onCharacterDecoded = { [weak self] char, freq in
                        self?.pendingChars.append((char, freq, .cw, self?.bayesianCWDecoder?.signalStrength ?? 0))
                    }
                    bayesianCWDecoder?.onSignalDetected = { [weak self] detected, freq in
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.isDecoding = detected
                            self.delegate?.modemService(self, signalDetected: detected, onChannel: freq, mode: .cw)
                        }
                    }
                } else {
                    cwModem = CWModem(configuration: config)
                    cwModem?.delegate = self
                }
                let freq = cachedCWToneFreq
                DispatchQueue.main.async { [weak self] in self?.channelFrequencies = [freq] }
            }
        case .js8call:
            if js8callModem == nil {
                js8callModem = JS8CallModem(configuration: .normal)
                js8callModem?.delegate = self
                DispatchQueue.main.async { [weak self] in self?.channelFrequencies = [1000.0] }
            }
        case .ft8:
            if ft8Modem == nil {
                ft8Modem = FT8Modem()
                ft8Modem?.delegate = self
                DispatchQueue.main.async { [weak self] in self?.channelFrequencies = [1500.0] }
            }
        case .olivia, .rattlegram:
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

    /// Feed audio samples for DSP processing. Safe to call from any thread.
    /// Dispatches to the internal DSP queue — does NOT block the caller.
    func feedSamples(_ samples: [Float]) {
        dspQueue.async { [self] in
            self.processRxSamplesOnDSP(samples)
        }
    }

    /// Process raw Float array samples. MUST run on dspQueue.
    private func processRxSamplesOnDSP(_ samples: [Float]) {
        #if canImport(AmateurDigitalCore)
        // Ensure the modem for the active mode exists (lazy creation)
        ensureModemCreated()

        var newStrength: Float = 0
        var newDecoding = false

        switch dspActiveMode {
        case .rtty:
            if dspRTTYDecoderType == "diversity", let dual = dualRTTYDecoder {
                // Diversity mode: run DualRTTYDecoder on primary frequency
                dual.process(samples: samples)
                newStrength = dual.signalStrength
                newDecoding = dual.signalDetected
            } else if let multiDemod = multiChannelDemodulator {
                multiDemod.process(samples: samples)
            } else {
                rttyModem?.process(samples: samples)
            }
            if dspRTTYDecoderType != "diversity" {
                newStrength = rttyModem?.signalStrength ?? 0
                newDecoding = rttyModem?.isSignalDetected ?? false
            }

        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            if let multiDemod = multiChannelPSKDemodulator {
                multiDemod.process(samples: samples)
            } else {
                pskModem?.process(samples: samples)
            }
            newStrength = pskModem?.signalStrength ?? 0
            newDecoding = pskModem?.isSignalDetected ?? false

        case .cw:
            if dspCWDecoderType == "diversity", let dual = dualCWDecoder {
                dual.process(samples: samples)
                newStrength = dual.signalStrength
                newDecoding = dual.signalDetected
            } else if dspCWDecoderType == "bayesian", let bayes = bayesianCWDecoder {
                bayes.process(samples: samples)
                newStrength = bayes.signalStrength
                newDecoding = bayes.signalDetected
            } else {
                cwModem?.process(samples: samples)
                newStrength = cwModem?.signalStrength ?? 0
                newDecoding = cwModem?.isSignalDetected ?? false
            }

        case .olivia:
            break

        case .rattlegram:
            break  // Handled below with separate canImport

        case .js8call:
            js8callModem?.process(samples: samples)
            newStrength = 0
            newDecoding = js8callModem?.isSignalDetected ?? false

        case .ft8:
            ft8Modem?.process(samples: samples)
            newStrength = 0
            newDecoding = ft8Modem?.signalDetected ?? false
        }

        // Flush accumulated character callbacks in a single main-thread dispatch
        if !pendingChars.isEmpty {
            let batch = pendingChars
            pendingChars.removeAll(keepingCapacity: true)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                for c in batch {
                    self.delegate?.modemService(self, didDecode: c.char, onChannel: c.freq, mode: c.mode, signalStrength: c.strength)
                }
            }
        }

        // Throttled @Published updates (only dispatch to main when values change)
        let strengthChanged = abs(lastDispatchedStrength - newStrength) > 0.01
        let decodingChanged = lastDispatchedDecoding != newDecoding
        if strengthChanged || decodingChanged {
            lastDispatchedStrength = newStrength
            lastDispatchedDecoding = newDecoding
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if strengthChanged { self.signalStrength = newStrength }
                if decodingChanged { self.isDecoding = newDecoding }
            }
        }
        #endif

        #if canImport(RattlegramCore)
        if dspActiveMode == .rattlegram {
            rattlegramProcessor?.feed(samples)
        }
        #endif
    }

    /// Legacy entry point — redirects to feedSamples for backward compatibility
    func processRxSamples(_ samples: [Float]) {
        feedSamples(samples)
    }

    // MARK: - Encoding (TX)

    /// Encode text for transmission
    ///
    /// Returns an audio buffer containing the encoded signal
    /// ready to be played through the audio output.
    ///
    /// - Parameter text: Text to encode
    /// - Returns: Audio buffer, or nil if encoding fails
    @MainActor func encodeTxText(_ text: String) -> AVAudioPCMBuffer? {
        var samples: [Float] = []

        #if canImport(RattlegramCore)
        if activeMode == .rattlegram {
            samples = encodeRattlegramSamples(text, atFrequency: nil)
            if samples.isEmpty { return nil }
            return createBuffer(from: samples)
        }
        #endif

        #if canImport(AmateurDigitalCore)
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

        case .cw:
            let txModem = CWModem(configuration: currentCWConfiguration)
            samples = txModem.encodeWithEnvelope(
                text: text,
                preambleMs: Double(settings.txPreambleMs),
                postambleMs: 200
            )

        case .js8call:
            guard let modem = js8callModem else { return nil }
            samples = modem.encodeWithEnvelope(
                text: text,
                frameType: 0,
                preambleMs: 0,
                postambleMs: 200
            )

        case .ft8:
            let modem = ft8Modem ?? FT8Modem()
            samples = modem.encodeWithEnvelope(
                message: text,
                frequency: 1500.0,
                preambleMs: 0,
                postambleMs: 200
            )

        case .olivia, .rattlegram:
            return nil
        }

        return createBuffer(from: samples)
        #else
        return nil
        #endif
    }

    /// Encode text and return raw samples
    @MainActor func encodeTxSamples(_ text: String) -> [Float] {
        return encodeTxSamples(text, atFrequency: nil)
    }

    /// Encode text at a specific frequency and return raw samples
    /// - Parameters:
    ///   - text: Text to encode
    ///   - frequency: Channel frequency in Hz, or nil to use default
    /// - Returns: Audio samples
    @MainActor func encodeTxSamples(_ text: String, atFrequency frequency: Double?) -> [Float] {
        #if canImport(RattlegramCore)
        if activeMode == .rattlegram {
            return encodeRattlegramSamples(text, atFrequency: frequency)
        }
        #endif

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

        case .cw:
            let config: CWConfiguration
            if let freq = frequency {
                config = currentCWConfiguration.withToneFrequency(freq)
            } else {
                config = currentCWConfiguration
            }
            let txModem = CWModem(configuration: config)
            return txModem.encodeWithEnvelope(
                text: text,
                preambleMs: Double(settings.txPreambleMs),
                postambleMs: 200
            )

        case .js8call:
            let config: JS8CallConfiguration
            if let freq = frequency {
                config = JS8CallConfiguration.normal.withCarrierFrequency(freq)
            } else {
                config = .normal
            }
            let txModem = JS8CallModem(configuration: config)
            return txModem.encodeWithEnvelope(
                text: text,
                frameType: 0,
                preambleMs: 0,
                postambleMs: 200
            )

        case .ft8:
            let txModem = FT8Modem()
            return txModem.encodeWithEnvelope(
                message: text,
                frequency: frequency ?? 1500.0,
                preambleMs: 0,
                postambleMs: 200
            )

        case .olivia, .rattlegram:
            return []
        }
        #else
        return []
        #endif
    }

    /// Generate idle tone for carrier
    @MainActor func generateIdleTone(duration: Double) -> AVAudioPCMBuffer? {
        #if canImport(AmateurDigitalCore)
        var samples: [Float] = []

        switch activeMode {
        case .rtty:
            guard let modem = rttyModem else { return nil }
            samples = modem.generateIdle(duration: duration)

        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            guard let modem = pskModem else { return nil }
            samples = modem.generateIdle(duration: duration)

        case .cw, .olivia, .rattlegram, .js8call, .ft8:
            // CW/JS8Call/FT8 don't have a continuous idle tone
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
    @MainActor func generatePreamble(durationMs: Int, atFrequency frequency: Double? = nil) -> [Float]? {
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

        case .cw, .olivia, .rattlegram, .js8call, .ft8:
            // CW/Rattlegram/JS8Call/FT8 have built-in sync, no preamble needed
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

    // MARK: - Per-Channel RTTY Settings

    /// Set baud rate for a specific RTTY channel by frequency
    func setChannelBaudRate(_ baudRate: Double, atFrequency frequency: Double) {
        #if canImport(AmateurDigitalCore)
        guard let demod = multiChannelDemodulator,
              let channelId = demod.channelId(near: frequency) else { return }
        demod.setBaudRate(baudRate, forChannel: channelId)
        #endif
    }

    /// Set polarity inversion for a specific RTTY channel by frequency
    func setChannelPolarity(inverted: Bool, atFrequency frequency: Double) {
        #if canImport(AmateurDigitalCore)
        guard let demod = multiChannelDemodulator,
              let channelId = demod.channelId(near: frequency) else { return }
        demod.setPolarity(inverted: inverted, forChannel: channelId)
        #endif
    }

    /// Set frequency offset for a specific RTTY channel by frequency
    func setChannelFrequencyOffset(_ offset: Double, atFrequency frequency: Double) {
        #if canImport(AmateurDigitalCore)
        guard let demod = multiChannelDemodulator,
              let channelId = demod.channelId(near: frequency) else { return }
        demod.setFrequencyOffset(offset, forChannel: channelId)
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

    // MARK: - Rattlegram Processing

    #if canImport(RattlegramCore)
    /// Encode text for Rattlegram transmission
    @MainActor private func encodeRattlegramSamples(_ text: String, atFrequency frequency: Double?) -> [Float] {
        let encoder = RattlegramCore.Encoder(sampleRate: 48000)

        // Build 170-byte null-padded payload
        var payload = [UInt8](repeating: 0, count: 170)
        let bytes = Array(text.utf8)
        for i in 0..<min(bytes.count, 170) {
            payload[i] = bytes[i]
        }

        let carrierFreq = Int(frequency ?? 1500.0)
        let callSign = settings.callsign

        encoder.configure(
            payload: payload,
            callSign: callSign,
            carrierFrequency: carrierFreq,
            noiseSymbols: 6,
            fancyHeader: true
        )

        var allSamples = [Float]()
        var buf = [Int16](repeating: 0, count: encoder.extendedLength)
        while encoder.produce(&buf) {
            allSamples.append(contentsOf: buf.map { Float($0) / 32768.0 })
        }
        // Final (silence) symbol
        allSamples.append(contentsOf: buf.map { Float($0) / 32768.0 })

        // Normalize to match RTTY/PSK output levels (~0.9 peak)
        // OFDM encoder conservatively peaks at ~50% to avoid clipping
        let peak = allSamples.map { abs($0) }.max() ?? 0
        if peak > 0 {
            let scale = Float(0.9) / peak
            for i in 0..<allSamples.count {
                allSamples[i] *= scale
            }
        }

        return allSamples
    }
    #endif
}

// MARK: - MultiChannelRTTYDemodulatorDelegate

#if canImport(AmateurDigitalCore)
extension ModemService: MultiChannelRTTYDemodulatorDelegate {
    nonisolated func demodulator(
        _ demodulator: MultiChannelRTTYDemodulator,
        didDecode character: Character,
        onChannel channel: RTTYChannel
    ) {
        // Accumulate on dspQueue; flushed in processRxSamplesOnDSP
        pendingChars.append((character, channel.frequency, .rtty, channel.signalStrength))
    }

    nonisolated func demodulator(
        _ demodulator: MultiChannelRTTYDemodulator,
        signalDetected detected: Bool,
        onChannel channel: RTTYChannel
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.modemService(self, signalDetected: detected, onChannel: channel.frequency, mode: .rtty)
        }
    }

    nonisolated func demodulator(
        _ demodulator: MultiChannelRTTYDemodulator,
        didUpdateChannels updatedChannels: [RTTYChannel]
    ) {
        let freqs = updatedChannels.map { $0.frequency }
        DispatchQueue.main.async { [weak self] in
            self?.channelFrequencies = freqs
        }
    }
}

// MARK: - DualRTTYDecoderDelegate (Diversity Mode)

extension ModemService: DualRTTYDecoderDelegate {
    nonisolated func dualDecoder(_ decoder: DualRTTYDecoder, didDecode character: Character, atFrequency frequency: Double) {
        pendingChars.append((character, frequency, .rtty, decoder.signalStrength))
    }

    nonisolated func dualDecoder(_ decoder: DualRTTYDecoder, signalDetected detected: Bool, atFrequency frequency: Double) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isDecoding = detected
            self.delegate?.modemService(self, signalDetected: detected, onChannel: frequency, mode: .rtty)
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
        pendingChars.append((character, frequency, .rtty, modem.signalStrength))
    }

    nonisolated func modem(
        _ modem: RTTYModem,
        signalDetected detected: Bool,
        atFrequency frequency: Double
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isDecoding = detected
            self.delegate?.modemService(self, signalDetected: detected, onChannel: frequency, mode: .rtty)
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
        pendingChars.append((character, channel.frequency, dspActiveMode, channel.signalStrength))
    }

    nonisolated func demodulator(
        _ demodulator: MultiChannelPSKDemodulator,
        signalDetected detected: Bool,
        onChannel channel: PSKChannel
    ) {
        let frequency = channel.frequency
        let mode = dspActiveMode
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.modemService(self, signalDetected: detected, onChannel: frequency, mode: mode)
        }
    }

    nonisolated func demodulator(
        _ demodulator: MultiChannelPSKDemodulator,
        didUpdateChannels updatedChannels: [PSKChannel]
    ) {
        let freqs = updatedChannels.map { $0.frequency }
        DispatchQueue.main.async { [weak self] in
            self?.channelFrequencies = freqs
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
        pendingChars.append((character, frequency, dspActiveMode, modem.signalStrength))
    }

    nonisolated func modem(
        _ modem: PSKModem,
        signalDetected detected: Bool,
        atFrequency frequency: Double
    ) {
        let mode = dspActiveMode
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isDecoding = detected
            self.delegate?.modemService(self, signalDetected: detected, onChannel: frequency, mode: mode)
        }
    }
}

// MARK: - JS8CallModemDelegate

extension ModemService: JS8CallModemDelegate {
    nonisolated func modem(
        _ modem: JS8CallModem,
        didDecode frame: JS8CallFrame
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.modemService(
                self,
                didDecodeMessage: frame.message,
                callSign: nil,
                bitFlips: Int((1.0 - frame.quality) * 60),
                onChannel: frame.frequency,
                mode: .js8call
            )
        }
    }

    nonisolated func modem(
        _ modem: JS8CallModem,
        signalDetected detected: Bool,
        count: Int
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isDecoding = detected
            self.delegate?.modemService(self, signalDetected: detected, onChannel: 1000.0, mode: .js8call)
        }
    }
}

// MARK: - CWModemDelegate

extension ModemService: CWModemDelegate {
    nonisolated func modem(
        _ modem: CWModem,
        didDecode character: Character,
        atFrequency frequency: Double
    ) {
        pendingChars.append((character, frequency, .cw, modem.signalStrength))
    }

    nonisolated func modem(
        _ modem: CWModem,
        signalDetected detected: Bool,
        atFrequency frequency: Double
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isDecoding = detected
            self.delegate?.modemService(self, signalDetected: detected, onChannel: frequency, mode: .cw)
        }
    }
}

// BayesianCWDecoder uses closure callbacks (onCharacterDecoded, onSignalDetected)
// wired up at creation time above — no delegate extension needed.

// MARK: - FT8ModemDelegate

extension ModemService: FT8ModemDelegate {
    nonisolated func modem(
        _ modem: FT8Modem,
        didDecode message: FT8Message,
        frequency: Double,
        snr: Double,
        timeOffset: Double
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.modemService(
                self,
                didDecodeMessage: message.displayText,
                callSign: nil,
                bitFlips: 0,
                onChannel: frequency,
                mode: .ft8
            )
        }
    }

    nonisolated func modem(
        _ modem: FT8Modem,
        signalDetected detected: Bool,
        count: Int
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isDecoding = detected
            self.delegate?.modemService(self, signalDetected: detected, onChannel: 1500.0, mode: .ft8)
        }
    }
}
#endif
