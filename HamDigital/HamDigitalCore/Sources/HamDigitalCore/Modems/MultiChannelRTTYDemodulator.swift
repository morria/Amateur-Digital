//
//  MultiChannelRTTYDemodulator.swift
//  DigiModesCore
//
//  Simultaneous RTTY decoding on multiple frequencies
//

import Foundation

/// Channel information for multi-channel demodulation
public struct RTTYChannel: Identifiable, Equatable {
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

/// Delegate protocol for multi-channel RTTY demodulation events
public protocol MultiChannelRTTYDemodulatorDelegate: AnyObject {
    /// Called when a character is decoded on a channel
    /// - Parameters:
    ///   - demodulator: The multi-channel demodulator
    ///   - character: The decoded character
    ///   - channel: The channel where the character was decoded
    func demodulator(
        _ demodulator: MultiChannelRTTYDemodulator,
        didDecode character: Character,
        onChannel channel: RTTYChannel
    )

    /// Called when signal detection changes on a channel
    /// - Parameters:
    ///   - demodulator: The multi-channel demodulator
    ///   - detected: Whether signal is detected
    ///   - channel: The channel where detection changed
    func demodulator(
        _ demodulator: MultiChannelRTTYDemodulator,
        signalDetected detected: Bool,
        onChannel channel: RTTYChannel
    )

    /// Called when channel list is updated
    /// - Parameters:
    ///   - demodulator: The multi-channel demodulator
    ///   - channels: Updated list of all channels
    func demodulator(
        _ demodulator: MultiChannelRTTYDemodulator,
        didUpdateChannels channels: [RTTYChannel]
    )
}

/// Multi-channel RTTY demodulator for simultaneous decoding
///
/// Monitors multiple frequencies in the audio passband simultaneously,
/// decoding RTTY signals on each channel. Useful for monitoring
/// the entire RTTY sub-band or specific frequencies of interest.
///
/// Example usage:
/// ```swift
/// let demodulator = MultiChannelRTTYDemodulator(
///     frequencies: [1275, 1445, 1615, 1785, 1955]  // 170 Hz spacing
/// )
/// demodulator.delegate = self
///
/// // Process incoming audio
/// demodulator.process(samples: audioBuffer)
///
/// // Characters arrive via delegate for each channel
/// ```
public final class MultiChannelRTTYDemodulator {

    // MARK: - Properties

    private let baseConfiguration: RTTYConfiguration
    private var demodulators: [UUID: FSKDemodulator] = [:]
    private var channelMap: [UUID: RTTYChannel] = [:]

    /// Delegate for receiving decoded characters and events
    public weak var delegate: MultiChannelRTTYDemodulatorDelegate?

    /// All active channels
    public var channels: [RTTYChannel] {
        Array(channelMap.values).sorted { $0.frequency < $1.frequency }
    }

    /// Number of active channels
    public var channelCount: Int {
        channelMap.count
    }

    // MARK: - Initialization

    /// Create a multi-channel demodulator with specified frequencies
    /// - Parameters:
    ///   - frequencies: Array of center (mark) frequencies in Hz
    ///   - configuration: Base RTTY configuration (default: standard)
    public init(
        frequencies: [Double],
        configuration: RTTYConfiguration = .standard
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
    ///   - spacing: Frequency spacing between channels in Hz
    ///   - configuration: Base RTTY configuration
    public convenience init(
        startFrequency: Double,
        endFrequency: Double,
        spacing: Double,
        configuration: RTTYConfiguration = .standard
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
    /// - Parameter frequency: Center (mark) frequency in Hz
    /// - Returns: The created channel
    @discardableResult
    public func addChannel(at frequency: Double) -> RTTYChannel {
        let channel = RTTYChannel(frequency: frequency)

        let config = baseConfiguration.withCenterFrequency(frequency)
        let demodulator = FSKDemodulator(configuration: config)
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
    public func channel(at frequency: Double) -> RTTYChannel? {
        channelMap.values.first { abs($0.frequency - frequency) < 1.0 }
    }

    /// Get channel by ID
    /// - Parameter id: Channel ID
    /// - Returns: Channel with that ID, or nil
    public func channel(withId id: UUID) -> RTTYChannel? {
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
    private func findChannelId(for demodulator: FSKDemodulator) -> UUID? {
        for (id, demod) in demodulators {
            if demod === demodulator {
                return id
            }
        }
        return nil
    }
}

// MARK: - FSKDemodulatorDelegate

extension MultiChannelRTTYDemodulator: FSKDemodulatorDelegate {
    public func demodulator(
        _ demodulator: FSKDemodulator,
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
        _ demodulator: FSKDemodulator,
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

extension MultiChannelRTTYDemodulator {

    /// Standard RTTY sub-band channels (170 Hz spacing)
    /// - Returns: Multi-channel demodulator for common RTTY frequencies
    public static func standardSubband() -> MultiChannelRTTYDemodulator {
        // Common RTTY audio frequencies in the 300-3000 Hz passband
        let frequencies: [Double] = [
            1275, 1445, 1615, 1785, 1955, 2125, 2295, 2465
        ]
        return MultiChannelRTTYDemodulator(frequencies: frequencies)
    }

    /// Create demodulator for a specific frequency range with auto-spacing
    /// - Parameters:
    ///   - range: Frequency range in Hz
    ///   - shift: RTTY shift to use for spacing (default: 170 Hz)
    /// - Returns: Multi-channel demodulator
    public static func covering(
        range: ClosedRange<Double>,
        shift: Double = 170
    ) -> MultiChannelRTTYDemodulator {
        return MultiChannelRTTYDemodulator(
            startFrequency: range.lowerBound,
            endFrequency: range.upperBound,
            spacing: shift
        )
    }
}
