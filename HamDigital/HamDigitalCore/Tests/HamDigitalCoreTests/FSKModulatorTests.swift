//
//  FSKModulatorTests.swift
//  DigiModesCoreTests
//

import XCTest
@testable import HamDigitalCore

final class FSKModulatorTests: XCTestCase {

    // MARK: - Configuration

    func testSamplesPerBit() {
        let modulator = FSKModulator(configuration: .standard)
        // 48000 / 45.45 ≈ 1056
        XCTAssertEqual(modulator.samplesPerBit, 1056)
    }

    func testSamplesPerStopBits() {
        let modulator = FSKModulator(configuration: .standard)
        // 1.5 * 1056 = 1584
        XCTAssertEqual(modulator.samplesPerStopBits, 1584)
    }

    // MARK: - Tone Generation

    func testGenerateMarkFrequency() {
        var modulator = FSKModulator(configuration: .standard)
        let samples = modulator.generateMark(count: 4800)  // 100ms

        // Verify frequency using Goertzel filter
        var markFilter = GoertzelFilter(
            frequency: 2125,
            sampleRate: 48000,
            blockSize: 1024
        )
        var spaceFilter = GoertzelFilter(
            frequency: 1955,
            sampleRate: 48000,
            blockSize: 1024
        )

        let markPower = markFilter.processBlock(Array(samples[0..<1024]))
        let spacePower = spaceFilter.processBlock(Array(samples[0..<1024]))

        XCTAssertGreaterThan(markPower, spacePower * 10,
                            "Mark tone should have much more power at mark frequency")
    }

    func testGenerateSpaceFrequency() {
        var modulator = FSKModulator(configuration: .standard)
        let samples = modulator.generateSpace(count: 4800)  // 100ms

        // Verify frequency using Goertzel filter
        var markFilter = GoertzelFilter(
            frequency: 2125,
            sampleRate: 48000,
            blockSize: 1024
        )
        var spaceFilter = GoertzelFilter(
            frequency: 1955,
            sampleRate: 48000,
            blockSize: 1024
        )

        let markPower = markFilter.processBlock(Array(samples[0..<1024]))
        let spacePower = spaceFilter.processBlock(Array(samples[0..<1024]))

        XCTAssertGreaterThan(spacePower, markPower * 10,
                            "Space tone should have much more power at space frequency")
    }

    // MARK: - Character Framing

    func testCharacterLength() {
        var modulator = FSKModulator(configuration: .standard)

        // Modulate a single code
        let samples = modulator.modulateCode(0x01)  // 'E'

        // Should be 7.5 bits worth of samples
        // 1 start + 5 data + 1.5 stop = 7.5 bits
        let expectedSamples = Int(7.5 * Double(modulator.samplesPerBit))
        XCTAssertEqual(samples.count, expectedSamples,
                      "Character should be 7.5 bits long")
    }

    func testStartBitIsSpace() {
        var modulator = FSKModulator(configuration: .standard)

        // Modulate any code
        let samples = modulator.modulateCode(0x1F)  // All 1s in data

        // Extract first bit (start bit)
        let startBitSamples = Array(samples[0..<modulator.samplesPerBit])

        // Verify it's space frequency
        var detector = FSKDetector(
            markFrequency: 2125,
            spaceFrequency: 1955,
            sampleRate: 48000,
            blockSize: modulator.samplesPerBit
        )

        let correlation = detector.processBlock(startBitSamples)
        XCTAssertLessThan(correlation, -0.3,
                         "Start bit should be space (negative correlation)")
    }

    func testStopBitsAreMark() {
        var modulator = FSKModulator(configuration: .standard)

        // Modulate any code
        let samples = modulator.modulateCode(0x00)  // All 0s in data

        // Extract stop bits (last 1.5 bits)
        let stopBitStart = samples.count - modulator.samplesPerStopBits
        let stopBitSamples = Array(samples[stopBitStart..<samples.count])

        // Verify it's mark frequency (use subset for clean block size)
        var detector = FSKDetector(
            markFrequency: 2125,
            spaceFrequency: 1955,
            sampleRate: 48000,
            blockSize: modulator.samplesPerBit
        )

        let correlation = detector.processBlock(Array(stopBitSamples[0..<modulator.samplesPerBit]))
        XCTAssertGreaterThan(correlation, 0.3,
                            "Stop bits should be mark (positive correlation)")
    }

    func testDataBitsLSBFirst() {
        var modulator = FSKModulator(configuration: .standard)

        // Modulate code 0x01 (binary: 00001)
        // LSB first: bit0=1, bit1=0, bit2=0, bit3=0, bit4=0
        let samples = modulator.modulateCode(0x01)

        // Extract data bits (skip start bit)
        let startOfData = modulator.samplesPerBit
        let samplesPerBit = modulator.samplesPerBit

        var detector = FSKDetector(
            markFrequency: 2125,
            spaceFrequency: 1955,
            sampleRate: 48000,
            blockSize: samplesPerBit
        )

        // Bit 0 should be mark (1)
        let bit0Samples = Array(samples[startOfData..<(startOfData + samplesPerBit)])
        let bit0Correlation = detector.processBlock(bit0Samples)
        XCTAssertGreaterThan(bit0Correlation, 0.3, "Bit 0 should be mark (1)")

        // Bits 1-4 should be space (0)
        for bitIndex in 1..<5 {
            detector.reset()
            let bitStart = startOfData + bitIndex * samplesPerBit
            let bitSamples = Array(samples[bitStart..<(bitStart + samplesPerBit)])
            let correlation = detector.processBlock(bitSamples)
            XCTAssertLessThan(correlation, -0.3, "Bit \(bitIndex) should be space (0)")
        }
    }

