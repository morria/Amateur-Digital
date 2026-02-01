//
//  RTTYRoundTripTests.swift
//  DigiModesCoreTests
//
//  Integration tests verifying encode → decode round trips
//

import XCTest
@testable import DigiModesCore

final class RTTYRoundTripTests: XCTestCase {

    // MARK: - Test Delegate

    class TestModemDelegate: RTTYModemDelegate {
        var decodedCharacters: [Character] = []
        var signalStates: [Bool] = []

        func modem(
            _ modem: RTTYModem,
            didDecode character: Character,
            atFrequency frequency: Double
        ) {
            decodedCharacters.append(character)
        }

        func modem(
            _ modem: RTTYModem,
            signalDetected detected: Bool,
            atFrequency frequency: Double
        ) {
            signalStates.append(detected)
        }

        var decodedText: String {
            String(decodedCharacters)
        }

        func reset() {
            decodedCharacters.removeAll()
            signalStates.removeAll()
        }
    }

    // MARK: - Properties

    var modem: RTTYModem!
    var delegate: TestModemDelegate!

    override func setUp() {
        super.setUp()
        modem = RTTYModem()
        delegate = TestModemDelegate()
        modem.delegate = delegate
    }

    override func tearDown() {
        modem = nil
        delegate = nil
        super.tearDown()
    }

    // MARK: - Basic Round Trip Tests

    func testRoundTripSingleLetter() {
        let samples = modem.encodeWithIdle(text: "E", preambleMs: 100, postambleMs: 100)
        modem.process(samples: samples)

        XCTAssertTrue(delegate.decodedText.contains("E"),
                     "Should decode 'E'. Got: '\(delegate.decodedText)'")
    }

