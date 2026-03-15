//
//  CWConfiguration.swift
//  AmateurDigitalCore
//
//  Configuration for CW (Morse code) signal parameters
//

import Foundation

/// Configuration for CW (Morse code) signal parameters
///
/// CW uses on-off keying (OOK) of a single audio tone.
/// Timing follows the PARIS standard: 50 dit units per word.
///
/// - Dit: 1 unit
/// - Dah: 3 units
/// - Intra-character gap: 1 unit
/// - Inter-character gap: 3 units
/// - Word gap: 7 units
public struct CWConfiguration: Equatable, Sendable {

    // MARK: - Properties

    /// CW tone frequency in Hz (the audio pitch of the tone)
    public var toneFrequency: Double

    /// Speed in words per minute (PARIS standard)
    public var wpm: Double

    /// Audio sample rate in Hz
    public var sampleRate: Double

    /// Rise/fall time for keying envelope in seconds
    /// Shapes the leading/trailing edge of each element to prevent clicks
    public var riseTime: Double

    /// Dash-to-dot ratio (standard = 3.0, some ops use 2.8-3.2)
    public var dashDotRatio: Double

    // MARK: - Computed Properties

    /// Dit duration in seconds
    public var ditDuration: Double {
        MorseCodec.ditDuration(forWPM: wpm)
    }

    /// Dah duration in seconds
    public var dahDuration: Double {
        ditDuration * dashDotRatio
    }

    /// Intra-character gap in seconds (between elements within a character)
    public var intraCharGap: Double {
        ditDuration
    }

    /// Inter-character gap in seconds (between characters)
    public var interCharGap: Double {
        ditDuration * 3
    }

    /// Word gap in seconds
    public var wordGap: Double {
        ditDuration * 7
    }

    /// Number of samples per dit at current sample rate
    public var samplesPerDit: Int {
        Int((ditDuration * sampleRate).rounded())
    }

    /// Number of samples per dah at current sample rate
    public var samplesPerDah: Int {
        Int((dahDuration * sampleRate).rounded())
    }

    /// Number of rise/fall samples for envelope shaping
    public var riseSamples: Int {
        let n = Int((riseTime * sampleRate).rounded())
        // Don't let rise time exceed 40% of a dit
        return min(n, samplesPerDit * 2 / 5)
    }

    /// Approximate signal bandwidth in Hz (main lobe of keying spectrum)
    public var bandwidth: Double {
        // CW bandwidth ≈ baud rate = 1/dit_duration
        // Practical bandwidth including sidebands: ~4/dit_duration
        4.0 / ditDuration
    }

    /// Goertzel filter block size for tone detection
    /// Balances frequency resolution vs time response
    public var goertzelBlockSize: Int {
        // Target ~10ms blocks for time resolution at any speed
        // At 48kHz: 480 samples = 10ms, 100 Hz bandwidth
        let blockMs = 10.0
        let blockSamples = Int(sampleRate * blockMs / 1000.0)
        // But don't exceed 1/4 of a dit for fast WPM
        let maxBlock = samplesPerDit / 4
        return max(64, min(blockSamples, max(64, maxBlock)))
    }

    // MARK: - Preset Configurations

    /// Standard CW at 20 WPM, 700 Hz tone
    public static let standard = CWConfiguration(
        toneFrequency: 700.0,
        wpm: 20.0,
        sampleRate: 48000.0,
        riseTime: 0.005,
        dashDotRatio: 3.0
    )

    /// Slow CW at 13 WPM (common for beginners/nets)
    public static let slow = CWConfiguration(
        toneFrequency: 700.0,
        wpm: 13.0,
        sampleRate: 48000.0,
        riseTime: 0.005,
        dashDotRatio: 3.0
    )

    /// Fast CW at 30 WPM (contest speed)
    public static let fast = CWConfiguration(
        toneFrequency: 700.0,
        wpm: 30.0,
        sampleRate: 48000.0,
        riseTime: 0.004,
        dashDotRatio: 3.0
    )

    /// QRS (very slow) at 5 WPM
    public static let qrs = CWConfiguration(
        toneFrequency: 700.0,
        wpm: 5.0,
        sampleRate: 48000.0,
        riseTime: 0.008,
        dashDotRatio: 3.0
    )

    // MARK: - Initialization

    /// Create a CW configuration
    /// - Parameters:
    ///   - toneFrequency: CW tone frequency in Hz (default: 700)
    ///   - wpm: Speed in words per minute (default: 20)
    ///   - sampleRate: Audio sample rate in Hz (default: 48000)
    ///   - riseTime: Keying envelope rise/fall time in seconds (default: 0.005)
    ///   - dashDotRatio: Ratio of dah to dit duration (default: 3.0)
    public init(
        toneFrequency: Double = 700.0,
        wpm: Double = 20.0,
        sampleRate: Double = 48000.0,
        riseTime: Double = 0.005,
        dashDotRatio: Double = 3.0
    ) {
        self.toneFrequency = toneFrequency
        self.wpm = wpm
        self.sampleRate = sampleRate
        self.riseTime = riseTime
        self.dashDotRatio = dashDotRatio
    }

    // MARK: - Factory Methods

    public func withToneFrequency(_ freq: Double) -> CWConfiguration {
        CWConfiguration(toneFrequency: freq, wpm: wpm, sampleRate: sampleRate, riseTime: riseTime, dashDotRatio: dashDotRatio)
    }

    public func withWPM(_ speed: Double) -> CWConfiguration {
        CWConfiguration(toneFrequency: toneFrequency, wpm: speed, sampleRate: sampleRate, riseTime: riseTime, dashDotRatio: dashDotRatio)
    }

    public func withSampleRate(_ rate: Double) -> CWConfiguration {
        CWConfiguration(toneFrequency: toneFrequency, wpm: wpm, sampleRate: rate, riseTime: riseTime, dashDotRatio: dashDotRatio)
    }

    public func withRiseTime(_ time: Double) -> CWConfiguration {
        CWConfiguration(toneFrequency: toneFrequency, wpm: wpm, sampleRate: sampleRate, riseTime: time, dashDotRatio: dashDotRatio)
    }

    public func withDashDotRatio(_ ratio: Double) -> CWConfiguration {
        CWConfiguration(toneFrequency: toneFrequency, wpm: wpm, sampleRate: sampleRate, riseTime: riseTime, dashDotRatio: ratio)
    }
}

// MARK: - CustomStringConvertible

extension CWConfiguration: CustomStringConvertible {
    public var description: String {
        "CW(\(Int(wpm)) WPM, \(Int(toneFrequency)) Hz, \(Int(bandwidth)) Hz BW)"
    }
}
