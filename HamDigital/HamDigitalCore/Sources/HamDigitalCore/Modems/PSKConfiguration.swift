//
//  PSKConfiguration.swift
//  HamDigitalCore
//
//  Configuration for PSK signal parameters (BPSK/QPSK, 31.25/62.5 baud)
//

import Foundation

/// Modulation type for PSK modes
public enum PSKModulationType: String, Sendable, Equatable, CaseIterable {
    /// Binary Phase Shift Keying - 2 phases (0°, 180°)
    case bpsk
    /// Quadrature Phase Shift Keying - 4 phases (0°, 90°, 180°, 270°)
    case qpsk
}

/// Configuration for PSK signal parameters
///
/// Supports multiple PSK variants:
/// - PSK31: BPSK at 31.25 baud (~31 Hz bandwidth)
/// - BPSK63: BPSK at 62.5 baud (~63 Hz bandwidth)
/// - QPSK31: QPSK at 31.25 baud (~31 Hz bandwidth, 2x throughput)
/// - QPSK63: QPSK at 62.5 baud (~63 Hz bandwidth, 2x throughput)
public struct PSKConfiguration: Equatable, Sendable {

    // MARK: - Properties

    /// Modulation type (BPSK or QPSK)
    public var modulationType: PSKModulationType

    /// Baud rate (31.25 for PSK31/QPSK31, 62.5 for BPSK63/QPSK63)
    public var baudRate: Double

    /// Center frequency in Hz (carrier frequency)
    public var centerFrequency: Double

    /// Audio sample rate in Hz
    public var sampleRate: Double

    // MARK: - Computed Properties

    /// Number of bits per symbol (1 for BPSK, 2 for QPSK)
    public var bitsPerSymbol: Int {
        modulationType == .bpsk ? 1 : 2
    }

    /// Number of samples per symbol at current sample rate
    public var samplesPerSymbol: Int {
        Int((sampleRate / baudRate).rounded())
    }

    /// Symbol duration in seconds
    public var symbolDuration: Double {
        1.0 / baudRate
    }

    /// Approximate signal bandwidth in Hz
    public var bandwidth: Double {
        baudRate
    }

    /// Phase increment per sample for the carrier
    public var phaseIncrementPerSample: Double {
        2.0 * .pi * centerFrequency / sampleRate
    }

    /// Human-readable mode name
    public var modeName: String {
        switch (modulationType, baudRate) {
        case (.bpsk, 31.25): return "PSK31"
        case (.bpsk, 62.5): return "BPSK63"
        case (.qpsk, 31.25): return "QPSK31"
        case (.qpsk, 62.5): return "QPSK63"
        default: return "\(modulationType.rawValue.uppercased())\(Int(baudRate))"
        }
    }

    // MARK: - Preset Configurations

    /// Standard PSK31 configuration (BPSK, 31.25 baud, 1000 Hz center)
    public static let psk31 = PSKConfiguration(
        modulationType: .bpsk,
        baudRate: 31.25,
        centerFrequency: 1000.0,
        sampleRate: 48000.0
    )

    /// BPSK63 configuration (BPSK, 62.5 baud, 1000 Hz center)
    public static let bpsk63 = PSKConfiguration(
        modulationType: .bpsk,
        baudRate: 62.5,
        centerFrequency: 1000.0,
        sampleRate: 48000.0
    )

    /// QPSK31 configuration (QPSK, 31.25 baud, 1000 Hz center)
    public static let qpsk31 = PSKConfiguration(
        modulationType: .qpsk,
        baudRate: 31.25,
        centerFrequency: 1000.0,
        sampleRate: 48000.0
    )

    /// QPSK63 configuration (QPSK, 62.5 baud, 1000 Hz center)
    public static let qpsk63 = PSKConfiguration(
        modulationType: .qpsk,
        baudRate: 62.5,
        centerFrequency: 1000.0,
        sampleRate: 48000.0
    )

    /// Standard configuration (alias for psk31)
    public static let standard = psk31

    // MARK: - Initialization

    /// Create a PSK configuration
    /// - Parameters:
    ///   - modulationType: BPSK or QPSK (default: .bpsk)
    ///   - baudRate: Baud rate (default: 31.25)
    ///   - centerFrequency: Center frequency in Hz (default: 1000)
    ///   - sampleRate: Audio sample rate (default: 48000)
    public init(
        modulationType: PSKModulationType = .bpsk,
        baudRate: Double = 31.25,
        centerFrequency: Double = 1000.0,
        sampleRate: Double = 48000.0
    ) {
        self.modulationType = modulationType
        self.baudRate = baudRate
        self.centerFrequency = centerFrequency
        self.sampleRate = sampleRate
    }

    // MARK: - Factory Methods

    /// Create configuration with a different center frequency
    /// - Parameter freq: New center frequency in Hz
    /// - Returns: New configuration with updated frequency
    public func withCenterFrequency(_ freq: Double) -> PSKConfiguration {
        PSKConfiguration(
            modulationType: modulationType,
            baudRate: baudRate,
            centerFrequency: freq,
            sampleRate: sampleRate
        )
    }

    /// Create configuration with a different sample rate
    /// - Parameter rate: New sample rate
    /// - Returns: New configuration with updated sample rate
    public func withSampleRate(_ rate: Double) -> PSKConfiguration {
        PSKConfiguration(
            modulationType: modulationType,
            baudRate: baudRate,
            centerFrequency: centerFrequency,
            sampleRate: rate
        )
    }

    /// Create configuration with a different modulation type
    /// - Parameter type: New modulation type
    /// - Returns: New configuration with updated modulation type
    public func withModulationType(_ type: PSKModulationType) -> PSKConfiguration {
        PSKConfiguration(
            modulationType: type,
            baudRate: baudRate,
            centerFrequency: centerFrequency,
            sampleRate: sampleRate
        )
    }

    /// Create configuration with a different baud rate
    /// - Parameter rate: New baud rate
    /// - Returns: New configuration with updated baud rate
    public func withBaudRate(_ rate: Double) -> PSKConfiguration {
        PSKConfiguration(
            modulationType: modulationType,
            baudRate: rate,
            centerFrequency: centerFrequency,
            sampleRate: sampleRate
        )
    }
}

// MARK: - CustomStringConvertible

extension PSKConfiguration: CustomStringConvertible {
    public var description: String {
        "\(modeName)(\(baudRate) baud, \(modulationType.rawValue.uppercased()), \(Int(centerFrequency)) Hz center, ~\(Int(bandwidth)) Hz bandwidth)"
    }
}

// MARK: - Backward Compatibility

/// Type alias for backward compatibility with PSK31-specific code
public typealias PSK31Configuration = PSKConfiguration
