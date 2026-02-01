//
//  SineGenerator.swift
//  DigiModesCore
//
//  Efficient sine wave generator using phase accumulator
//  for phase-continuous FSK tone generation
//

import Foundation

/// Efficient sine wave generator using phase accumulator
///
/// Uses a phase accumulator approach for smooth, phase-continuous
/// tone generation. Essential for FSK modulation where switching
/// between mark and space frequencies must not introduce clicks.
public struct SineGenerator {

    // MARK: - Properties

    private let sampleRate: Double
    private var phase: Double = 0.0
    private var frequency: Double

    /// Phase increment per sample for current frequency
    private var phaseIncrement: Double {
        2.0 * .pi * frequency / sampleRate
    }

    // MARK: - Initialization

    /// Create a sine generator
    /// - Parameters:
    ///   - frequency: Initial frequency in Hz
    ///   - sampleRate: Audio sample rate (default 48000 Hz)
    public init(frequency: Double, sampleRate: Double = 48000.0) {
        self.frequency = frequency
        self.sampleRate = sampleRate
    }

    // MARK: - Generation

    /// Generate the next sample
    /// - Returns: Sample value in range [-1.0, 1.0]
    public mutating func nextSample() -> Float {
        let sample = Float(sin(phase))
        phase += phaseIncrement

        // Keep phase in [0, 2*pi) to prevent accumulation errors
        if phase >= 2.0 * .pi {
            phase -= 2.0 * .pi
        }

        return sample
    }

    /// Generate multiple samples
    /// - Parameter count: Number of samples to generate
    /// - Returns: Array of samples in range [-1.0, 1.0]
    public mutating func generate(count: Int) -> [Float] {
        var samples = [Float]()
        samples.reserveCapacity(count)

        for _ in 0..<count {
            samples.append(nextSample())
        }

        return samples
    }

    /// Generate samples for a specific duration
    /// - Parameter duration: Duration in seconds
    /// - Returns: Array of samples
    public mutating func generate(duration: Double) -> [Float] {
        let count = Int(duration * sampleRate)
        return generate(count: count)
    }

    // MARK: - Control

    /// Change frequency (maintains phase continuity)
    ///
    /// Phase continuity prevents clicks when switching between
    /// mark and space frequencies in FSK modulation.
    /// - Parameter newFrequency: New frequency in Hz
    public mutating func setFrequency(_ newFrequency: Double) {
        self.frequency = newFrequency
    }

    /// Get current frequency
    public var currentFrequency: Double {
        frequency
    }

    /// Get current phase in radians
    public var currentPhase: Double {
        phase
    }

    /// Reset phase to zero
    public mutating func reset() {
        phase = 0.0
    }

    /// Reset phase to a specific value
    /// - Parameter newPhase: Phase in radians
    public mutating func setPhase(_ newPhase: Double) {
        phase = newPhase.truncatingRemainder(dividingBy: 2.0 * .pi)
        if phase < 0 {
            phase += 2.0 * .pi
        }
    }
}
