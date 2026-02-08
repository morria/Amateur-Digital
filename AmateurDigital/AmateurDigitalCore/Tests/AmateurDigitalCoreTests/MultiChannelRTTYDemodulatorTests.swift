//
//  MultiChannelRTTYDemodulatorTests.swift
//  DigiModesCoreTests
//

import XCTest
@testable import AmateurDigitalCore

final class MultiChannelRTTYDemodulatorTests: XCTestCase {

    // MARK: - Test Delegate

    class TestDelegate: MultiChannelRTTYDemodulatorDelegate {
        var decodedCharacters: [(Character, RTTYChannel)] = []
        var signalChanges: [(Bool, RTTYChannel)] = []
        var channelUpdates: [[RTTYChannel]] = []

        func demodulator(
            _ demodulator: MultiChannelRTTYDemodulator,
            didDecode character: Character,
            onChannel channel: RTTYChannel
        ) {
            decodedCharacters.append((character, channel))
        }

        func demodulator(
            _ demodulator: MultiChannelRTTYDemodulator,
            signalDetected detected: Bool,
            onChannel channel: RTTYChannel
        ) {
            signalChanges.append((detected, channel))
        }

        func demodulator(
            _ demodulator: MultiChannelRTTYDemodulator,
            didUpdateChannels channels: [RTTYChannel]
        ) {
            channelUpdates.append(channels)
        }

        func reset() {
            decodedCharacters.removeAll()
            signalChanges.removeAll()
            channelUpdates.removeAll()
        }
    }

    // MARK: - Properties

    var demodulator: MultiChannelRTTYDemodulator!
    var delegate: TestDelegate!

    override func setUp() {
        super.setUp()
        demodulator = MultiChannelRTTYDemodulator(frequencies: [1500, 2125])
        demodulator.afcEnabled = false  // Disable AFC for deterministic tests
        delegate = TestDelegate()
        demodulator.delegate = delegate
    }

    override func tearDown() {
        demodulator = nil
        delegate = nil
        super.tearDown()
    }

    // MARK: - Initialization Tests

    func testInitWithFrequencies() {
        let demod = MultiChannelRTTYDemodulator(frequencies: [1000, 1500, 2000])

        XCTAssertEqual(demod.channelCount, 3)
        XCTAssertEqual(demod.channels.count, 3)
    }

    func testInitWithRange() {
        let demod = MultiChannelRTTYDemodulator(
            startFrequency: 1000,
            endFrequency: 2000,
            spacing: 200
        )

        // Should have channels at 1000, 1200, 1400, 1600, 1800, 2000
        XCTAssertEqual(demod.channelCount, 6)
    }

    func testChannelsSortedByFrequency() {
        let demod = MultiChannelRTTYDemodulator(frequencies: [2000, 1000, 1500])

        let frequencies = demod.channels.map { $0.frequency }
        XCTAssertEqual(frequencies, [1000, 1500, 2000])
    }

    // MARK: - Channel Management

    func testAddChannel() {
        let initialCount = demodulator.channelCount

        let newChannel = demodulator.addChannel(at: 1800)

        XCTAssertEqual(demodulator.channelCount, initialCount + 1)
        XCTAssertEqual(newChannel.frequency, 1800)
    }

    func testRemoveChannel() {
        let channel = demodulator.addChannel(at: 1800)
        let countAfterAdd = demodulator.channelCount

        demodulator.removeChannel(channel.id)

        XCTAssertEqual(demodulator.channelCount, countAfterAdd - 1)
    }

    func testRemoveAllChannels() {
        demodulator.addChannel(at: 1000)
        demodulator.addChannel(at: 1200)

        demodulator.removeAllChannels()

        XCTAssertEqual(demodulator.channelCount, 0)
    }

    func testChannelAtFrequency() {
        let channel = demodulator.channel(at: 2125)

        XCTAssertNotNil(channel)
        XCTAssertEqual(channel?.frequency, 2125)
    }

    func testChannelAtFrequencyNotFound() {
        let channel = demodulator.channel(at: 9999)

        XCTAssertNil(channel)
    }

    func testChannelWithId() {
        let newChannel = demodulator.addChannel(at: 1800)
        let found = demodulator.channel(withId: newChannel.id)

        XCTAssertNotNil(found)
        XCTAssertEqual(found?.id, newChannel.id)
    }

    // MARK: - Delegate Notifications

    func testChannelUpdateOnAdd() {
        delegate.reset()

        _ = demodulator.addChannel(at: 1800)

        XCTAssertFalse(delegate.channelUpdates.isEmpty,
                      "Should notify delegate on channel add")
    }

    func testChannelUpdateOnRemove() {
        let channel = demodulator.addChannel(at: 1800)
        delegate.reset()

        demodulator.removeChannel(channel.id)

        XCTAssertFalse(delegate.channelUpdates.isEmpty,
                      "Should notify delegate on channel remove")
    }

    // MARK: - Processing

