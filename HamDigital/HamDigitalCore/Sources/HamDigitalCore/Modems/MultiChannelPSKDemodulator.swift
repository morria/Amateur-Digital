//
//  MultiChannelPSKDemodulator.swift
//  HamDigitalCore
//
//  Simultaneous PSK decoding on multiple frequencies
//

import Foundation

/// Channel information for multi-channel PSK demodulation
public struct PSKChannel: Identifiable, Equatable {
    public let id: UUID
    public let frequency: Double
    public var signalStrength: Float
    public var signalDetected: Bool
    public var lastCharacter: Character?
    public var lastActivity: Date?

    public init(
        id: UUID = UUID(),
        frequency: Double,
        signalStrength: Float = 0,
        signalDetected: Bool = false,
        lastCharacter: Character? = nil,
        lastActivity: Date? = nil
    ) {
        self.id = id
        self.frequency = frequency
        self.signalStrength = signalStrength
        self.signalDetected = signalDetected
        self.lastCharacter = lastCharacter
        self.lastActivity = lastActivity
    }
}

/// Delegate protocol for multi-channel PSK demodulation events
public protocol MultiChannelPSKDemodulatorDelegate: AnyObject {
    /// Called when a character is decoded on a channel
    /// - Parameters:
    ///   - demodulator: The multi-channel demodulator
    ///   - character: The decoded character
    ///   - channel: The channel where the character was decoded
    func demodulator(
        _ demodulator: MultiChannelPSKDemodulator,
        didDecode character: Character,
        onChannel channel: PSKChannel
    )

    /// Called when signal detection changes on a channel
    /// - Parameters:
    ///   - demodulator: The multi-channel demodulator
    ///   - detected: Whether signal is detected
    ///   - channel: The channel where detection changed
    func demodulator(
        _ demodulator: MultiChannelPSKDemodulator,
        signalDetected detected: Bool,
        onChannel channel: PSKChannel
    )

    /// Called when channel list is updated
    /// - Parameters:
    ///   - demodulator: The multi-channel demodulator
    ///   - channels: Updated list of all channels
    func demodulator(
        _ demodulator: MultiChannelPSKDemodulator,
        didUpdateChannels channels: [PSKChannel]
    )
}

/// Multi-channel PSK demodulator for simultaneous decoding
///
/// Monitors multiple frequencies in the audio passband simultaneously,
/// decoding PSK signals on each channel. PSK's narrow bandwidth (~31-63 Hz)
/// allows many channels to be packed closely together (50 Hz spacing typical).
///
/// Supports PSK31, BPSK63, QPSK31, and QPSK63 modes.
///
/// Example usage:
/// ```swift
/// let demodulator = MultiChannelPSKDemodulator(
///     frequencies: [1000, 1050, 1100, 1150, 1200],  // 50 Hz spacing
///     configuration: .psk31
/// )
/// demodulator.delegate = self
///
/// // Process incoming audio
/// demodulator.process(samples: audioBuffer)
///
/// // Characters arrive via delegate for each channel
/// ```
public final class MultiChannelPSKDemodulator {

    // MARK: - Properties

    private let baseConfiguration: PSKConfiguration
    private var demodulators: [UUID: PSKDemodulator] = [:]
    private var channelMap: [UUID: PSKChannel] = [:]

    /// Delegate for receiving decoded characters and events
    public weak var delegate: MultiChannelPSKDemodulatorDelegate?

    /// All active channels
    public var channels: [PSKChannel] {
        Array(channelMap.values).sorted { $0.frequency < $1.frequency }
    }

    /// Number of active channels
    public var channelCount: Int {
        channelMap.count
    }

    /// Current configuration
    public var configuration: PSKConfiguration {
        baseConfiguration
    }

    // MARK: - Initialization

    /// Create a multi-channel demodulator with specified frequencies
    /// - Parameters:
    ///   - frequencies: Array of center frequencies in Hz
    ///   - configuration: Base PSK configuration (default: PSK31)
    public init(
        frequencies: [Double],
        configuration: PSKConfiguration = .standard
    ) {
        self.baseConfiguration = configuration

        for frequency in frequencies {
            addChannel(at: frequency)
        }
    }

    /// Create a multi-channel demodulator covering a frequency range
    /// - Parameters:
    ///   - startFrequency: Starting frequency in Hz
    ///   - endFrequency: Ending frequency in Hz
    ///   - spacing: Frequency spacing between channels in Hz (default: 50)
    ///   - configuration: Base PSK configuration
    public convenience init(
        startFrequency: Double,
        endFrequency: Double,
        spacing: Double = 50,
        configuration: PSKConfiguration = .standard
    ) {
        var frequencies: [Double] = []
        var freq = startFrequency
        while freq <= endFrequency {
            frequencies.append(freq)
            freq += spacing
        }
        self.init(frequencies: frequencies, configuration: configuration)
    }

    // MARK: - Channel Management

    /// Add a new channel at the specified frequency
    /// - Parameter frequency: Center frequency in Hz
    /// - Returns: The created channel
    @discardableResult
    public func addChannel(at frequency: Double) -> PSKChannel {
        let channel = PSKChannel(frequency: frequency)

        let config = baseConfiguration.withCenterFrequency(frequency)
        let demodulator = PSKDemodulator(configuration: config)
        demodulator.delegate = self

        demodulators[channel.id] = demodulator
        channelMap[channel.id] = channel

        delegate?.demodulator(self, didUpdateChannels: channels)

        return channel
    }

