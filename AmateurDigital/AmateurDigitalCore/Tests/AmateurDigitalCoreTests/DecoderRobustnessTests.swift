//
//  DecoderRobustnessTests.swift
//  AmateurDigitalCoreTests
//
//  Fuzz/robustness tests verifying decoders don't crash on edge-case inputs.
//  Tests: empty input, very short input, random noise, max amplitude,
//  all zeros, very long input, and rapid reset cycles.
//

import XCTest
@testable import AmateurDigitalCore

// MARK: - Test Delegate (captures output without assertions)

private class SilentFSKDelegate: FSKDemodulatorDelegate {
    var charCount = 0
    func demodulator(_ demodulator: FSKDemodulator, didDecode character: Character, atFrequency frequency: Double) {
        charCount += 1
    }
    func demodulator(_ demodulator: FSKDemodulator, signalDetected detected: Bool, atFrequency frequency: Double) {}
}

private class SilentPSKDelegate: PSKDemodulatorDelegate {
    var charCount = 0
    func demodulator(_ demodulator: PSKDemodulator, didDecode character: Character, atFrequency frequency: Double) {
        charCount += 1
    }
    func demodulator(_ demodulator: PSKDemodulator, signalDetected detected: Bool, atFrequency frequency: Double) {}
}

private class SilentCWDelegate: CWDemodulatorDelegate {
    var charCount = 0
    func demodulator(_ demodulator: CWDemodulator, didDecode character: Character, atFrequency frequency: Double) {
        charCount += 1
    }
    func demodulator(_ demodulator: CWDemodulator, signalDetected detected: Bool, atFrequency frequency: Double) {}
}

// MARK: - Seeded RNG

private struct FuzzRNG {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 1 : seed }

    mutating func nextFloat() -> Float {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let value = state &* 0x2545F4914F6CDD1D
        return Float(value) / Float(UInt64.max) * 2.0 - 1.0  // -1.0 to 1.0
    }
}

// MARK: - RTTY Robustness

final class RTTYRobustnessTests: XCTestCase {

    func testEmptyInput() {
        let demod = FSKDemodulator(configuration: .standard)
        let delegate = SilentFSKDelegate()
        demod.delegate = delegate
        demod.process(samples: [])
        // No crash = pass
    }

    func testVeryShortInput() {
        let demod = FSKDemodulator(configuration: .standard)
        let delegate = SilentFSKDelegate()
        demod.delegate = delegate
        demod.process(samples: [0.1, -0.1, 0.05])
        // No crash = pass
    }

    func testAllZeros() {
        let demod = FSKDemodulator(configuration: .standard)
        let delegate = SilentFSKDelegate()
        demod.delegate = delegate
        demod.process(samples: [Float](repeating: 0, count: 48000))
        // No crash = pass
    }

    func testMaxAmplitude() {
        let demod = FSKDemodulator(configuration: .standard)
        let delegate = SilentFSKDelegate()
        demod.delegate = delegate
        // Alternating +1/-1 at max amplitude
        var samples = [Float](repeating: 0, count: 48000)
        for i in 0..<samples.count { samples[i] = i % 2 == 0 ? 1.0 : -1.0 }
        demod.process(samples: samples)
    }

    func testRandomNoise() {
        let demod = FSKDemodulator(configuration: .standard)
        let delegate = SilentFSKDelegate()
        demod.delegate = delegate
        var rng = FuzzRNG(seed: 42)
        var samples = [Float](repeating: 0, count: 48000 * 2)
        for i in 0..<samples.count { samples[i] = rng.nextFloat() * 0.5 }
        demod.process(samples: samples)
    }

    func testRapidReset() {
        let demod = FSKDemodulator(configuration: .standard)
        let delegate = SilentFSKDelegate()
        demod.delegate = delegate
        var rng = FuzzRNG(seed: 99)
        for _ in 0..<20 {
            var samples = [Float](repeating: 0, count: 4800)
            for i in 0..<samples.count { samples[i] = rng.nextFloat() * 0.3 }
            demod.process(samples: samples)
            demod.reset()
        }
    }

    func testSingleSample() {
        let demod = FSKDemodulator(configuration: .standard)
        let delegate = SilentFSKDelegate()
        demod.delegate = delegate
        // Feed one sample at a time
        for _ in 0..<1000 {
            demod.process(samples: [0.1])
        }
    }
}

// MARK: - PSK Robustness

final class PSKRobustnessTests: XCTestCase {

    func testEmptyInput() {
        let demod = PSKDemodulator(configuration: .psk31)
        let delegate = SilentPSKDelegate()
        demod.delegate = delegate
        demod.process(samples: [])
    }

    func testVeryShortInput() {
        let demod = PSKDemodulator(configuration: .psk31)
        let delegate = SilentPSKDelegate()
        demod.delegate = delegate
        demod.process(samples: [0.1, -0.1, 0.05])
    }

