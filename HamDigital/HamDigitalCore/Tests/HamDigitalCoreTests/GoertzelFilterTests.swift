//
//  GoertzelFilterTests.swift
//  DigiModesCoreTests
//

import XCTest
@testable import HamDigitalCore

final class GoertzelFilterTests: XCTestCase {

    // MARK: - Basic Detection

    func testDetectsSingleFrequency() {
        // Generate a 1000 Hz sine wave
        let sampleRate: Double = 48000
        let frequency: Double = 1000
        let blockSize = 1024

        var samples = [Float]()
        for i in 0..<blockSize {
            let t = Double(i) / sampleRate
            samples.append(Float(sin(2.0 * .pi * frequency * t)))
        }

        // Create filter for 1000 Hz
        var filter = GoertzelFilter(
            frequency: frequency,
            sampleRate: sampleRate,
            blockSize: blockSize
        )

        let power = filter.processBlock(samples)

        // Power should be significant
        XCTAssertGreaterThan(power, 100, "Should detect 1000 Hz tone")
    }

    func testRejectsOtherFrequencies() {
        // Generate a 1000 Hz sine wave
        let sampleRate: Double = 48000
        let signalFreq: Double = 1000
        let blockSize = 1024

        var samples = [Float]()
        for i in 0..<blockSize {
            let t = Double(i) / sampleRate
            samples.append(Float(sin(2.0 * .pi * signalFreq * t)))
        }

        // Create filter for 2000 Hz (NOT the signal frequency)
        var filter = GoertzelFilter(
            frequency: 2000,
            sampleRate: sampleRate,
            blockSize: blockSize
        )

        let power = filter.processBlock(samples)

        // Power should be much lower than at signal frequency
        var signalFilter = GoertzelFilter(
            frequency: signalFreq,
            sampleRate: sampleRate,
            blockSize: blockSize
        )
        let signalPower = signalFilter.processBlock(samples)

        XCTAssertLessThan(power, signalPower / 10, "Should reject 2000 Hz when signal is 1000 Hz")
    }

    // MARK: - RTTY Mark/Space Detection

    func testDistinguishesMarkAndSpace() {
        let sampleRate: Double = 48000
        let markFreq: Double = 2125
        let spaceFreq: Double = 1955
        let blockSize = 256

        // Generate mark tone
        var markSamples = [Float]()
        for i in 0..<blockSize {
            let t = Double(i) / sampleRate
            markSamples.append(Float(sin(2.0 * .pi * markFreq * t)))
        }

        // Generate space tone
        var spaceSamples = [Float]()
        for i in 0..<blockSize {
            let t = Double(i) / sampleRate
            spaceSamples.append(Float(sin(2.0 * .pi * spaceFreq * t)))
        }

        var markFilter = GoertzelFilter(
            frequency: markFreq,
            sampleRate: sampleRate,
            blockSize: blockSize
        )

        var spaceFilter = GoertzelFilter(
            frequency: spaceFreq,
            sampleRate: sampleRate,
            blockSize: blockSize
        )

        // Test mark tone detection
        let markPowerOnMark = markFilter.processBlock(markSamples)
        markFilter.reset()
        let spacePowerOnMark = spaceFilter.processBlock(markSamples)
        spaceFilter.reset()

        XCTAssertGreaterThan(markPowerOnMark, spacePowerOnMark * 3,
                            "Mark filter should detect mark tone better than space filter")

        // Test space tone detection
        let markPowerOnSpace = markFilter.processBlock(spaceSamples)
        let spacePowerOnSpace = spaceFilter.processBlock(spaceSamples)

        XCTAssertGreaterThan(spacePowerOnSpace, markPowerOnSpace * 3,
                            "Space filter should detect space tone better than mark filter")
    }

    // MARK: - FSK Detector

    func testFSKDetectorMarkCorrelation() {
        let sampleRate: Double = 48000
        let markFreq: Double = 2125
        let spaceFreq: Double = 1955
        let blockSize = 256

        // Generate mark tone
        var markSamples = [Float]()
        for i in 0..<blockSize {
            let t = Double(i) / sampleRate
            markSamples.append(Float(sin(2.0 * .pi * markFreq * t)))
        }

        var detector = FSKDetector(
            markFrequency: markFreq,
            spaceFrequency: spaceFreq,
            sampleRate: sampleRate,
            blockSize: blockSize
        )

        let correlation = detector.processBlock(markSamples)

        // Mark tone should give positive correlation (close to +1)
        XCTAssertGreaterThan(correlation, 0.5, "Mark tone should have positive correlation")
    }

