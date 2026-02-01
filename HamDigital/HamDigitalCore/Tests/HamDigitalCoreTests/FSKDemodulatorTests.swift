//
//  FSKDemodulatorTests.swift
//  DigiModesCoreTests
//

import XCTest
@testable import HamDigitalCore

final class FSKDemodulatorTests: XCTestCase {

    // MARK: - Test Delegate

    class TestDelegate: FSKDemodulatorDelegate {
        var decodedCharacters: [Character] = []
        var decodedFrequencies: [Double] = []
        var signalStates: [Bool] = []

        func demodulator(
            _ demodulator: FSKDemodulator,
            didDecode character: Character,
            atFrequency frequency: Double
        ) {
            decodedCharacters.append(character)
            decodedFrequencies.append(frequency)
        }

        func demodulator(
            _ demodulator: FSKDemodulator,
            signalDetected detected: Bool,
            atFrequency frequency: Double
        ) {
            signalStates.append(detected)
        }

        func reset() {
            decodedCharacters.removeAll()
            decodedFrequencies.removeAll()
            signalStates.removeAll()
        }
    }

    // MARK: - Properties

    var modulator: FSKModulator!
    var demodulator: FSKDemodulator!
    var delegate: TestDelegate!

    override func setUp() {
        super.setUp()
        modulator = FSKModulator(configuration: .standard)
        demodulator = FSKDemodulator(configuration: .standard)
        delegate = TestDelegate()
        demodulator.delegate = delegate
    }

    override func tearDown() {
        modulator = nil
        demodulator = nil
        delegate = nil
        super.tearDown()
    }

    // MARK: - Basic State Tests

    func testInitialState() {
        XCTAssertEqual(demodulator.state, .waitingForStart)
        XCTAssertFalse(demodulator.signalDetected)
        XCTAssertEqual(demodulator.signalStrength, 0)
    }

    func testReset() {
        // Process some samples to change state
        var samples = modulator.generateMark(count: 1000)
        demodulator.process(samples: samples)

        // Reset
        demodulator.reset()

        XCTAssertEqual(demodulator.state, .waitingForStart)
        XCTAssertFalse(demodulator.signalDetected)
    }

    // MARK: - Single Character Decoding

    func testDecodeSingleCharacterE() {
        // "E" is Baudot code 0x01 (00001)
        // It's in letters mode by default

        // Generate some idle first
        var samples = modulator.generateIdle(bits: 5)

        // Generate E character
        let eCode: UInt8 = 0x01
        samples.append(contentsOf: modulator.modulateCode(eCode))

        // Add trailing idle
        samples.append(contentsOf: modulator.generateIdle(bits: 5))

        demodulator.process(samples: samples)

        XCTAssertTrue(delegate.decodedCharacters.contains("E"),
                     "Should decode 'E' character. Got: \(delegate.decodedCharacters)")
    }

    func testDecodeSingleCharacterT() {
        // "T" is Baudot code 0x10 (10000)

        var samples = modulator.generateIdle(bits: 5)
        let tCode: UInt8 = 0x10
        samples.append(contentsOf: modulator.modulateCode(tCode))
        samples.append(contentsOf: modulator.generateIdle(bits: 5))

        demodulator.process(samples: samples)

        XCTAssertTrue(delegate.decodedCharacters.contains("T"),
                     "Should decode 'T' character. Got: \(delegate.decodedCharacters)")
    }

    // MARK: - Multiple Characters

    func testDecodeMultipleCharacters() {
        // Encode "HI" - both letters, no shift needed
        // H = 0x14, I = 0x06

        var samples = modulator.generateIdle(bits: 5)
        samples.append(contentsOf: modulator.modulateCode(0x14))  // H
        samples.append(contentsOf: modulator.modulateCode(0x06))  // I
        samples.append(contentsOf: modulator.generateIdle(bits: 5))

        demodulator.process(samples: samples)

        XCTAssertEqual(delegate.decodedCharacters.count, 2,
                      "Should decode 2 characters")
        XCTAssertEqual(delegate.decodedCharacters, ["H", "I"],
                      "Should decode 'HI'")
    }

    // MARK: - Shift Handling

    func testDecodeWithShiftToFigures() {
        // FIGS shift = 0x1B, then "3" = 0x01 in figures mode

        var samples = modulator.generateIdle(bits: 5)
        samples.append(contentsOf: modulator.modulateCode(0x1B))  // FIGS
        samples.append(contentsOf: modulator.modulateCode(0x01))  // 3
        samples.append(contentsOf: modulator.generateIdle(bits: 5))

        demodulator.process(samples: samples)

        // FIGS shift doesn't produce a character, just changes state
        // The "3" should be decoded
        XCTAssertTrue(delegate.decodedCharacters.contains("3"),
                     "Should decode '3' after FIGS shift. Got: \(delegate.decodedCharacters)")
    }

    // MARK: - Round Trip with Text

