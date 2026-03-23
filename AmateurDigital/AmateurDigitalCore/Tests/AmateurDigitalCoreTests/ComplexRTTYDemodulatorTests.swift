//
//  ComplexRTTYDemodulatorTests.swift
//  AmateurDigitalCoreTests
//
//  Tests for the fldigi-style complex RTTY demodulator.
//  Verifies round-trip encoding → decoding for clean signals.
//

import XCTest
@testable import AmateurDigitalCore

final class ComplexRTTYDemodulatorTests: XCTestCase {

    // MARK: - Test Delegate

    class TestDelegate: ComplexRTTYDemodulatorDelegate {
        var decodedCharacters: [Character] = []
        var signalStates: [Bool] = []

        var decodedText: String { String(decodedCharacters) }

        func demodulator(
            _ demodulator: ComplexRTTYDemodulator,
            didDecode character: Character,
            atFrequency frequency: Double
        ) {
            decodedCharacters.append(character)
        }

        func demodulator(
            _ demodulator: ComplexRTTYDemodulator,
            signalDetected detected: Bool,
            atFrequency frequency: Double
        ) {
            signalStates.append(detected)
        }

        func reset() {
            decodedCharacters.removeAll()
            signalStates.removeAll()
        }
    }

    // MARK: - Helper

    /// Generate RTTY test audio using FSKModulator and decode with ComplexRTTYDemodulator.
    /// Returns the decoded text.
    private func roundTrip(
        text: String,
        configuration: RTTYConfiguration = .standard,
        preambleMs: Double = 300,
        postambleMs: Double = 200
    ) -> String {
        var modulator = FSKModulator(configuration: configuration)
        let demodulator = ComplexRTTYDemodulator(configuration: configuration)
        let delegate = TestDelegate()
        demodulator.delegate = delegate

        let samples = modulator.modulateTextWithIdle(
            text,
            preambleMs: preambleMs,
            postambleMs: postambleMs
        )
        demodulator.process(samples: samples)

        return delegate.decodedText
    }

    // MARK: - Basic Round Trip Tests

    func testRoundTripSingleLetter() {
        let text = roundTrip(text: "E")
        XCTAssertTrue(text.contains("E"),
                     "Should decode 'E'. Got: '\(text)'")
    }

    func testRoundTripRYRY() {
        // RYRY is a classic RTTY test pattern — alternating mark/space
        let text = roundTrip(text: "RYRYRYRY")
        XCTAssertTrue(text.contains("R"),
                     "Should decode 'R'. Got: '\(text)'")
        XCTAssertTrue(text.contains("Y"),
                     "Should decode 'Y'. Got: '\(text)'")
    }

    func testRoundTripCQMessage() {
        let text = roundTrip(text: "CQ CQ DE W1AW K")
        // Check for key characters (letters only, no numbers)
        XCTAssertTrue(text.contains("C"), "Should decode 'C'. Got: '\(text)'")
        XCTAssertTrue(text.contains("Q"), "Should decode 'Q'. Got: '\(text)'")
        XCTAssertTrue(text.contains("D"), "Should decode 'D'. Got: '\(text)'")
        XCTAssertTrue(text.contains("E"), "Should decode 'E'. Got: '\(text)'")
        XCTAssertTrue(text.contains("K"), "Should decode 'K'. Got: '\(text)'")
    }

    func testRoundTripShortMessage() {
        let text = roundTrip(text: "CQ CQ CQ")
        XCTAssertTrue(text.contains("C"), "Should decode 'C'. Got: '\(text)'")
        XCTAssertTrue(text.contains("Q"), "Should decode 'Q'. Got: '\(text)'")
        XCTAssertTrue(text.contains(" "), "Should decode space. Got: '\(text)'")
    }

    func testRoundTripLettersOnly() {
        // Pure letters, no FIGS shift needed — simplest case
        let text = roundTrip(text: "HELLO WORLD")
        XCTAssertTrue(text.contains("H"), "Should decode 'H'. Got: '\(text)'")
        XCTAssertTrue(text.contains("L"), "Should decode 'L'. Got: '\(text)'")
        XCTAssertTrue(text.contains("O"), "Should decode 'O'. Got: '\(text)'")
    }

    // MARK: - Different Configurations

    func testRoundTripBaud50() {
        let config = RTTYConfiguration.baud50
        let text = roundTrip(text: "TEST", configuration: config)
        XCTAssertTrue(text.contains("T") || text.contains("E"),
                     "Should decode at 50 baud. Got: '\(text)'")
    }

    func testRoundTripWideShift() {
        let config = RTTYConfiguration.wide425
        let text = roundTrip(text: "CQ", configuration: config)
        XCTAssertTrue(text.contains("C") || text.contains("Q"),
                     "Should decode with 425 Hz shift. Got: '\(text)'")
    }

    func testRoundTripDifferentFrequency() {
        let config = RTTYConfiguration(
            baudRate: 45.45,
            markFrequency: 1500.0,
            shift: 170.0,
            sampleRate: 48000.0
        )
        let text = roundTrip(text: "TEST", configuration: config)
        XCTAssertTrue(text.contains("T") || text.contains("E") || text.contains("S"),
                     "Should decode at 1500 Hz center. Got: '\(text)'")
    }

    // MARK: - Noise Tolerance

    func testRoundTripWithLightNoise() {
        let config = RTTYConfiguration.standard
        var modulator = FSKModulator(configuration: config)
        let demodulator = ComplexRTTYDemodulator(configuration: config)
        let delegate = TestDelegate()
        demodulator.delegate = delegate

        let samples = modulator.modulateTextWithIdle(
            "CQ CQ CQ",
            preambleMs: 300,
            postambleMs: 200
        )

        // Add 10% noise
        let noisySamples = samples.map { sample -> Float in
            sample + Float.random(in: -0.1...0.1)
        }

        demodulator.process(samples: noisySamples)

        let text = delegate.decodedText
        XCTAssertFalse(text.isEmpty, "Should decode something with 10% noise. Got: '\(text)'")
    }

    // MARK: - Reset

    func testReset() {
        let demodulator = ComplexRTTYDemodulator(configuration: .standard)
        let delegate = TestDelegate()
        demodulator.delegate = delegate

        var modulator = FSKModulator(configuration: .standard)
        let samples = modulator.modulateTextWithIdle("TEST", preambleMs: 300, postambleMs: 200)
        demodulator.process(samples: samples)

        demodulator.reset()

        // After reset, shift state should be back to letters
        XCTAssertEqual(demodulator.currentShiftState, .letters,
                      "Reset should restore letters shift")
    }

    // MARK: - Tune

    func testTune() {
        let demodulator = ComplexRTTYDemodulator(configuration: .standard)
        XCTAssertEqual(demodulator.centerFrequency, 2125.0)

        demodulator.tune(to: 1800.0)
        XCTAssertEqual(demodulator.centerFrequency, 1800.0)
    }
}
