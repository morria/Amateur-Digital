//
//  RTTYConfiguration.swift
//  DigiModesCore
//
//  Configuration for RTTY signal parameters
//

import Foundation

/// Configuration for RTTY signal parameters
///
/// Standard amateur RTTY uses 45.45 baud with 170 Hz shift.
/// Mark frequency is typically 2125 Hz, space is 1955 Hz.
public struct RTTYConfiguration: Equatable, Sendable {

    // MARK: - Properties

    /// Baud rate (bits per second)
    /// Standard amateur values: 45.45, 50, 75, 100
    public var baudRate: Double

    /// Mark frequency in Hz (logic "1", higher tone)
    public var markFrequency: Double

    /// Frequency shift in Hz between mark and space
    public var shift: Double

    /// Audio sample rate in Hz
    public var sampleRate: Double

    // MARK: - Computed Properties

    /// Space frequency in Hz (logic "0", lower tone)
    /// Space = Mark - Shift
    public var spaceFrequency: Double {
        markFrequency - shift
    }

    /// Number of samples per bit at current baud rate
    public var samplesPerBit: Int {
        Int((sampleRate / baudRate).rounded())
    }

    /// Bit duration in seconds
    public var bitDuration: Double {
        1.0 / baudRate
    }

    /// Samples per character (1 start + 5 data + 1.5 stop = 7.5 bits)
    public var samplesPerCharacter: Int {
        Int(7.5 * Double(samplesPerBit))
    }

    /// Approximate characters per second
    public var charactersPerSecond: Double {
        baudRate / 7.5
    }

    // MARK: - Preset Configurations

    /// Standard 45.45 baud amateur RTTY
    public static let standard = RTTYConfiguration(
        baudRate: 45.45,
        markFrequency: 2125.0,
        shift: 170.0,
        sampleRate: 48000.0
    )

    /// 50 baud RTTY (common in Europe)
    public static let baud50 = RTTYConfiguration(
        baudRate: 50.0,
        markFrequency: 2125.0,
        shift: 170.0,
        sampleRate: 48000.0
    )

    /// 75 baud RTTY
    public static let baud75 = RTTYConfiguration(
        baudRate: 75.0,
        markFrequency: 2125.0,
        shift: 170.0,
        sampleRate: 48000.0
    )

    /// 100 baud RTTY
    public static let baud100 = RTTYConfiguration(
        baudRate: 100.0,
        markFrequency: 2125.0,
        shift: 170.0,
        sampleRate: 48000.0
    )

    /// Standard with 425 Hz shift (wider shift for poor conditions)
    public static let wide425 = RTTYConfiguration(
        baudRate: 45.45,
        markFrequency: 2125.0,
        shift: 425.0,
        sampleRate: 48000.0
    )

    /// Standard with 850 Hz shift (very wide shift)
    public static let wide850 = RTTYConfiguration(
        baudRate: 45.45,
        markFrequency: 2125.0,
        shift: 850.0,
        sampleRate: 48000.0
    )

    // MARK: - Initialization

    /// Create an RTTY configuration
    /// - Parameters:
    ///   - baudRate: Baud rate (default: 45.45)
    ///   - markFrequency: Mark frequency in Hz (default: 2125)
    ///   - shift: Frequency shift in Hz (default: 170)
    ///   - sampleRate: Audio sample rate (default: 48000)
    public init(
        baudRate: Double = 45.45,
        markFrequency: Double = 2125.0,
        shift: Double = 170.0,
        sampleRate: Double = 48000.0
    ) {
        self.baudRate = baudRate
        self.markFrequency = markFrequency
        self.shift = shift
        self.sampleRate = sampleRate
    }

    // MARK: - Factory Methods

    /// Create configuration with a different center frequency
    ///
    /// Useful for multi-channel operation where each channel
    /// is at a different audio frequency.
    /// - Parameter centerFreq: New mark frequency
    /// - Returns: New configuration with updated frequencies
    public func withCenterFrequency(_ centerFreq: Double) -> RTTYConfiguration {
        RTTYConfiguration(
            baudRate: baudRate,
            markFrequency: centerFreq,
            shift: shift,
            sampleRate: sampleRate
        )
    }

    /// Create configuration with a different baud rate
    /// - Parameter rate: New baud rate
    /// - Returns: New configuration with updated baud rate
    public func withBaudRate(_ rate: Double) -> RTTYConfiguration {
        RTTYConfiguration(
            baudRate: rate,
            markFrequency: markFrequency,
            shift: shift,
            sampleRate: sampleRate
        )
    }

    /// Create configuration with a different shift
    /// - Parameter newShift: New shift in Hz
    /// - Returns: New configuration with updated shift
    public func withShift(_ newShift: Double) -> RTTYConfiguration {
        RTTYConfiguration(
            baudRate: baudRate,
            markFrequency: markFrequency,
            shift: newShift,
            sampleRate: sampleRate
        )
    }

    /// Create configuration with a different sample rate
    /// - Parameter rate: New sample rate
    /// - Returns: New configuration with updated sample rate
    public func withSampleRate(_ rate: Double) -> RTTYConfiguration {
        RTTYConfiguration(
            baudRate: baudRate,
            markFrequency: markFrequency,
            shift: shift,
            sampleRate: rate
        )
    }
}

// MARK: - CustomStringConvertible

extension RTTYConfiguration: CustomStringConvertible {
    public var description: String {
        "RTTY(\(baudRate) baud, \(Int(markFrequency))/\(Int(spaceFrequency)) Hz, \(Int(shift)) Hz shift)"
    }
}