    func testAllZeros() {
        let demod = PSKDemodulator(configuration: .psk31)
        let delegate = SilentPSKDelegate()
        demod.delegate = delegate
        demod.process(samples: [Float](repeating: 0, count: 48000))
    }

    func testMaxAmplitude() {
        let demod = PSKDemodulator(configuration: .psk31)
        let delegate = SilentPSKDelegate()
        demod.delegate = delegate
        var samples = [Float](repeating: 0, count: 48000)
        for i in 0..<samples.count { samples[i] = i % 2 == 0 ? 1.0 : -1.0 }
        demod.process(samples: samples)
    }

    func testRandomNoise() {
        let demod = PSKDemodulator(configuration: .psk31)
        let delegate = SilentPSKDelegate()
        demod.delegate = delegate
        var rng = FuzzRNG(seed: 42)
        var samples = [Float](repeating: 0, count: 48000 * 2)
        for i in 0..<samples.count { samples[i] = rng.nextFloat() * 0.5 }
        demod.process(samples: samples)
    }

    func testRapidReset() {
        let demod = PSKDemodulator(configuration: .psk31)
        let delegate = SilentPSKDelegate()
        demod.delegate = delegate
        var rng = FuzzRNG(seed: 99)
        for _ in 0..<20 {
            var samples = [Float](repeating: 0, count: 4800)
            for i in 0..<samples.count { samples[i] = rng.nextFloat() * 0.3 }
            demod.process(samples: samples)
            demod.reset()
        }
    }

    func testAllModes() {
        // Verify all PSK modes handle noise without crash
        let configs: [PSKConfiguration] = [.psk31, .bpsk63, .qpsk31, .qpsk63]
        var rng = FuzzRNG(seed: 77)
        var samples = [Float](repeating: 0, count: 48000)
        for i in 0..<samples.count { samples[i] = rng.nextFloat() * 0.3 }

        for config in configs {
            let demod = PSKDemodulator(configuration: config)
            let delegate = SilentPSKDelegate()
            demod.delegate = delegate
            demod.process(samples: samples)
        }
    }
}

// MARK: - CW Robustness

final class CWRobustnessTests: XCTestCase {

    func testEmptyInput() {
        let demod = CWDemodulator(configuration: .standard)
        let delegate = SilentCWDelegate()
        demod.delegate = delegate
        demod.process(samples: [])
    }

    func testVeryShortInput() {
        let demod = CWDemodulator(configuration: .standard)
        let delegate = SilentCWDelegate()
        demod.delegate = delegate
        demod.process(samples: [0.1, -0.1, 0.05])
    }

    func testAllZeros() {
        let demod = CWDemodulator(configuration: .standard)
        let delegate = SilentCWDelegate()
        demod.delegate = delegate
        demod.process(samples: [Float](repeating: 0, count: 48000))
    }

    func testMaxAmplitude() {
        let demod = CWDemodulator(configuration: .standard)
        let delegate = SilentCWDelegate()
        demod.delegate = delegate
        var samples = [Float](repeating: 0, count: 48000)
        for i in 0..<samples.count { samples[i] = i % 2 == 0 ? 1.0 : -1.0 }
        demod.process(samples: samples)
    }

    func testRandomNoise() {
        let demod = CWDemodulator(configuration: .standard)
        let delegate = SilentCWDelegate()
        demod.delegate = delegate
        var rng = FuzzRNG(seed: 42)
        var samples = [Float](repeating: 0, count: 48000 * 2)
        for i in 0..<samples.count { samples[i] = rng.nextFloat() * 0.5 }
        demod.process(samples: samples)
    }

    func testRapidReset() {
        let demod = CWDemodulator(configuration: .standard)
        let delegate = SilentCWDelegate()
        demod.delegate = delegate
        var rng = FuzzRNG(seed: 99)
        for _ in 0..<20 {
            var samples = [Float](repeating: 0, count: 4800)
            for i in 0..<samples.count { samples[i] = rng.nextFloat() * 0.3 }
            demod.process(samples: samples)
            demod.reset()
        }
    }

    func testAllSpeeds() {
        // Verify all WPM settings handle noise without crash
        var rng = FuzzRNG(seed: 55)
        var samples = [Float](repeating: 0, count: 48000)
        for i in 0..<samples.count { samples[i] = rng.nextFloat() * 0.3 }

        for wpm in [5.0, 13.0, 20.0, 30.0, 45.0, 60.0] {
            let config = CWConfiguration.standard.withWPM(wpm)
            let demod = CWDemodulator(configuration: config)
            let delegate = SilentCWDelegate()
            demod.delegate = delegate
            demod.process(samples: samples)
        }
    }
}
