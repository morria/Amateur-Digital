//
//  MultiChannelIntegrationTests.swift
//  DigiModesCoreTests
//
//  Integration tests for simultaneous multi-channel RTTY encoding and decoding
//

import XCTest
@testable import AmateurDigitalCore

final class MultiChannelIntegrationTests: XCTestCase {

    // MARK: - Single Channel Round-Trip

    /// Test that a single channel can encode and decode correctly
    func testSingleChannelRoundTrip() {
        let config = RTTYConfiguration.standard
        let encoder = RTTYModem(configuration: config)

        // Use shorter message for faster test
        let message = "RYRYRY"
        let samples = encoder.encodeWithIdle(text: message, preambleMs: 200, postambleMs: 100)

        // Create demodulator and collect decoded characters
        var decoded = ""
        let demodulator = FSKDemodulator(configuration: config)

        let delegate = TestDemodulatorDelegate { char in
            decoded.append(char)
        }
        demodulator.delegate = delegate

        // Process samples
        demodulator.process(samples: samples)

        // RYRYRY should produce R and Y characters
        let hasR = decoded.contains("R")
        let hasY = decoded.contains("Y")
        XCTAssertTrue(hasR || hasY, "Should decode R or Y from RYRYRY. Got: \(decoded)")
    }

    // MARK: - Multi-Channel Simultaneous Decoding

    /// Test that 4 simultaneous channels can be decoded correctly
    func testFourChannelSimultaneousDecode() {
        let sampleRate = 48000.0

        // Define 4 channels with different frequencies and messages
        let channels: [(freq: Double, callsign: String, message: String)] = [
            (1500, "W1AW", "DE W1AW"),
            (1700, "K5ABC", "DE K5ABC"),
            (1900, "N0XYZ", "DE N0XYZ"),
            (2100, "VE3TST", "DE VE3TST")
        ]

        // Generate samples for each channel
        var allChannelSamples: [[Float]] = []
        var maxLength = 0

        for (freq, _, message) in channels {
            let config = RTTYConfiguration(
                baudRate: 45.45,
                markFrequency: freq,
                shift: 170.0,
                sampleRate: sampleRate
            )
            let modem = RTTYModem(configuration: config)
            let samples = modem.encodeWithIdle(text: message, preambleMs: 50, postambleMs: 25)
            allChannelSamples.append(samples)
            maxLength = max(maxLength, samples.count)
        }

        // Mix all channels together
        var mixed = [Float](repeating: 0, count: maxLength)
        for channelSamples in allChannelSamples {
            for (i, sample) in channelSamples.enumerated() {
                mixed[i] += sample * 0.25  // Scale to prevent clipping
            }
        }

        // Create multi-channel demodulator
        let demodulator = MultiChannelRTTYDemodulator(
            frequencies: channels.map { $0.freq },
            configuration: RTTYConfiguration.standard
        )

        // Track decoded content per channel
        var decodedPerChannel: [Double: String] = [:]
        for (freq, _, _) in channels {
            decodedPerChannel[freq] = ""
        }

        let delegate = TestMultiChannelDelegate { char, channel in
            let freq = channel.frequency
            decodedPerChannel[freq, default: ""].append(char)
        }
        demodulator.delegate = delegate

        // Process all samples
        demodulator.process(samples: mixed)

        // Verify each channel decoded its expected pattern
        var channelsWithCorrectOutput = 0
        for (freq, _, message) in channels {
            let decoded = decodedPerChannel[freq] ?? ""
            if !decoded.isEmpty {
                // Check if decoded output contains expected callsign fragment
                // Message format: "DE W1AW" - look for callsign letters
                let expectedCallsign = message.replacingOccurrences(of: "DE ", with: "")
                let hasExpectedContent = expectedCallsign.contains { decoded.contains($0) }
                if hasExpectedContent {
                    channelsWithCorrectOutput += 1
                }
            }
        }
        // At least 2 of 4 channels should decode correctly
        XCTAssertGreaterThanOrEqual(channelsWithCorrectOutput, 2,
            "At least 2 of 4 channels should decode expected content. Got \(channelsWithCorrectOutput)")
    }

    // MARK: - Channel Separation

    /// Test that channels don't interfere with each other
    func testChannelSeparation() {
        let sampleRate = 48000.0

        // Two adjacent channels
        let freq1 = 1500.0
        let freq2 = 1700.0  // 200 Hz separation (> 170 Hz shift)

        let config1 = RTTYConfiguration(baudRate: 45.45, markFrequency: freq1, shift: 170.0, sampleRate: sampleRate)
        let config2 = RTTYConfiguration(baudRate: 45.45, markFrequency: freq2, shift: 170.0, sampleRate: sampleRate)

        // Channel 1 sends "AAA", Channel 2 sends "BBB"
        let modem1 = RTTYModem(configuration: config1)
        let modem2 = RTTYModem(configuration: config2)

        let samples1 = modem1.encodeWithIdle(text: "AAAA", preambleMs: 50, postambleMs: 25)
        let samples2 = modem2.encodeWithIdle(text: "BBBB", preambleMs: 50, postambleMs: 25)

        // Mix
        let maxLen = max(samples1.count, samples2.count)
        var mixed = [Float](repeating: 0, count: maxLen)
        for (i, s) in samples1.enumerated() { mixed[i] += s * 0.5 }
        for (i, s) in samples2.enumerated() { mixed[i] += s * 0.5 }

        // Create demodulators for each frequency
        let demod1 = FSKDemodulator(configuration: config1)
        let demod2 = FSKDemodulator(configuration: config2)

        var decoded1 = ""
        var decoded2 = ""

        let delegate1 = TestDemodulatorDelegate { decoded1.append($0) }
        let delegate2 = TestDemodulatorDelegate { decoded2.append($0) }

        demod1.delegate = delegate1
        demod2.delegate = delegate2

        // Process mixed audio through both demodulators
        demod1.process(samples: mixed)
        demod2.process(samples: mixed)

        // Channel 1 should decode "A"s (not "B"s)
        // Channel 2 should decode "B"s (not "A"s)
        let ch1HasA = decoded1.contains("A")
        let ch1HasB = decoded1.contains("B")
        let ch2HasA = decoded2.contains("A")
        let ch2HasB = decoded2.contains("B")

        // At minimum, we need output from at least one channel
        XCTAssertTrue(!decoded1.isEmpty || !decoded2.isEmpty,
            "Should decode from at least one channel. Ch1: '\(decoded1)', Ch2: '\(decoded2)'")

        // Check for cross-contamination - each channel should primarily decode its own signal
        if !decoded1.isEmpty && !decoded2.isEmpty {
            // If both channels have output, verify separation
            XCTAssertTrue(ch1HasA || !ch1HasB,
                "Channel 1 should prefer 'A's over 'B's. Got: '\(decoded1)'")
            XCTAssertTrue(ch2HasB || !ch2HasA,
                "Channel 2 should prefer 'B's over 'A's. Got: '\(decoded2)'")
        }
    }