    // MARK: - Text Encoding

    func testModulateText() {
        var modulator = FSKModulator(configuration: .standard)

        let samples = modulator.modulateText("E")

        // "E" encodes as: LTRS preamble (2x) + E code
        // That's 3 characters minimum
        let minSamples = 3 * Int(7.5 * Double(modulator.samplesPerBit))
        XCTAssertGreaterThanOrEqual(samples.count, minSamples,
                                    "Should have samples for preamble + character")
    }

    func testModulateTextWithIdle() {
        var modulator = FSKModulator(configuration: .standard)

        let samples = modulator.modulateTextWithIdle("E", preambleMs: 100, postambleMs: 50)

        // Should have preamble + message + postamble
        let preambleSamples = Int(0.1 * 48000)  // 100ms
        let postambleSamples = Int(0.05 * 48000)  // 50ms
        let messageSamples = 3 * Int(7.5 * Double(modulator.samplesPerBit))

        let expectedMin = preambleSamples + messageSamples + postambleSamples
        XCTAssertGreaterThanOrEqual(samples.count, expectedMin,
                                    "Should include preamble and postamble idle")
    }

    // MARK: - Multiple Characters

    func testModulateMultipleCharacters() {
        var modulator = FSKModulator(configuration: .standard)

        let codes: [UInt8] = [0x01, 0x03, 0x05]  // E, A, S
        let samples = modulator.modulateCodes(codes)

        let expectedSamples = 3 * Int(7.5 * Double(modulator.samplesPerBit))
        XCTAssertEqual(samples.count, expectedSamples,
                      "Should have samples for all 3 characters")
    }

    // MARK: - Phase Continuity

    func testPhaseContinuityBetweenTones() {
        var modulator = FSKModulator(configuration: .standard)

        // Generate alternating mark/space to test phase continuity
        let samples = modulator.modulateCode(0x15)  // 10101 pattern

        // Check that there are no sudden discontinuities (clicks)
        var maxDiff: Float = 0
        for i in 1..<samples.count {
            let diff = abs(samples[i] - samples[i-1])
            maxDiff = max(maxDiff, diff)
        }

        // Phase-continuous switching should have smooth transitions
        // Max difference should be small (less than 0.5 for normal phase evolution)
        XCTAssertLessThan(maxDiff, 0.5,
                         "Phase-continuous modulation should not have sharp discontinuities")
    }

    // MARK: - Idle Generation

    func testGenerateIdleDuration() {
        var modulator = FSKModulator(configuration: .standard)

        let samples = modulator.generateIdle(duration: 0.1)  // 100ms

        let expectedSamples = Int(0.1 * 48000)
        XCTAssertEqual(samples.count, expectedSamples,
                      "Idle duration should match requested time")
    }

    func testGenerateIdleBits() {
        var modulator = FSKModulator(configuration: .standard)

        let samples = modulator.generateIdle(bits: 10)

        let expectedSamples = 10 * modulator.samplesPerBit
        XCTAssertEqual(samples.count, expectedSamples,
                      "Idle bits should match requested count")
    }

    // MARK: - Reset

    func testReset() {
        var modulator = FSKModulator(configuration: .standard)

        // Modulate something that changes shift state
        _ = modulator.modulateText("123")  // Forces FIGS shift

        // Reset
        modulator.reset()

        // Should be back to letters shift
        XCTAssertEqual(modulator.currentShiftState, .letters,
                      "Reset should restore letters shift state")
    }

    // MARK: - Different Configurations

    func testDifferentBaudRate() {
        let config = RTTYConfiguration.baud75
        var modulator = FSKModulator(configuration: config)

        let samples = modulator.modulateCode(0x01)

        // 75 baud = 48000/75 = 640 samples per bit
        // 7.5 bits = 4800 samples
        let expectedSamples = Int(7.5 * Double(config.samplesPerBit))
        XCTAssertEqual(samples.count, expectedSamples)
    }

    func testDifferentShift() {
        let config = RTTYConfiguration.wide425
        var modulator = FSKModulator(configuration: config)

        let markSamples = modulator.generateMark(count: 1024)
        let spaceSamples = modulator.generateSpace(count: 1024)

        // Verify frequencies with wider shift (2125 Hz mark, 1700 Hz space)
        var markOnMark = GoertzelFilter(frequency: 2125, sampleRate: 48000, blockSize: 1024)
        var markOnSpace = GoertzelFilter(frequency: 1700, sampleRate: 48000, blockSize: 1024)

        let markPower = markOnMark.processBlock(markSamples)
        let spacePower = markOnSpace.processBlock(spaceSamples)

        XCTAssertGreaterThan(markPower, 100, "Should detect mark at 2125 Hz")
        XCTAssertGreaterThan(spacePower, 100, "Should detect space at 1700 Hz with 425 Hz shift")
    }

    // MARK: - Factory Method

    func testWithCenterFrequency() {
        var modulator = FSKModulator.withCenterFrequency(1500)

        let samples = modulator.generateMark(count: 1024)

        // Verify frequency at new center
        var filter = GoertzelFilter(frequency: 1500, sampleRate: 48000, blockSize: 1024)
        let power = filter.processBlock(samples)

        XCTAssertGreaterThan(power, 100, "Should generate tone at specified center frequency")
    }
}

// MARK: - FSKDetector Extension for Tests

extension FSKDetector {
    mutating func reset() {
        self = FSKDetector(
            markFrequency: 2125,
            spaceFrequency: 1955,
            sampleRate: 48000,
            blockSize: 1056
        )
    }
}