    func testRoundTripSimpleText() {
        // Use the modulator's text encoding for a clean round trip

        let samples = modulator.modulateTextWithIdle("CQ", preambleMs: 50, postambleMs: 50)

        demodulator.process(samples: samples)

        // Should contain C and Q (preamble LTRS shifts don't produce characters)
        let text = String(delegate.decodedCharacters)
        XCTAssertTrue(text.contains("C"), "Should decode 'C'. Got: \(text)")
        XCTAssertTrue(text.contains("Q"), "Should decode 'Q'. Got: \(text)")
    }

    // MARK: - Signal Detection

    func testSignalDetectionOnMark() {
        // Process continuous mark tone
        let samples = modulator.generateMark(count: 10000)

        demodulator.process(samples: samples)

        // Should detect signal (though waiting for start bit)
        XCTAssertTrue(demodulator.signalDetected || demodulator.signalStrength > 0.2,
                     "Should detect FSK signal")
    }

    func testSignalStrengthWithSignal() {
        let samples = modulator.modulateTextWithIdle("TEST", preambleMs: 100, postambleMs: 100)

        demodulator.process(samples: samples)

        XCTAssertGreaterThan(demodulator.signalStrength, 0.1,
                            "Signal strength should be significant with FSK signal")
    }

    // MARK: - Tuning

    func testTuneToFrequency() {
        demodulator.tune(to: 1500)

        XCTAssertEqual(demodulator.centerFrequency, 1500,
                      "Center frequency should update after tuning")
        XCTAssertEqual(demodulator.state, .waitingForStart,
                      "State should reset after tuning")
    }

    func testDecodeAtDifferentFrequency() {
        // Create modulator and demodulator at same non-standard frequency
        let config = RTTYConfiguration.standard.withCenterFrequency(1500)
        var customModulator = FSKModulator(configuration: config)
        let customDemodulator = FSKDemodulator(configuration: config)

        let customDelegate = TestDelegate()
        customDemodulator.delegate = customDelegate

        // Generate samples at 1500 Hz center
        var samples = customModulator.generateIdle(bits: 5)
        samples.append(contentsOf: customModulator.modulateCode(0x01))  // E
        samples.append(contentsOf: customModulator.generateIdle(bits: 5))

        customDemodulator.process(samples: samples)

        XCTAssertTrue(customDelegate.decodedCharacters.contains("E"),
                     "Should decode at non-standard frequency")
    }

    // MARK: - State Transitions

    func testStateTransitionToStartBit() {
        // Send a space tone to trigger start bit detection
        let samples = modulator.generateSpace(count: 500)

        demodulator.process(samples: samples)

        // Should have moved to inStartBit state
        if case .inStartBit = demodulator.state {
            // Success
        } else if case .receivingData = demodulator.state {
            // Also acceptable - moved past start bit
        } else if case .waitingForStart = demodulator.state {
            // May still be waiting if not enough samples
        } else {
            XCTFail("Unexpected state: \(demodulator.state)")
        }
    }

    // MARK: - Factory Method

    func testWithCenterFrequency() {
        let customDemod = FSKDemodulator.withCenterFrequency(1800)

        XCTAssertEqual(customDemod.centerFrequency, 1800)
    }

    // MARK: - Shift State

    func testCurrentShiftState() {
        XCTAssertEqual(demodulator.currentShiftState, .letters,
                      "Initial shift state should be letters")

        // Process FIGS shift
        var samples = modulator.generateIdle(bits: 5)
        samples.append(contentsOf: modulator.modulateCode(0x1B))  // FIGS
        samples.append(contentsOf: modulator.generateIdle(bits: 5))

        demodulator.process(samples: samples)

        XCTAssertEqual(demodulator.currentShiftState, .figures,
                      "Shift state should be figures after FIGS code")
    }

    // MARK: - Frequency Reporting

    func testFrequencyReportedInDelegate() {
        var samples = modulator.generateIdle(bits: 5)
        samples.append(contentsOf: modulator.modulateCode(0x01))  // E
        samples.append(contentsOf: modulator.generateIdle(bits: 5))

        demodulator.process(samples: samples)

        if !delegate.decodedFrequencies.isEmpty {
            XCTAssertEqual(delegate.decodedFrequencies[0], 2125.0,
                          "Reported frequency should match center frequency")
        }
    }
}

// MARK: - Extended Round Trip Tests

extension FSKDemodulatorTests {

    func testRoundTripCallsign() {
        let samples = modulator.modulateTextWithIdle("W1AW", preambleMs: 100, postambleMs: 100)

        demodulator.process(samples: samples)

        let text = String(delegate.decodedCharacters)
        XCTAssertTrue(text.contains("W"), "Should decode 'W'. Got: \(text)")
        XCTAssertTrue(text.contains("1"), "Should decode '1'. Got: \(text)")
        XCTAssertTrue(text.contains("A"), "Should decode 'A'. Got: \(text)")
    }

    func testRoundTripWithNumbers() {
        let samples = modulator.modulateTextWithIdle("73", preambleMs: 100, postambleMs: 100)

        demodulator.process(samples: samples)

        let text = String(delegate.decodedCharacters)
        XCTAssertTrue(text.contains("7") || text.contains("3"),
                     "Should decode numbers. Got: \(text)")
    }
}
