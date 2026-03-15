//
//  CWModulator.swift
//  AmateurDigitalCore
//
//  CW modulator: converts text to on-off keyed audio samples
//

import Foundation

/// CW Modulator for transmission
///
/// Generates CW (Morse code) audio from text using on-off keying (OOK)
/// with raised-cosine envelope shaping to minimize keying clicks.
///
/// Example usage:
/// ```swift
/// var modulator = CWModulator(configuration: .standard)
/// let samples = modulator.modulateText("CQ CQ CQ DE W1AW K")
/// // Play samples through audio output
/// ```
public struct CWModulator {

    // MARK: - Properties

    private let configuration: CWConfiguration
    private var phase: Double = 0

    public var currentConfiguration: CWConfiguration { configuration }

    // MARK: - Initialization

    public init(configuration: CWConfiguration = .standard) {
        self.configuration = configuration
    }

    // MARK: - Text Modulation

    /// Encode text to CW audio samples
    /// - Parameter text: Text to encode (case-insensitive, uppercase by convention)
    /// - Returns: Audio samples in [-1.0, 1.0]
    public mutating func modulateText(_ text: String) -> [Float] {
        let timings = MorseCodec.encodeToTimings(text)
        return modulateTimings(timings)
    }

    /// Encode text with leading/trailing silence
    /// - Parameters:
    ///   - text: Text to encode
    ///   - preambleMs: Silence before message in milliseconds
    ///   - postambleMs: Silence after message in milliseconds
    /// - Returns: Audio samples with silence padding
    public mutating func modulateTextWithEnvelope(
        _ text: String,
        preambleMs: Double = 200,
        postambleMs: Double = 200
    ) -> [Float] {
        let preSamples = Int(preambleMs / 1000.0 * configuration.sampleRate)
        let postSamples = Int(postambleMs / 1000.0 * configuration.sampleRate)

        var samples = [Float](repeating: 0, count: preSamples)
        samples.append(contentsOf: modulateText(text))
        samples.append(contentsOf: [Float](repeating: 0, count: postSamples))

        return samples
    }

    // MARK: - Low-Level Modulation

    /// Modulate a timing array to audio samples
    /// - Parameter timings: Array of dit-unit timings (+ve = key down, -ve = key up)
    /// - Returns: Audio samples
    public mutating func modulateTimings(_ timings: [Int]) -> [Float] {
        var samples = [Float]()
        let ditSamples = configuration.samplesPerDit

        for timing in timings {
            let durationSamples: Int
            if timing > 0 {
                // Key-down: generate tone with envelope
                durationSamples = timing * ditSamples
                let tone = generateTone(samples: durationSamples)
                samples.append(contentsOf: tone)
            } else {
                // Key-up: silence
                durationSamples = abs(timing) * ditSamples
                samples.append(contentsOf: [Float](repeating: 0, count: durationSamples))
            }
        }

        return samples
    }

    /// Generate a shaped tone burst
    /// - Parameter samples: Number of samples to generate
    /// - Returns: Audio samples with raised-cosine envelope
    private mutating func generateTone(samples count: Int) -> [Float] {
        var samples = [Float]()
        samples.reserveCapacity(count)

        let riseSamples = configuration.riseSamples
        let phaseIncrement = 2.0 * .pi * configuration.toneFrequency / configuration.sampleRate

        for i in 0..<count {
            // Raised-cosine envelope for rise/fall
            let envelope: Float
            if i < riseSamples {
                // Rise
                envelope = Float(0.5 * (1.0 - cos(.pi * Double(i) / Double(riseSamples))))
            } else if i >= count - riseSamples {
                // Fall
                let fallIndex = i - (count - riseSamples)
                envelope = Float(0.5 * (1.0 + cos(.pi * Double(fallIndex) / Double(riseSamples))))
            } else {
                envelope = 1.0
            }

            let sample = envelope * Float(sin(phase))
            samples.append(sample)

            phase += phaseIncrement
            if phase >= 2.0 * .pi {
                phase -= 2.0 * .pi
            }
        }

        return samples
    }

    // MARK: - Control

    /// Reset the modulator state
    public mutating func reset() {
        phase = 0
    }
}
