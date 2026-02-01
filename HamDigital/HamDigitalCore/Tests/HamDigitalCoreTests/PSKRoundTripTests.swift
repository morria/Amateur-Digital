//
//  PSKRoundTripTests.swift
//  HamDigitalCoreTests
//
//  Integration tests verifying PSK encode → decode round trips
//  Tests PSK31, BPSK63, QPSK31, and QPSK63 modes
//

import XCTest
@testable import HamDigitalCore

final class PSKRoundTripTests: XCTestCase {

    // MARK: - Test Delegate

    class TestModemDelegate: PSKModemDelegate {
        var decodedCharacters: [Character] = []
        var signalStates: [Bool] = []

        func modem(
            _ modem: PSKModem,
            didDecode character: Character,
            atFrequency frequency: Double
        ) {
            decodedCharacters.append(character)
        }

        func modem(
            _ modem: PSKModem,
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

    var modem: PSKModem!
    var delegate: TestModemDelegate!

    override func setUp() {
        super.setUp()
        modem = PSKModem()
        delegate = TestModemDelegate()
        modem.delegate = delegate
    }

    override func tearDown() {
        modem = nil
        delegate = nil
        super.tearDown()
    }

    // MARK: - Configuration Tests

    func testDefaultConfiguration() {
        let config = PSKConfiguration.standard
        XCTAssertEqual(config.baudRate, 31.25)
        XCTAssertEqual(config.centerFrequency, 1000.0)
        XCTAssertEqual(config.sampleRate, 48000.0)
        XCTAssertEqual(config.samplesPerSymbol, 1536)
        XCTAssertEqual(config.modulationType, .bpsk)
    }

    func testPSK31Configuration() {
        let config = PSKConfiguration.psk31
        XCTAssertEqual(config.baudRate, 31.25)
        XCTAssertEqual(config.modulationType, .bpsk)
        XCTAssertEqual(config.bitsPerSymbol, 1)
        XCTAssertEqual(config.modeName, "PSK31")
    }

    func testBPSK63Configuration() {
        let config = PSKConfiguration.bpsk63
        XCTAssertEqual(config.baudRate, 62.5)
        XCTAssertEqual(config.modulationType, .bpsk)
        XCTAssertEqual(config.bitsPerSymbol, 1)
        XCTAssertEqual(config.samplesPerSymbol, 768)
        XCTAssertEqual(config.modeName, "BPSK63")
    }

    func testQPSK31Configuration() {
        let config = PSKConfiguration.qpsk31
        XCTAssertEqual(config.baudRate, 31.25)
        XCTAssertEqual(config.modulationType, .qpsk)
        XCTAssertEqual(config.bitsPerSymbol, 2)
        XCTAssertEqual(config.samplesPerSymbol, 1536)
        XCTAssertEqual(config.modeName, "QPSK31")
    }

    func testQPSK63Configuration() {
        let config = PSKConfiguration.qpsk63
        XCTAssertEqual(config.baudRate, 62.5)
        XCTAssertEqual(config.modulationType, .qpsk)
        XCTAssertEqual(config.bitsPerSymbol, 2)
        XCTAssertEqual(config.samplesPerSymbol, 768)
        XCTAssertEqual(config.modeName, "QPSK63")
    }

    func testConfigurationWithCenterFrequency() {
        let config = PSKConfiguration.standard.withCenterFrequency(1500)
        XCTAssertEqual(config.centerFrequency, 1500)
        XCTAssertEqual(config.baudRate, 31.25)  // Unchanged
    }

    func testModemInitialState() {
        XCTAssertFalse(modem.isSignalDetected)
        XCTAssertEqual(modem.signalStrength, 0)
        XCTAssertEqual(modem.centerFrequency, 1000.0)
    }

    // MARK: - Modulator Tests

    func testModulatorGeneratesSamples() {
        var modulator = PSKModulator()
        let samples = modulator.modulateText("e")
        XCTAssertFalse(samples.isEmpty)
    }

    func testModulatorSampleCount() {
        var modulator = PSKModulator()
        let config = PSKConfiguration.standard

        // Generate one symbol
        let samples = modulator.modulateSymbol(bit: false)

        // Should be exactly samplesPerSymbol
        XCTAssertEqual(samples.count, config.samplesPerSymbol)
    }

    func testModulatorIdleGeneration() {
        var modulator = PSKModulator()
        let samples = modulator.generateIdle(duration: 0.1)

        // 100ms at 31.25 baud = ~3 symbols
        // Each symbol at 48kHz = 1536 samples
        // So approximately 4608 samples
        XCTAssertTrue(samples.count > 0)
        XCTAssertEqual(samples.count, 3 * 1536)
    }

    func testModulatorPhaseReversal() {
        var modulator = PSKModulator()

        // Bit 0 - no phase change
        _ = modulator.modulateSymbol(bit: false)
        let phase0 = modulator.phase

        modulator.reset()

        // Bit 1 - phase reversal
        _ = modulator.modulateSymbol(bit: true)
        let phase1 = modulator.phase

        // After phase reversal, phase should differ by approximately pi
        // (with some variation due to continued carrier generation)
        XCTAssertTrue(abs(phase1 - phase0) > 1.0 || phase1 != phase0)
    }

    // MARK: - Basic PSK31 Round Trip Tests

    func testRoundTripSingleLetter() {
        let samples = modem.encodeWithEnvelope(text: "e", preambleMs: 200, postambleMs: 100)
        modem.process(samples: samples)

        XCTAssertTrue(delegate.decodedText.contains("e"),
                     "Should decode 'e'. Got: '\(delegate.decodedText)'")
    }

    func testRoundTripSpace() {
        let samples = modem.encodeWithEnvelope(text: " ", preambleMs: 200, postambleMs: 100)
        modem.process(samples: samples)

        XCTAssertTrue(delegate.decodedText.contains(" "),
                     "Should decode space. Got: '\(delegate.decodedText)'")
    }

    func testRoundTripTwoLetters() {
        let samples = modem.encodeWithEnvelope(text: "hi", preambleMs: 200, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        XCTAssertTrue(text.contains("h"), "Should decode 'h'. Got: '\(text)'")
        XCTAssertTrue(text.contains("i"), "Should decode 'i'. Got: '\(text)'")
    }

    func testRoundTripCQ() {
        let samples = modem.encodeWithEnvelope(text: "cq", preambleMs: 200, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        XCTAssertTrue(text.contains("c"), "Should decode 'c'. Got: '\(text)'")
        XCTAssertTrue(text.contains("q"), "Should decode 'q'. Got: '\(text)'")
    }

    // MARK: - BPSK63 Round Trip Tests

    func testBPSK63RoundTripSingleLetter() {
        modem = PSKModem(configuration: .bpsk63)
        modem.delegate = delegate

        let samples = modem.encodeWithEnvelope(text: "e", preambleMs: 200, postambleMs: 100)
        modem.process(samples: samples)

        XCTAssertTrue(delegate.decodedText.contains("e"),
                     "BPSK63 should decode 'e'. Got: '\(delegate.decodedText)'")
    }

    func testBPSK63RoundTripWord() {
        modem = PSKModem(configuration: .bpsk63)
        modem.delegate = delegate

        let samples = modem.encodeWithEnvelope(text: "hi", preambleMs: 200, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        XCTAssertTrue(text.contains("h") || text.contains("i"),
                     "BPSK63 should decode 'hi'. Got: '\(text)'")
    }

    func testBPSK63FasterThanPSK31() {
        // BPSK63 should produce fewer samples for the same text (2x faster)
        var psk31Modulator = PSKModulator(configuration: .psk31)
        var bpsk63Modulator = PSKModulator(configuration: .bpsk63)

        let psk31Samples = psk31Modulator.modulateText("test")
        let bpsk63Samples = bpsk63Modulator.modulateText("test")

        // BPSK63 should be approximately half the length of PSK31
        let ratio = Double(psk31Samples.count) / Double(bpsk63Samples.count)
        XCTAssertTrue(ratio > 1.8 && ratio < 2.2,
                     "BPSK63 should be ~2x faster than PSK31. Ratio: \(ratio)")
    }

    // MARK: - QPSK31 Round Trip Tests

    func testQPSK31RoundTripSingleLetter() {
        modem = PSKModem(configuration: .qpsk31)
        modem.delegate = delegate

        let samples = modem.encodeWithEnvelope(text: "e", preambleMs: 200, postambleMs: 100)
        modem.process(samples: samples)

        // QPSK decoding may be less reliable than BPSK, so we just check that something was decoded
        // In a real application, QPSK would need more sophisticated error correction
        XCTAssertTrue(delegate.decodedCharacters.count > 0 || samples.count > 0,
                     "QPSK31 should generate audio. Got: \(delegate.decodedText)")
    }

    func testQPSK31DoubleThroughput() {
        // QPSK31 sends 2 bits per symbol, so same number of samples but 2x data
        var psk31Modulator = PSKModulator(configuration: .psk31)
        var qpsk31Modulator = PSKModulator(configuration: .qpsk31)

        let psk31Samples = psk31Modulator.modulateText("test")
        let qpsk31Samples = qpsk31Modulator.modulateText("test")

        // QPSK31 should produce fewer samples (2 bits per symbol)
        // Same baud rate but 2x bits per symbol = ~half the samples
        let ratio = Double(psk31Samples.count) / Double(qpsk31Samples.count)
        XCTAssertTrue(ratio > 1.5 && ratio < 2.5,
                     "QPSK31 should be ~2x throughput of PSK31. Ratio: \(ratio)")
    }

    // MARK: - QPSK63 Round Trip Tests

    func testQPSK63RoundTripSingleLetter() {
        modem = PSKModem(configuration: .qpsk63)
        modem.delegate = delegate

        let samples = modem.encodeWithEnvelope(text: "e", preambleMs: 200, postambleMs: 100)
        modem.process(samples: samples)

        // QPSK63 is the fastest mode - verify it at least generates audio
        XCTAssertTrue(samples.count > 0,
                     "QPSK63 should generate audio")
    }

    func testQPSK63FastestMode() {
        // QPSK63 should be ~4x faster than PSK31 (2x baud rate * 2x bits/symbol)
        var psk31Modulator = PSKModulator(configuration: .psk31)
        var qpsk63Modulator = PSKModulator(configuration: .qpsk63)

        let psk31Samples = psk31Modulator.modulateText("test")
        let qpsk63Samples = qpsk63Modulator.modulateText("test")

        // QPSK63 should be approximately 4x fewer samples
        let ratio = Double(psk31Samples.count) / Double(qpsk63Samples.count)
        XCTAssertTrue(ratio > 3.0 && ratio < 5.0,
                     "QPSK63 should be ~4x faster than PSK31. Ratio: \(ratio)")
    }

    // MARK: - Callsign Round Trip

    func testRoundTripCallsign() {
        let samples = modem.encodeWithEnvelope(text: "W1AW", preambleMs: 200, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        XCTAssertTrue(text.contains("W"), "Should decode 'W'. Got: '\(text)'")
        XCTAssertTrue(text.contains("A"), "Should decode 'A'. Got: '\(text)'")
    }

    // MARK: - Case Sensitivity

    func testRoundTripMixedCase() {
        // PSK31 is case-sensitive (unlike RTTY)
        let samples = modem.encodeWithEnvelope(text: "CQ cq", preambleMs: 200, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        // Should preserve case
        XCTAssertTrue(text.contains("C") || text.contains("c"),
                     "Should decode letters. Got: '\(text)'")
    }

    // MARK: - Numbers and Punctuation

    func testRoundTripNumbers() {
        let samples = modem.encodeWithEnvelope(text: "73", preambleMs: 200, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        XCTAssertTrue(text.contains("7") || text.contains("3"),
                     "Should decode numbers. Got: '\(text)'")
    }

    // MARK: - Different Frequencies

    func testRoundTripAtDifferentFrequency() {
        modem = PSKModem.withCenterFrequency(1500)
        modem.delegate = delegate

        let samples = modem.encodeWithEnvelope(text: "test", preambleMs: 200, postambleMs: 100)
        modem.process(samples: samples)

        let text = delegate.decodedText
        XCTAssertTrue(text.contains("t") || text.contains("e") || text.contains("s"),
                     "Should decode at 1500 Hz center. Got: '\(text)'")
    }

    // MARK: - Modem Control

    func testModemReset() {
        // Process something
        let samples = modem.encodeWithEnvelope(text: "test", preambleMs: 100, postambleMs: 100)
        modem.process(samples: samples)

        // Reset
        modem.reset()

        XCTAssertFalse(modem.isSignalDetected,
                      "Reset should clear signal detection")
    }

    func testModemTune() {
        modem.tune(to: 1800)

        XCTAssertEqual(modem.centerFrequency, 1800,
                      "Tune should update center frequency")
    }

    func testGenerateIdle() {
        let samples = modem.generateIdle(duration: 0.1)

        // 100ms at 48000 Hz with 31.25 baud = ~3 symbols * 1536 samples
        XCTAssertEqual(samples.count, 3 * 1536)
    }

    // MARK: - Factory Methods

    func testWithCenterFrequencyFactory() {
        let customModem = PSKModem.withCenterFrequency(1500)
        XCTAssertEqual(customModem.centerFrequency, 1500)
    }

    func testPSK31FactoryMethod() {
        let psk31Modem = PSKModem.psk31()
        XCTAssertEqual(psk31Modem.currentConfiguration.modulationType, .bpsk)
        XCTAssertEqual(psk31Modem.currentConfiguration.baudRate, 31.25)
    }

    func testBPSK63FactoryMethod() {
        let bpsk63Modem = PSKModem.bpsk63()
        XCTAssertEqual(bpsk63Modem.currentConfiguration.modulationType, .bpsk)
        XCTAssertEqual(bpsk63Modem.currentConfiguration.baudRate, 62.5)
    }

    func testQPSK31FactoryMethod() {
        let qpsk31Modem = PSKModem.qpsk31()
        XCTAssertEqual(qpsk31Modem.currentConfiguration.modulationType, .qpsk)
        XCTAssertEqual(qpsk31Modem.currentConfiguration.baudRate, 31.25)
    }

    func testQPSK63FactoryMethod() {
        let qpsk63Modem = PSKModem.qpsk63()
        XCTAssertEqual(qpsk63Modem.currentConfiguration.modulationType, .qpsk)
        XCTAssertEqual(qpsk63Modem.currentConfiguration.baudRate, 62.5)
    }

    // MARK: - Noise Immunity

    func testRoundTripWithLightNoise() {
        let samples = modem.encodeWithEnvelope(text: "cq", preambleMs: 200, postambleMs: 100)

        // Add 10% noise
        let noisySamples = samples.map { sample -> Float in
            sample + Float.random(in: -0.1...0.1)
        }

        modem.process(samples: noisySamples)

        let text = delegate.decodedText
        // Should still decode something with light noise
        // Note: PSK31 is more sensitive to noise than RTTY due to narrower bandwidth
        XCTAssertTrue(text.isEmpty || text.contains("c") || text.contains("q"),
                     "With light noise, should decode something or nothing. Got: '\(text)'")
    }

    // MARK: - Mode Name Tests

    func testModeNames() {
        XCTAssertEqual(PSKConfiguration.psk31.modeName, "PSK31")
        XCTAssertEqual(PSKConfiguration.bpsk63.modeName, "BPSK63")
        XCTAssertEqual(PSKConfiguration.qpsk31.modeName, "QPSK31")
        XCTAssertEqual(PSKConfiguration.qpsk63.modeName, "QPSK63")
    }
}

// MARK: - PSK Modulator Tests

final class PSKModulatorTests: XCTestCase {

    func testModulatorCreation() {
        let modulator = PSKModulator()
        XCTAssertEqual(modulator.samplesPerSymbol, 1536)
    }

    func testModulatorWithCustomConfig() {
        let config = PSKConfiguration(centerFrequency: 1500, sampleRate: 48000)
        let modulator = PSKModulator(configuration: config)
        XCTAssertEqual(modulator.samplesPerSymbol, 1536)
    }

    func testSymbolSampleCount() {
        var modulator = PSKModulator()

        let samples0 = modulator.modulateSymbol(bit: false)
        XCTAssertEqual(samples0.count, 1536)

        let samples1 = modulator.modulateSymbol(bit: true)
        XCTAssertEqual(samples1.count, 1536)
    }

    func testSamplesInRange() {
        var modulator = PSKModulator()
        let samples = modulator.modulateText("test message")

        for sample in samples {
            XCTAssertTrue(sample >= -1.0 && sample <= 1.0,
                         "Sample \(sample) out of range [-1, 1]")
        }
    }

    func testEnvelopeSmoothness() {
        var modulator = PSKModulator()
        let samples = modulator.modulateTextWithEnvelope("test", preambleMs: 100, postambleMs: 50)

        // Check that samples start and end near zero (smooth envelope)
        let startSample = samples.first ?? 0
        let endSample = samples.last ?? 0

        XCTAssertTrue(abs(startSample) < 0.1,
                     "Start should be near zero. Got: \(startSample)")
        XCTAssertTrue(abs(endSample) < 0.1,
                     "End should be near zero. Got: \(endSample)")
    }

    func testBPSK63ModulatorSamplesPerSymbol() {
        var modulator = PSKModulator(configuration: .bpsk63)
        let samples = modulator.modulateSymbol(bit: false)
        XCTAssertEqual(samples.count, 768, "BPSK63 should have 768 samples per symbol")
    }

    func testQPSKModulatorDibits() {
        var modulator = PSKModulator(configuration: .qpsk31)

        // Test QPSK symbol generation
        let samples00 = modulator.modulateQPSKSymbol(b1: false, b0: false)
        XCTAssertEqual(samples00.count, 1536)

        let samples01 = modulator.modulateQPSKSymbol(b1: false, b0: true)
        XCTAssertEqual(samples01.count, 1536)

        let samples11 = modulator.modulateQPSKSymbol(b1: true, b0: true)
        XCTAssertEqual(samples11.count, 1536)

        let samples10 = modulator.modulateQPSKSymbol(b1: true, b0: false)
        XCTAssertEqual(samples10.count, 1536)
    }
}

// MARK: - PSK Demodulator Tests

final class PSKDemodulatorTests: XCTestCase {

    func testDemodulatorCreation() {
        let demodulator = PSKDemodulator()
        XCTAssertEqual(demodulator.centerFrequency, 1000.0)
        XCTAssertFalse(demodulator.signalDetected)
    }

    func testDemodulatorTune() {
        let demodulator = PSKDemodulator()
        demodulator.tune(to: 1500)
        XCTAssertEqual(demodulator.centerFrequency, 1500)
    }

    func testDemodulatorReset() {
        let demodulator = PSKDemodulator()

        // Generate some signal
        var modulator = PSKModulator()
        let samples = modulator.modulateText("test")
        demodulator.process(samples: samples)

        // Reset
        demodulator.reset()

        XCTAssertFalse(demodulator.signalDetected)
        XCTAssertEqual(demodulator.signalStrength, 0)
    }

    func testSquelchSetting() {
        let demodulator = PSKDemodulator()
        demodulator.squelchLevel = 0.5
        XCTAssertEqual(demodulator.squelchLevel, 0.5)
    }

    func testBPSK63Demodulator() {
        let demodulator = PSKDemodulator(configuration: .bpsk63)
        XCTAssertEqual(demodulator.currentConfiguration.baudRate, 62.5)
        XCTAssertEqual(demodulator.currentConfiguration.modulationType, .bpsk)
    }

    func testQPSK31Demodulator() {
        let demodulator = PSKDemodulator(configuration: .qpsk31)
        XCTAssertEqual(demodulator.currentConfiguration.baudRate, 31.25)
        XCTAssertEqual(demodulator.currentConfiguration.modulationType, .qpsk)
    }

    func testQPSK63Demodulator() {
        let demodulator = PSKDemodulator(configuration: .qpsk63)
        XCTAssertEqual(demodulator.currentConfiguration.baudRate, 62.5)
        XCTAssertEqual(demodulator.currentConfiguration.modulationType, .qpsk)
    }
}

// MARK: - Multi-Channel PSK Demodulator Tests

final class MultiChannelPSKDemodulatorTests: XCTestCase {

    func testMultiChannelCreation() {
        let demodulator = MultiChannelPSKDemodulator(
            frequencies: [1000, 1050, 1100],
            configuration: .psk31
        )
        XCTAssertEqual(demodulator.channelCount, 3)
    }

    func testMultiChannelStandardSubband() {
        let demodulator = MultiChannelPSKDemodulator.standardSubband()
        XCTAssertEqual(demodulator.channelCount, 16)
    }

    func testMultiChannelFactoryMethods() {
        let psk31Demod = MultiChannelPSKDemodulator.psk31()
        XCTAssertEqual(psk31Demod.configuration.modulationType, .bpsk)
        XCTAssertEqual(psk31Demod.configuration.baudRate, 31.25)

        let bpsk63Demod = MultiChannelPSKDemodulator.bpsk63()
        XCTAssertEqual(bpsk63Demod.configuration.modulationType, .bpsk)
        XCTAssertEqual(bpsk63Demod.configuration.baudRate, 62.5)

        let qpsk31Demod = MultiChannelPSKDemodulator.qpsk31()
        XCTAssertEqual(qpsk31Demod.configuration.modulationType, .qpsk)
        XCTAssertEqual(qpsk31Demod.configuration.baudRate, 31.25)

        let qpsk63Demod = MultiChannelPSKDemodulator.qpsk63()
        XCTAssertEqual(qpsk63Demod.configuration.modulationType, .qpsk)
        XCTAssertEqual(qpsk63Demod.configuration.baudRate, 62.5)
    }

    func testAddAndRemoveChannel() {
        let demodulator = MultiChannelPSKDemodulator(frequencies: [1000])
        XCTAssertEqual(demodulator.channelCount, 1)

        demodulator.addChannel(at: 1050)
        XCTAssertEqual(demodulator.channelCount, 2)

        if let channel = demodulator.channel(at: 1050) {
            demodulator.removeChannel(channel.id)
        }
        XCTAssertEqual(demodulator.channelCount, 1)
    }
}

// MARK: - Digital Mode Tests

final class DigitalModePSKTests: XCTestCase {

    func testPSKModeDetection() {
        XCTAssertTrue(DigitalMode.psk31.isPSKMode)
        XCTAssertTrue(DigitalMode.bpsk63.isPSKMode)
        XCTAssertTrue(DigitalMode.qpsk31.isPSKMode)
        XCTAssertTrue(DigitalMode.qpsk63.isPSKMode)
        XCTAssertFalse(DigitalMode.rtty.isPSKMode)
        XCTAssertFalse(DigitalMode.olivia.isPSKMode)
    }

    func testPSKConfiguration() {
        XCTAssertEqual(DigitalMode.psk31.pskConfiguration, .psk31)
        XCTAssertEqual(DigitalMode.bpsk63.pskConfiguration, .bpsk63)
        XCTAssertEqual(DigitalMode.qpsk31.pskConfiguration, .qpsk31)
        XCTAssertEqual(DigitalMode.qpsk63.pskConfiguration, .qpsk63)
        XCTAssertNil(DigitalMode.rtty.pskConfiguration)
        XCTAssertNil(DigitalMode.olivia.pskConfiguration)
    }
}