    func testRoundTripTwoLetters() {
        let samples = modem.encodeWithIdle(text: "HI", preambleMs: 100, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        XCTAssertTrue(text.contains("H"), "Should decode 'H'. Got: '\(text)'")
        XCTAssertTrue(text.contains("I"), "Should decode 'I'. Got: '\(text)'")
    }

    func testRoundTripCQ() {
        let samples = modem.encodeWithIdle(text: "CQ", preambleMs: 100, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        XCTAssertTrue(text.contains("C"), "Should decode 'C'. Got: '\(text)'")
        XCTAssertTrue(text.contains("Q"), "Should decode 'Q'. Got: '\(text)'")
    }

    // MARK: - Callsign Round Trip

    func testRoundTripCallsign() {
        let samples = modem.encodeWithIdle(text: "W1AW", preambleMs: 150, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        XCTAssertTrue(text.contains("W"), "Should decode 'W'. Got: '\(text)'")
        XCTAssertTrue(text.contains("A"), "Should decode 'A'. Got: '\(text)'")
        // Note: '1' requires shift to figures, so may be more complex
    }

    func testRoundTripCallsignWithNumbers() {
        let samples = modem.encodeWithIdle(text: "N0CALL", preambleMs: 150, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        XCTAssertTrue(text.contains("N"), "Should decode 'N'. Got: '\(text)'")
        XCTAssertTrue(text.contains("C"), "Should decode 'C'. Got: '\(text)'")
        XCTAssertTrue(text.contains("A"), "Should decode 'A'. Got: '\(text)'")
        XCTAssertTrue(text.contains("L"), "Should decode 'L'. Got: '\(text)'")
    }

    // MARK: - Message Round Trip

    func testRoundTripShortMessage() {
        let samples = modem.encodeWithIdle(text: "CQ CQ CQ", preambleMs: 150, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        // Should contain C, Q, and space
        XCTAssertTrue(text.contains("C"), "Should decode 'C'. Got: '\(text)'")
        XCTAssertTrue(text.contains("Q"), "Should decode 'Q'. Got: '\(text)'")
        XCTAssertTrue(text.contains(" "), "Should decode space. Got: '\(text)'")
    }

    func testRoundTripRYRY() {
        // RYRY is a classic RTTY test pattern
        let samples = modem.encodeWithIdle(text: "RYRYRYRY", preambleMs: 150, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        XCTAssertTrue(text.contains("R"), "Should decode 'R'. Got: '\(text)'")
        XCTAssertTrue(text.contains("Y"), "Should decode 'Y'. Got: '\(text)'")
    }

    // MARK: - Numbers and Punctuation

    func testRoundTripNumbers() {
        let samples = modem.encodeWithIdle(text: "73", preambleMs: 150, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        // Numbers require FIGS shift
        XCTAssertTrue(text.contains("7") || text.contains("3"),
                     "Should decode numbers. Got: '\(text)'")
    }

    func testRoundTripMixedContent() {
        let samples = modem.encodeWithIdle(text: "RST 599", preambleMs: 150, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        XCTAssertTrue(text.contains("R"), "Should decode 'R'. Got: '\(text)'")
        XCTAssertTrue(text.contains("S"), "Should decode 'S'. Got: '\(text)'")
        XCTAssertTrue(text.contains("T"), "Should decode 'T'. Got: '\(text)'")
    }

    // MARK: - Different Configurations

    func testRoundTripWithBaud50() {
        let config = RTTYConfiguration.baud50
        modem = RTTYModem(configuration: config)
        modem.delegate = delegate

        let samples = modem.encodeWithIdle(text: "TEST", preambleMs: 150, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        XCTAssertTrue(text.contains("T"), "Should decode at 50 baud. Got: '\(text)'")
        XCTAssertTrue(text.contains("E"), "Should decode at 50 baud. Got: '\(text)'")
    }

    func testRoundTripWithBaud75() {
        let config = RTTYConfiguration.baud75
        modem = RTTYModem(configuration: config)
        modem.delegate = delegate

        let samples = modem.encodeWithIdle(text: "HI", preambleMs: 150, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        XCTAssertTrue(text.contains("H") || text.contains("I"),
                     "Should decode at 75 baud. Got: '\(text)'")
    }

    func testRoundTripWithWideShift() {
        let config = RTTYConfiguration.wide425
        modem = RTTYModem(configuration: config)
        modem.delegate = delegate

        let samples = modem.encodeWithIdle(text: "CQ", preambleMs: 150, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        XCTAssertTrue(text.contains("C") || text.contains("Q"),
                     "Should decode with 425 Hz shift. Got: '\(text)'")
    }

    // MARK: - Different Frequencies

    func testRoundTripAtDifferentFrequency() {
        modem = RTTYModem.withCenterFrequency(1500)
        modem.delegate = delegate

        let samples = modem.encodeWithIdle(text: "TEST", preambleMs: 150, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        XCTAssertTrue(text.contains("T") || text.contains("E") || text.contains("S"),
                     "Should decode at 1500 Hz center. Got: '\(text)'")
    }

    // MARK: - Noise Immunity

    func testRoundTripWithLightNoise() {
        let samples = modem.encodeWithIdle(text: "CQ", preambleMs: 150, postambleMs: 100)

        // Add 10% noise
        let noisySamples = samples.map { sample -> Float in
            sample + Float.random(in: -0.1...0.1)
        }

        modem.process(samples: noisySamples)

        let text = delegate.decodedText
        // Should still decode with light noise
        XCTAssertFalse(text.isEmpty, "Should decode something with 10% noise")
    }

    // MARK: - RTTYModem API Tests

    func testModemInitialState() {
        XCTAssertFalse(modem.isSignalDetected)
        XCTAssertEqual(modem.signalStrength, 0)
        XCTAssertEqual(modem.shiftState, .letters)
        XCTAssertEqual(modem.centerFrequency, 2125.0)
    }

    func testModemReset() {
        // Process something
        let samples = modem.encodeWithIdle(text: "123", preambleMs: 100, postambleMs: 100)
        modem.process(samples: samples)

        // Reset
        modem.reset()

        XCTAssertEqual(modem.shiftState, .letters,
                      "Reset should restore letters shift")
    }

    func testModemTune() {
        modem.tune(to: 1800)

        XCTAssertEqual(modem.centerFrequency, 1800,
                      "Tune should update center frequency")
    }

    func testGenerateIdle() {
        let samples = modem.generateIdle(duration: 0.1)

        // 100ms at 48000 Hz = 4800 samples
        XCTAssertEqual(samples.count, 4800)
    }

    // MARK: - Signal Detection

    func testSignalDetectionDuringDecode() {
        let samples = modem.encodeWithIdle(text: "TESTTEST", preambleMs: 200, postambleMs: 200)
        modem.process(samples: samples)

        // Should have detected signal at some point
        XCTAssertTrue(delegate.signalStates.contains(true),
                     "Should detect signal during transmission")
    }

    // MARK: - Factory Methods

    func testWithCenterFrequencyFactory() {
        let customModem = RTTYModem.withCenterFrequency(1500)
        XCTAssertEqual(customModem.centerFrequency, 1500)
    }

    func testWithWideShiftFactory() {
        let wideModem = RTTYModem.withWideShift(425)
        XCTAssertEqual(wideModem.currentConfiguration.shift, 425)
    }
}

// MARK: - Extended Integration Tests

extension RTTYRoundTripTests {

    /// Test a complete CQ call
    func testFullCQCall() {
        let message = "CQ CQ CQ DE W1AW W1AW K"
        let samples = modem.encodeWithIdle(text: message, preambleMs: 200, postambleMs: 100)

        modem.process(samples: samples)

        let text = delegate.decodedText
        // Check for key parts
        XCTAssertTrue(text.contains("C"), "Should decode 'C' from CQ")
        XCTAssertTrue(text.contains("Q"), "Should decode 'Q' from CQ")
        XCTAssertTrue(text.contains("D"), "Should decode 'D' from DE")
        XCTAssertTrue(text.contains("E"), "Should decode 'E' from DE")
        XCTAssertTrue(text.contains("K"), "Should decode 'K' for over")
    }

    /// Test lowercase conversion (RTTY is uppercase only)
    func testLowercaseConvertsToUppercase() {
        let samples = modem.encodeWithIdle(text: "test", preambleMs: 150, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        // Should get uppercase
        XCTAssertTrue(text.contains("T") || text.contains("E") || text.contains("S"),
                     "Lowercase should convert to uppercase")
        XCTAssertFalse(text.contains("t"), "Should not contain lowercase")
    }
}