    /// Remove a channel
    /// - Parameter channelId: ID of the channel to remove
    public func removeChannel(_ channelId: UUID) {
        demodulators.removeValue(forKey: channelId)
        channelMap.removeValue(forKey: channelId)

        delegate?.demodulator(self, didUpdateChannels: channels)
    }

    /// Remove all channels
    public func removeAllChannels() {
        demodulators.removeAll()
        channelMap.removeAll()

        delegate?.demodulator(self, didUpdateChannels: channels)
    }

    /// Get channel by frequency
    /// - Parameter frequency: Frequency to search for
    /// - Returns: Channel at that frequency, or nil
    public func channel(at frequency: Double) -> PSKChannel? {
        channelMap.values.first { abs($0.frequency - frequency) < 1.0 }
    }

    /// Get channel by ID
    /// - Parameter id: Channel ID
    /// - Returns: Channel with that ID, or nil
    public func channel(withId id: UUID) -> PSKChannel? {
        channelMap[id]
    }

    // MARK: - Processing

    /// Process audio samples through all channels
    /// - Parameter samples: Audio samples to process
    public func process(samples: [Float]) {
        for (channelId, demodulator) in demodulators {
            demodulator.process(samples: samples)

            // Update channel signal info
            if var channel = channelMap[channelId] {
                channel.signalStrength = demodulator.signalStrength
                channel.signalDetected = demodulator.signalDetected
                channelMap[channelId] = channel
            }
        }
    }

    // MARK: - Control

    /// Reset all demodulators
    public func reset() {
        for demodulator in demodulators.values {
            demodulator.reset()
        }

        for channelId in channelMap.keys {
            channelMap[channelId]?.signalStrength = 0
            channelMap[channelId]?.signalDetected = false
        }
    }

    /// Set squelch level for all channels
    /// - Parameter level: Squelch level (0.0-1.0)
    public func setSquelch(_ level: Float) {
        for demodulator in demodulators.values {
            demodulator.squelchLevel = level
        }
    }

    // MARK: - Channel Finding

    /// Find channel ID for a demodulator
    private func findChannelId(for demodulator: PSKDemodulator) -> UUID? {
        for (id, demod) in demodulators {
            if demod === demodulator {
                return id
            }
        }
        return nil
    }
}

// MARK: - PSKDemodulatorDelegate

extension MultiChannelPSKDemodulator: PSKDemodulatorDelegate {
    public func demodulator(
        _ demodulator: PSKDemodulator,
        didDecode character: Character,
        atFrequency frequency: Double
    ) {
        guard let channelId = findChannelId(for: demodulator),
              var channel = channelMap[channelId] else {
            return
        }

        channel.lastCharacter = character
        channel.lastActivity = Date()
        channelMap[channelId] = channel

        delegate?.demodulator(self, didDecode: character, onChannel: channel)
    }

    public func demodulator(
        _ demodulator: PSKDemodulator,
        signalDetected detected: Bool,
        atFrequency frequency: Double
    ) {
        guard let channelId = findChannelId(for: demodulator),
              var channel = channelMap[channelId] else {
            return
        }

        channel.signalDetected = detected
        channelMap[channelId] = channel

        delegate?.demodulator(self, signalDetected: detected, onChannel: channel)
    }
}

// MARK: - Convenience Extensions

extension MultiChannelPSKDemodulator {

    /// Standard PSK sub-band channels (50 Hz spacing)
    /// - Parameter configuration: PSK configuration to use (default: PSK31)
    /// - Returns: Multi-channel demodulator for common PSK frequencies
    public static func standardSubband(configuration: PSKConfiguration = .standard) -> MultiChannelPSKDemodulator {
        // Common PSK audio frequencies with 50 Hz spacing
        let frequencies: [Double] = [
            800, 850, 900, 950, 1000, 1050, 1100, 1150,
            1200, 1250, 1300, 1350, 1400, 1450, 1500, 1550
        ]
        return MultiChannelPSKDemodulator(frequencies: frequencies, configuration: configuration)
    }

    /// Create demodulator for a specific frequency range with auto-spacing
    /// - Parameters:
    ///   - range: Frequency range in Hz
    ///   - spacing: Channel spacing (default: 50 Hz)
    ///   - configuration: PSK configuration to use
    /// - Returns: Multi-channel demodulator
    public static func covering(
        range: ClosedRange<Double>,
        spacing: Double = 50,
        configuration: PSKConfiguration = .standard
    ) -> MultiChannelPSKDemodulator {
        return MultiChannelPSKDemodulator(
            startFrequency: range.lowerBound,
            endFrequency: range.upperBound,
            spacing: spacing,
            configuration: configuration
        )
    }

    /// Create PSK31 multi-channel demodulator
    public static func psk31() -> MultiChannelPSKDemodulator {
        standardSubband(configuration: .psk31)
    }

    /// Create BPSK63 multi-channel demodulator
    public static func bpsk63() -> MultiChannelPSKDemodulator {
        standardSubband(configuration: .bpsk63)
    }

    /// Create QPSK31 multi-channel demodulator
    public static func qpsk31() -> MultiChannelPSKDemodulator {
        standardSubband(configuration: .qpsk31)
    }

    /// Create QPSK63 multi-channel demodulator
    public static func qpsk63() -> MultiChannelPSKDemodulator {
        standardSubband(configuration: .qpsk63)
    }
}

// MARK: - Backward Compatibility

/// Type alias for backward compatibility
public typealias PSK31Channel = PSKChannel
public typealias MultiChannelPSK31Demodulator = MultiChannelPSKDemodulator
public typealias MultiChannelPSK31DemodulatorDelegate = MultiChannelPSKDemodulatorDelegate