    func testFSKDetectorSpaceCorrelation() {
        let sampleRate: Double = 48000
        let markFreq: Double = 2125
        let spaceFreq: Double = 1955
        let blockSize = 256

        // Generate space tone
        var spaceSamples = [Float]()
        for i in 0..<blockSize {
            let t = Double(i) / sampleRate
            spaceSamples.append(Float(sin(2.0 * .pi * spaceFreq * t)))
        }

        var detector = FSKDetector(
            markFrequency: markFreq,
            spaceFrequency: spaceFreq,
            sampleRate: sampleRate,
            blockSize: blockSize
        )

        let correlation = detector.processBlock(spaceSamples)

        // Space tone should give negative correlation (close to -1)
        XCTAssertLessThan(correlation, -0.5, "Space tone should have negative correlation")
    }

    func testFSKDetectorWithNoise() {
        let sampleRate: Double = 48000
        let markFreq: Double = 2125
        let spaceFreq: Double = 1955
        let blockSize = 256

        // Generate mark tone with noise
        var noisyMarkSamples = [Float]()
        for i in 0..<blockSize {
            let t = Double(i) / sampleRate
            let signal = Float(sin(2.0 * .pi * markFreq * t))
            let noise = Float.random(in: -0.2...0.2)
            noisyMarkSamples.append(signal + noise)
        }

        var detector = FSKDetector(
            markFrequency: markFreq,
            spaceFrequency: spaceFreq,
            sampleRate: sampleRate,
            blockSize: blockSize
        )

        let correlation = detector.processBlock(noisyMarkSamples)

        // Should still detect mark with moderate noise
        XCTAssertGreaterThan(correlation, 0.3, "Should detect mark tone even with 20% noise")
    }

    // MARK: - Sample-by-Sample Processing

    func testSampleByampleProcessing() {
        let sampleRate: Double = 48000
        let frequency: Double = 1000
        let blockSize = 256

        var samples = [Float]()
        for i in 0..<blockSize {
            let t = Double(i) / sampleRate
            samples.append(Float(sin(2.0 * .pi * frequency * t)))
        }

        var filter = GoertzelFilter(
            frequency: frequency,
            sampleRate: sampleRate,
            blockSize: blockSize
        )

        // Process sample by sample
        var power: Float = 0
        for sample in samples {
            if let p = filter.process(sample: sample) {
                power = p
            }
        }

        // Should get same result as block processing
        var filter2 = GoertzelFilter(
            frequency: frequency,
            sampleRate: sampleRate,
            blockSize: blockSize
        )
        let blockPower = filter2.processBlock(samples)

        XCTAssertEqual(power, blockPower, accuracy: 0.01)
    }

    // MARK: - Reset

    func testReset() {
        var filter = GoertzelFilter(frequency: 1000, sampleRate: 48000, blockSize: 256)

        // Process some samples
        for i in 0..<100 {
            _ = filter.process(sample: Float(i) / 100.0)
        }

        // Reset
        filter.reset()

        // Samples remaining should be full block
        XCTAssertEqual(filter.samplesRemaining, 256)
        XCTAssertFalse(filter.isBlockComplete)
    }

    // MARK: - Properties

    func testFrequencyProperty() {
        let filter = GoertzelFilter(frequency: 2125, sampleRate: 48000, blockSize: 256)
        XCTAssertEqual(filter.frequency, 2125)
    }

    func testSamplesRemaining() {
        var filter = GoertzelFilter(frequency: 1000, sampleRate: 48000, blockSize: 256)

        XCTAssertEqual(filter.samplesRemaining, 256)

        for _ in 0..<100 {
            _ = filter.process(sample: 0)
        }

        XCTAssertEqual(filter.samplesRemaining, 156)
    }

    // MARK: - Silence Detection

    func testSilenceHasLowPower() {
        var filter = GoertzelFilter(frequency: 2125, sampleRate: 48000, blockSize: 256)

        // Process silence (all zeros)
        let silence = [Float](repeating: 0, count: 256)
        let power = filter.processBlock(silence)

        XCTAssertLessThan(power, 0.001, "Silence should have near-zero power")
    }

    func testWhiteNoiseHasLowCorrelation() {
        // Use a larger block size to reduce variance in the test
        let blockSize = 2048

        // Generate white noise using a seeded random for reproducibility
        var generator = SeededRandomGenerator(seed: 42)
        var noise = [Float]()
        for _ in 0..<blockSize {
            noise.append(Float(generator.nextDouble() * 2.0 - 1.0))
        }

        var detector = FSKDetector(
            markFrequency: 2125,
            spaceFrequency: 1955,
            sampleRate: 48000,
            blockSize: blockSize
        )

        let correlation = detector.processBlock(noise)

        // White noise should have correlation close to 0 (indeterminate)
        // With seeded random and larger block, this should be consistent
        XCTAssertLessThan(abs(correlation), 0.8,
                         "White noise should not strongly correlate with mark or space")
    }
}

// MARK: - Seeded Random Generator for Reproducible Tests

private struct SeededRandomGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextDouble() -> Double {
        // Simple xorshift64* algorithm
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let value = state &* 0x2545F4914F6CDD1D
        return Double(value) / Double(UInt64.max)
    }
}
