//
//  SineGeneratorTests.swift
//  DigiModesCoreTests
//

import XCTest
@testable import HamDigitalCore

final class SineGeneratorTests: XCTestCase {

    // MARK: - Basic Generation

    func testGeneratesCorrectNumberOfSamples() {
        var generator = SineGenerator(frequency: 1000, sampleRate: 48000)
        let samples = generator.generate(count: 100)
        XCTAssertEqual(samples.count, 100)
    }

    func testGeneratesCorrectDuration() {
        var generator = SineGenerator(frequency: 1000, sampleRate: 48000)
        let samples = generator.generate(duration: 0.1) // 100ms
        // 0.1 seconds * 48000 samples/second = 4800 samples
        XCTAssertEqual(samples.count, 4800)
    }

    func testSamplesInValidRange() {
        var generator = SineGenerator(frequency: 1000, sampleRate: 48000)
        let samples = generator.generate(count: 1000)

        for sample in samples {
            XCTAssertGreaterThanOrEqual(sample, -1.0, "Sample below -1.0")
            XCTAssertLessThanOrEqual(sample, 1.0, "Sample above 1.0")
        }
    }

    func testSineWaveAmplitude() {
        var generator = SineGenerator(frequency: 1000, sampleRate: 48000)
        let samples = generator.generate(count: 480) // 10ms = one full cycle at 1kHz

        let maxSample = samples.max() ?? 0
        let minSample = samples.min() ?? 0

        // Should reach close to +1 and -1
        XCTAssertGreaterThan(maxSample, 0.99, "Max should be close to 1.0")
        XCTAssertLessThan(minSample, -0.99, "Min should be close to -1.0")
    }

    // MARK: - Frequency Accuracy

    func testFrequencyAccuracy() {
        // Generate 1000 Hz tone at 48000 Hz sample rate
        // One cycle = 48 samples
        var generator = SineGenerator(frequency: 1000, sampleRate: 48000)
        let samples = generator.generate(count: 480) // 10 cycles

        // Count zero crossings (should be ~20 for 10 cycles)
        var zeroCrossings = 0
        for i in 1..<samples.count {
            if (samples[i-1] < 0 && samples[i] >= 0) ||
               (samples[i-1] >= 0 && samples[i] < 0) {
                zeroCrossings += 1
            }
        }

        // 10 cycles = 20 zero crossings (± 1 for edge effects)
        XCTAssertGreaterThanOrEqual(zeroCrossings, 19)
        XCTAssertLessThanOrEqual(zeroCrossings, 21)
    }

    // MARK: - Phase Continuity

    func testPhaseContinuityOnFrequencyChange() {
        var generator = SineGenerator(frequency: 1000, sampleRate: 48000)

        // Generate some samples at 1000 Hz
        let sample1 = generator.nextSample()
        let sample2 = generator.nextSample()
        let sample3 = generator.nextSample()

        // Change frequency
        generator.setFrequency(2000)

        // Next sample should be continuous (no sudden jump)
        let sample4 = generator.nextSample()

        // The difference between consecutive samples should be small
        // (no click from discontinuity)
        let diff = abs(sample4 - sample3)
        XCTAssertLessThan(diff, 0.5, "Frequency change caused discontinuity")
    }

    func testPhaseWrapping() {
        var generator = SineGenerator(frequency: 1000, sampleRate: 48000)

        // Generate many samples to ensure phase wraps correctly
        _ = generator.generate(count: 100000)

        // Phase should still be in valid range
        XCTAssertGreaterThanOrEqual(generator.currentPhase, 0)
        XCTAssertLessThan(generator.currentPhase, 2.0 * .pi)
    }

    // MARK: - Reset

    func testReset() {
        var generator = SineGenerator(frequency: 1000, sampleRate: 48000)

        // Generate some samples
        _ = generator.generate(count: 100)

        // Reset
        generator.reset()

        // Phase should be zero
        XCTAssertEqual(generator.currentPhase, 0)

        // First sample after reset should be sin(0) = 0
        let sample = generator.nextSample()
        XCTAssertEqual(sample, 0, accuracy: 0.0001)
    }

    func testSetPhase() {
        var generator = SineGenerator(frequency: 1000, sampleRate: 48000)

        // Set phase to pi/2 (90 degrees)
        generator.setPhase(.pi / 2)

        // First sample should be sin(pi/2) = 1.0
        let sample = generator.nextSample()
        XCTAssertEqual(sample, 1.0, accuracy: 0.0001)
    }

    // MARK: - Frequency Getter

    func testCurrentFrequency() {
        var generator = SineGenerator(frequency: 2125, sampleRate: 48000)
        XCTAssertEqual(generator.currentFrequency, 2125)

        generator.setFrequency(1955)
        XCTAssertEqual(generator.currentFrequency, 1955)
    }

    // MARK: - RTTY Frequencies

    func testRTTYMarkFrequency() {
        // Test generating standard RTTY mark tone (2125 Hz)
        var generator = SineGenerator(frequency: 2125, sampleRate: 48000)
        let samples = generator.generate(count: 4800) // 100ms

        // Use Goertzel to verify frequency content
        var filter = GoertzelFilter(frequency: 2125, sampleRate: 48000, blockSize: 4800)
        let power = filter.processBlock(samples)

        XCTAssertGreaterThan(power, 100, "Mark tone should have significant power at 2125 Hz")
    }

    func testRTTYSpaceFrequency() {
        // Test generating standard RTTY space tone (1955 Hz)
        var generator = SineGenerator(frequency: 1955, sampleRate: 48000)
        let samples = generator.generate(count: 4800) // 100ms

        // Use Goertzel to verify frequency content
        var filter = GoertzelFilter(frequency: 1955, sampleRate: 48000, blockSize: 4800)
        let power = filter.processBlock(samples)

        XCTAssertGreaterThan(power, 100, "Space tone should have significant power at 1955 Hz")
    }
}