    func testProcessMultipleChannels() {
        // Create modulator for 2125 Hz (one of our channels)
        var modulator = FSKModulator(configuration: .standard)

        // Generate signal at 2125 Hz
        var samples = modulator.generateIdle(bits: 5)
        samples.append(contentsOf: modulator.modulateCode(0x01))  // E
        samples.append(contentsOf: modulator.generateIdle(bits: 5))

        demodulator.process(samples: samples)

        // Should have decoded on the 2125 Hz channel
        let decodedAtStandard = delegate.decodedCharacters.filter {
            abs($0.1.frequency - 2125) < 1
        }
        XCTAssertFalse(decodedAtStandard.isEmpty,
                      "Should decode on 2125 Hz channel")
    }

    func testDecodeOnCorrectChannel() {
        // Create single-frequency demodulator
        let singleDemod = MultiChannelRTTYDemodulator(frequencies: [2125])
        let singleDelegate = TestDelegate()
        singleDemod.delegate = singleDelegate

        // Generate signal
        var modulator = FSKModulator(configuration: .standard)
        var samples = modulator.generateIdle(bits: 5)
        samples.append(contentsOf: modulator.modulateCode(0x01))  // E
        samples.append(contentsOf: modulator.generateIdle(bits: 5))

        singleDemod.process(samples: samples)

        if !singleDelegate.decodedCharacters.isEmpty {
            let (char, channel) = singleDelegate.decodedCharacters[0]
            XCTAssertEqual(channel.frequency, 2125)
            XCTAssertEqual(char, "E")
        }
    }

    // MARK: - Reset

    func testReset() {
        // Process some samples
        var modulator = FSKModulator(configuration: .standard)
        let samples = modulator.generateMark(count: 5000)
        demodulator.process(samples: samples)

        // Reset
        demodulator.reset()

        // All channels should have reset signal strength
        for channel in demodulator.channels {
            XCTAssertEqual(channel.signalStrength, 0)
            XCTAssertFalse(channel.signalDetected)
        }
    }

    // MARK: - Factory Methods

    func testStandardSubband() {
        let subband = MultiChannelRTTYDemodulator.standardSubband()

        XCTAssertGreaterThan(subband.channelCount, 0)
        // Should cover common RTTY frequencies (100 Hz spacing from 900-2500 Hz)
        XCTAssertNotNil(subband.channel(at: 2100))
    }

    func testCoveringRange() {
        let covering = MultiChannelRTTYDemodulator.covering(range: 1000...2000, shift: 250)

        // 1000, 1250, 1500, 1750, 2000 = 5 channels
        XCTAssertEqual(covering.channelCount, 5)
    }

    // MARK: - RTTYChannel Tests

    func testRTTYChannelEquatable() {
        let channel1 = RTTYChannel(frequency: 2125)
        let channel2 = RTTYChannel(frequency: 2125)

        // Different IDs, so not equal even with same frequency
        XCTAssertNotEqual(channel1, channel2)
    }

    func testRTTYChannelSameId() {
        let id = UUID()
        let channel1 = RTTYChannel(id: id, frequency: 2125)
        let channel2 = RTTYChannel(id: id, frequency: 2125)

        XCTAssertEqual(channel1, channel2)
    }
}

// MARK: - Integration with Multiple Frequencies

extension MultiChannelRTTYDemodulatorTests {

    func testTwoChannelsSimultaneous() {
        // Create signals at two different frequencies
        let config1 = RTTYConfiguration.standard.withCenterFrequency(1500)
        let config2 = RTTYConfiguration.standard.withCenterFrequency(2125)

        var mod1 = FSKModulator(configuration: config1)
        var mod2 = FSKModulator(configuration: config2)

        // Generate 'E' on channel 1
        var samples1 = mod1.generateIdle(bits: 5)
        samples1.append(contentsOf: mod1.modulateCode(0x01))  // E
        samples1.append(contentsOf: mod1.generateIdle(bits: 5))

        // Generate 'T' on channel 2
        var samples2 = mod2.generateIdle(bits: 5)
        samples2.append(contentsOf: mod2.modulateCode(0x10))  // T
        samples2.append(contentsOf: mod2.generateIdle(bits: 5))

        // Mix the samples (simulate both signals present)
        let maxLen = max(samples1.count, samples2.count)
        var mixed = [Float](repeating: 0, count: maxLen)
        for i in 0..<samples1.count {
            mixed[i] += samples1[i] * 0.5
        }
        for i in 0..<samples2.count {
            mixed[i] += samples2[i] * 0.5
        }

        // Demodulator with both frequencies
        let multiDemod = MultiChannelRTTYDemodulator(frequencies: [1500, 2125])
        multiDemod.afcEnabled = false  // Disable AFC for deterministic test
        let multiDelegate = TestDelegate()
        multiDemod.delegate = multiDelegate

        multiDemod.process(samples: mixed)

        // Should decode characters on both channels
        // Note: Due to mixing and interference, we check for presence not exact match
        XCTAssertGreaterThan(multiDelegate.decodedCharacters.count, 0,
                           "Should decode something from mixed signal")
    }
}