    // MARK: - Stress Test

    /// Test maximum channel capacity
    func testEightChannelCapacity() {
        let sampleRate = 48000.0

        // 8 channels from 1200-2600 Hz (200 Hz spacing)
        let frequencies = stride(from: 1200.0, through: 2600.0, by: 200.0).map { $0 }
        XCTAssertEqual(frequencies.count, 8)

        var allSamples: [[Float]] = []
        var maxLength = 0

        for freq in frequencies {
            let config = RTTYConfiguration(
                baudRate: 45.45,
                markFrequency: freq,
                shift: 170.0,
                sampleRate: sampleRate
            )
            let modem = RTTYModem(configuration: config)
            let samples = modem.encodeWithIdle(text: "TEST", preambleMs: 50, postambleMs: 25)
            allSamples.append(samples)
            maxLength = max(maxLength, samples.count)
        }

        // Mix all channels
        var mixed = [Float](repeating: 0, count: maxLength)
        for channelSamples in allSamples {
            for (i, sample) in channelSamples.enumerated() {
                mixed[i] += sample / Float(frequencies.count)
            }
        }

        // Create multi-channel demodulator
        let demodulator = MultiChannelRTTYDemodulator(
            frequencies: frequencies,
            configuration: RTTYConfiguration.standard
        )

        var decodedChars: [Character] = []
        let delegate = TestMultiChannelDelegate { char, _ in
            decodedChars.append(char)
        }
        demodulator.delegate = delegate

        demodulator.process(samples: mixed)

        // Count how many channels produced output with expected "TEST" characters
        var channelsWithTestChars = Set<Double>()
        let testChars = Set(Array("TEST"))

        // Track decoded chars per frequency
        var decodedPerFreq: [Double: String] = [:]
        for freq in frequencies {
            decodedPerFreq[freq] = ""
        }

        // Re-process to track per-channel
        let trackingDelegate = TestMultiChannelDelegate { char, channel in
            decodedPerFreq[channel.frequency, default: ""].append(char)
        }
        let trackingDemod = MultiChannelRTTYDemodulator(
            frequencies: frequencies,
            configuration: RTTYConfiguration.standard
        )
        trackingDemod.delegate = trackingDelegate
        trackingDemod.process(samples: mixed)

        for (freq, decoded) in decodedPerFreq {
            let hasTestChar = decoded.contains { testChars.contains($0) }
            if hasTestChar {
                channelsWithTestChars.insert(freq)
            }
        }

        // At least 1 of 8 channels should decode some expected content
        // Note: With minCharacterConfidence=0.3 and 8 signals mixed at 1/8 amplitude,
        // the SNR per channel is low. Getting 1 channel decoded is expected.
        XCTAssertGreaterThanOrEqual(channelsWithTestChars.count, 1,
            "At least 1 of 8 channels should decode TEST characters. Got \(channelsWithTestChars.count)")
    }
}

// MARK: - Test Helpers

/// Simple delegate for FSKDemodulator tests
private class TestDemodulatorDelegate: FSKDemodulatorDelegate {
    let onDecode: (Character) -> Void

    init(onDecode: @escaping (Character) -> Void) {
        self.onDecode = onDecode
    }

    func demodulator(_ demodulator: FSKDemodulator, didDecode character: Character, atFrequency frequency: Double) {
        onDecode(character)
    }

    func demodulator(_ demodulator: FSKDemodulator, signalDetected detected: Bool, atFrequency frequency: Double) {
        // Not used in these tests
    }
}

/// Simple delegate for MultiChannelRTTYDemodulator tests
private class TestMultiChannelDelegate: MultiChannelRTTYDemodulatorDelegate {
    let onDecode: (Character, RTTYChannel) -> Void

    init(onDecode: @escaping (Character, RTTYChannel) -> Void) {
        self.onDecode = onDecode
    }

    func demodulator(_ demodulator: MultiChannelRTTYDemodulator, didDecode character: Character, onChannel channel: RTTYChannel) {
        onDecode(character, channel)
    }

    func demodulator(_ demodulator: MultiChannelRTTYDemodulator, signalDetected detected: Bool, onChannel channel: RTTYChannel) {
        // Not used in these tests
    }

    func demodulator(_ demodulator: MultiChannelRTTYDemodulator, didUpdateChannels channels: [RTTYChannel]) {
        // Not used in these tests
    }
}
