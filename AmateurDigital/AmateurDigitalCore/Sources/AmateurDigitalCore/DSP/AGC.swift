//
//  AGC.swift
//  AmateurDigitalCore
//
//  Dual-loop Automatic Gain Control for HF signal normalization.
//  Fast loop handles QSB fading; slow loop tracks noise floor for squelch.
//

import Foundation

/// Dual-loop automatic gain control for normalizing signal levels before demodulation.
///
/// The fast loop tracks rapid signal changes (QSB fading) and normalizes to a constant level.
/// The slow loop tracks the overall noise floor for squelch decisions and SNR measurement.
///
/// Usage:
/// ```swift
/// var agc = DualLoopAGC()
/// let normalized = agc.process(samples)
/// let noiseFloor = agc.noiseFloor
/// let snr = agc.estimatedSNR
/// ```
public struct DualLoopAGC {

    /// Target output RMS level
    public var targetLevel: Float

    /// Fast loop: tracks signal envelope for normalization
    private var fastGain: Float = 1.0
    /// Fast loop attack rate (how quickly gain decreases for strong signals)
    private let fastAttack: Float
    /// Fast loop decay rate (how quickly gain increases for weak signals)
    private let fastDecay: Float

    /// Slow loop: tracks noise floor
    private var slowLevel: Float = 0.01
    /// Slow loop attack rate
    private let slowAttack: Float
    /// Slow loop decay rate
    private let slowDecay: Float

    /// Current noise floor estimate (RMS)
    public var noiseFloor: Float { slowLevel }

    /// Peak signal level (fast-tracked)
    private var peakLevel: Float = 0.01

    /// Estimated SNR in dB (signal peak vs noise floor)
    public var estimatedSNR: Float {
        guard slowLevel > 0.0001 else { return 60.0 }
        return 20.0 * log10(max(peakLevel, 0.0001) / slowLevel)
    }

    /// Gain limits
    private let minGain: Float
    private let maxGain: Float

    /// Create a dual-loop AGC.
    /// - Parameters:
    ///   - targetLevel: Desired output RMS (default 0.3)
    ///   - fastAttackMs: Fast loop attack time in ms (default 10)
    ///   - fastDecayMs: Fast loop decay time in ms (default 300)
    ///   - slowAttackMs: Slow loop attack time in ms (default 500)
    ///   - slowDecayMs: Slow loop decay time in ms (default 3000)
    ///   - sampleRate: Audio sample rate (default 48000)
    ///   - minGain: Minimum gain (default 0.01)
    ///   - maxGain: Maximum gain (default 100)
    public init(
        targetLevel: Float = 0.3,
        fastAttackMs: Float = 10,
        fastDecayMs: Float = 300,
        slowAttackMs: Float = 500,
        slowDecayMs: Float = 3000,
        sampleRate: Float = 48000,
        minGain: Float = 0.01,
        maxGain: Float = 100
    ) {
        self.targetLevel = targetLevel
        // Convert ms to per-sample alpha: alpha = 1 - exp(-1 / (timeConstant * sampleRate))
        self.fastAttack = 1.0 - exp(-1000.0 / (fastAttackMs * sampleRate))
        self.fastDecay  = 1.0 - exp(-1000.0 / (fastDecayMs * sampleRate))
        self.slowAttack = 1.0 - exp(-1000.0 / (slowAttackMs * sampleRate))
        self.slowDecay  = 1.0 - exp(-1000.0 / (slowDecayMs * sampleRate))
        self.minGain = minGain
        self.maxGain = maxGain
    }

    /// Process a buffer of samples through the AGC.
    /// - Parameter samples: Input audio samples
    /// - Returns: Gain-normalized samples
    public mutating func process(_ samples: [Float]) -> [Float] {
        var output = [Float](repeating: 0, count: samples.count)
        for i in 0..<samples.count {
            output[i] = processSample(samples[i])
        }
        return output
    }

    /// Process a single sample.
    public mutating func processSample(_ sample: Float) -> Float {
        let level = abs(sample)

        // Fast loop: track signal envelope
        if level > peakLevel {
            peakLevel += (level - peakLevel) * fastAttack
        } else {
            peakLevel += (level - peakLevel) * fastDecay
        }
        peakLevel = max(0.0001, peakLevel)

        // Compute gain to reach target level
        let desiredGain = targetLevel / peakLevel
        let alpha = desiredGain < fastGain ? fastAttack : fastDecay
        fastGain += (desiredGain - fastGain) * alpha
        fastGain = max(minGain, min(maxGain, fastGain))

        // Slow loop: track noise floor (uses the quieter of recent levels)
        if level < slowLevel {
            slowLevel += (level - slowLevel) * slowAttack
        } else {
            slowLevel += (level - slowLevel) * slowDecay
        }
        slowLevel = max(0.00001, slowLevel)

        return sample * fastGain
    }

    /// Reset AGC state.
    public mutating func reset() {
        fastGain = 1.0
        peakLevel = 0.01
        slowLevel = 0.01
    }
}
