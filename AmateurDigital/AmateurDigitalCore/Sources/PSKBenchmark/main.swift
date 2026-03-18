//
//  PSKBenchmark - PSK Decoding Quality Benchmark
//
//  Comprehensive scoring harness that tests PSK decoding across:
//  - Multiple SNR levels (clean to very noisy)
//  - Frequency offsets (simulating tuning error)
//  - Realistic ham radio text patterns
//  - All 4 PSK modes (PSK31, BPSK63, QPSK31, QPSK63)
//  - Timing jitter (simulating clock drift)
//  - Adjacent channel interference
//
//  Outputs a composite score (0-100) and detailed per-test results.
//

import Foundation
import AmateurDigitalCore

// MARK: - Seeded Random Generator

struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed == 0 ? 1 : seed
    }

    mutating func nextDouble() -> Double {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let value = state &* 0x2545F4914F6CDD1D
        return Double(value) / Double(UInt64.max)
    }

    mutating func nextGaussian() -> Double {
        let u1 = max(nextDouble(), 1e-10)
        let u2 = nextDouble()
        return sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
    }
}

// MARK: - Test Delegate

class BenchmarkDelegate: PSKDemodulatorDelegate {
    var decodedCharacters: [Character] = []

    var decodedText: String { String(decodedCharacters) }

    func demodulator(_ demodulator: PSKDemodulator, didDecode character: Character, atFrequency frequency: Double) {
        decodedCharacters.append(character)
    }

    func demodulator(_ demodulator: PSKDemodulator, signalDetected detected: Bool, atFrequency frequency: Double) {}

    func reset() { decodedCharacters.removeAll() }
}

// MARK: - Signal Impairments

func addWhiteNoise(to signal: [Float], snrDB: Float, rng: inout SeededRandom) -> [Float] {
    let signalPower = signal.map { $0 * $0 }.reduce(0, +) / Float(signal.count)
    let signalRMS = sqrt(signalPower)
    let noiseRMS = signalRMS / pow(10.0, snrDB / 20.0)

    return signal.map { sample in
        let noise = Float(rng.nextGaussian()) * noiseRMS
        return sample + noise
    }
}

func applyFrequencyOffset(to signal: [Float], offsetHz: Double, sampleRate: Double) -> [Float] {
    let phaseIncrement = 2.0 * .pi * offsetHz / sampleRate
    var phase = 0.0
    return signal.map { sample in
        let shifted = sample * Float(cos(phase))
        phase += phaseIncrement
        if phase >= 2.0 * .pi { phase -= 2.0 * .pi }
        return shifted
    }
}

func applyTimingJitter(to signal: [Float], jitterSamples: Int, rng: inout SeededRandom) -> [Float] {
    guard jitterSamples > 0, signal.count > jitterSamples * 2 else { return signal }
    var result = signal
    // Randomly insert or remove samples to simulate clock drift
    let stride = signal.count / max(1, jitterSamples)
    for i in Swift.stride(from: stride, to: signal.count - 1, by: stride) {
        if rng.nextDouble() > 0.5 {
            // Duplicate a sample (clock slow)
            result.insert(result[min(i, result.count - 1)], at: min(i, result.count))
        } else if result.count > signal.count / 2 {
            // Remove a sample (clock fast)
            result.remove(at: min(i, result.count - 1))
        }
    }
    return result
}


func applyFading(to signal: [Float], fadeRateHz: Double, fadeDepth: Float, sampleRate: Double) -> [Float] {
    let phaseIncrement = 2.0 * .pi * fadeRateHz / sampleRate
    var phase = 0.0
    return signal.map { sample in
        // Sinusoidal fade: amplitude varies between (1-depth) and 1.0
        let fade = 1.0 - fadeDepth * Float((1.0 + cos(phase)) / 2.0)
        phase += phaseIncrement
        return sample * fade
    }
}

func addAdjacentChannelInterference(to signal: [Float], interferenceFreqOffset: Double,
                                     centerFreq: Double, sampleRate: Double,
                                     sirDB: Float, rng: inout SeededRandom) -> [Float] {
    // Generate an interfering PSK signal at an adjacent frequency
    let intConfig = PSKConfiguration(modulationType: .bpsk, baudRate: 31.25,
                                      centerFrequency: centerFreq + interferenceFreqOffset,
                                      sampleRate: sampleRate)
    var intModulator = PSKModulator(configuration: intConfig)
    let intText = "CQ CQ CQ DE K1ABC K1ABC K"
    var intSamples = intModulator.modulateTextWithEnvelope(intText, preambleMs: 100, postambleMs: 50)

    // Scale interference to desired SIR (signal-to-interference ratio)
    let sigPower = signal.map { $0 * $0 }.reduce(0, +) / Float(signal.count)
    let sigRMS = sqrt(sigPower)
    let intPower = intSamples.map { $0 * $0 }.reduce(0, +) / Float(intSamples.count)
    let intRMS = sqrt(intPower)
    let targetIntRMS = sigRMS / pow(10.0, sirDB / 20.0)
    let scale = intRMS > 0 ? targetIntRMS / intRMS : 0

    // Pad or truncate interference to match signal length
    while intSamples.count < signal.count {
        intSamples.append(contentsOf: intSamples)
    }

    return zip(signal, intSamples.prefix(signal.count)).map { s, i in
        s + i * scale
    }
}

// MARK: - Scoring

func characterErrorRate(expected: String, actual: String) -> Double {
    guard !expected.isEmpty else { return actual.isEmpty ? 0 : 1 }
    guard !actual.isEmpty else { return 1.0 }  // Nothing decoded = 100% error

    let exp = Array(expected)
    let act = Array(actual)

    // Levenshtein distance for accurate CER
    let m = exp.count
    let n = act.count
    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

    for i in 0...m { dp[i][0] = i }
    for j in 0...n { dp[0][j] = j }

    for i in 1...m {
        for j in 1...n {
            if exp[i - 1] == act[j - 1] {
                dp[i][j] = dp[i - 1][j - 1]
            } else {
                dp[i][j] = 1 + min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
            }
        }
    }

    return Double(dp[m][n]) / Double(m)
}

func cerToScore(_ cer: Double) -> Double {
    // 0% CER = 100 points, 100% CER = 0 points, exponential curve
    return max(0, 100.0 * (1.0 - cer))
}

// MARK: - Test Cases

struct TestResult {
    let category: String
    let name: String
    let mode: String
    let expected: String
    let decoded: String
    let cer: Double
    let score: Double
}

struct BenchmarkSuite {
    let hamTexts: [(name: String, text: String)] = [
        ("cq_short", "CQ CQ CQ DE W1AW K"),
        ("qso_exchange", "UR RST 599 599 NAME IS BOB QTH BOSTON MA"),
        ("contest", "CQ TEST W1AW"),
        ("73_signoff", "TNX FER QSO 73 DE W1AW SK"),
        ("wx_report", "WX HR CLR TEMP 72F WIND NW 10"),
        ("mixed_case", "CQ cq de W1AW w1aw"),
        ("numbers", "12345 67890"),
        ("punctuation", "HELLO, WORLD. HOW ARE YOU?"),
        ("short", "CQ"),
        ("single_char", "e"),
    ]

    var results: [TestResult] = []
    let delegate = BenchmarkDelegate()

    mutating func runAll() {
        print(repeatStr("=", 70))
        print("PSK DECODING BENCHMARK")
        print(repeatStr("=", 70))
        print()

        runCleanChannelTests()
        runNoiseSweepTests()
        runFrequencyOffsetTests()
        runNoiseAndOffsetComboTests()
        runTimingJitterTests()
        runAdjacentChannelTests()
        runAllModesCleanTests()
        runBPSK63StressTests()
        runFadingChannelTests()
        runITUChannelTests()
        runLongMessageTests()
        runNoiseOnlyFalsePositiveTest()

        printSummary()
    }

    // MARK: - Clean Channel (Baseline)

    mutating func runCleanChannelTests() {
        print("--- Clean Channel (Baseline) ---")
        for (name, text) in hamTexts {
            let result = runSingleTest(
                category: "clean", name: name, mode: "PSK31",
                config: .psk31, text: text
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Noise Sweep

    mutating func runNoiseSweepTests() {
        print("--- Noise Sweep (PSK31) ---")
        let snrLevels: [Float] = [25, 20, 15, 12, 10, 8, 6, 3, 0]
        let text = "CQ CQ CQ DE W1AW K"

        for snr in snrLevels {
            let result = runSingleTest(
                category: "noise", name: "snr_\(Int(snr))dB", mode: "PSK31",
                config: .psk31, text: text,
                impairment: { samples in
                    var rng = SeededRandom(seed: 42 + UInt64(snr))
                    return addWhiteNoise(to: samples, snrDB: snr, rng: &rng)
                }
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Frequency Offset

    mutating func runFrequencyOffsetTests() {
        print("--- Frequency Offset (PSK31) ---")
        let offsets: [Double] = [1, 2, 5, 10, 15, 20, 30, 50]
        let text = "CQ CQ CQ DE W1AW K"

        for offset in offsets {
            let result = runFreqOffsetTest(
                category: "freq_offset", name: "+\(Int(offset))Hz", mode: "PSK31",
                baseConfig: .psk31, text: text, offsetHz: offset
            )
            results.append(result)
            printResult(result)
        }

        // Negative offsets
        for offset in [5.0, 10.0, 20.0] {
            let result = runFreqOffsetTest(
                category: "freq_offset", name: "-\(Int(offset))Hz", mode: "PSK31",
                baseConfig: .psk31, text: text, offsetHz: -offset
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Noise + Frequency Offset Combo

    mutating func runNoiseAndOffsetComboTests() {
        print("--- Noise + Frequency Offset Combo (PSK31) ---")
        let combos: [(snr: Float, offset: Double)] = [
            (20, 5),   // Moderate noise + small offset
            (15, 5),   // More noise + small offset
            (20, 10),  // Moderate noise + medium offset
            (15, 10),  // More noise + medium offset
            (10, 5),   // Heavy noise + small offset
        ]
        let text = "CQ CQ CQ DE W1AW K"

        for (snr, offset) in combos {
            let txConfig = PSKConfiguration.psk31.withCenterFrequency(1000 + offset)
            var modulator = PSKModulator(configuration: txConfig)
            var samples = modulator.modulateTextWithEnvelope(text, preambleMs: 200, postambleMs: 100)
            var rng = SeededRandom(seed: 55 + UInt64(snr) + UInt64(offset))
            samples = addWhiteNoise(to: samples, snrDB: snr, rng: &rng)

            let demodulator = PSKDemodulator(configuration: .psk31)
            delegate.reset()
            demodulator.delegate = delegate
            demodulator.squelchLevel = 0.1
            demodulator.process(samples: samples)

            let decoded = delegate.decodedText
            let cer = characterErrorRate(expected: text, actual: decoded)
            let score = cerToScore(cer)
            let result = TestResult(
                category: "noise_offset", name: "\(Int(snr))dB_+\(Int(offset))Hz",
                mode: "PSK31", expected: text, decoded: decoded, cer: cer, score: score
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Timing Jitter

    mutating func runTimingJitterTests() {
        print("--- Timing Jitter (PSK31) ---")
        let jitterLevels = [1, 2, 5, 10, 20]
        let text = "CQ CQ CQ DE W1AW K"

        for jitter in jitterLevels {
            let result = runSingleTest(
                category: "timing_jitter", name: "\(jitter)_samples", mode: "PSK31",
                config: .psk31, text: text,
                impairment: { samples in
                    var rng = SeededRandom(seed: 99 + UInt64(jitter))
                    return applyTimingJitter(to: samples, jitterSamples: jitter, rng: &rng)
                }
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Adjacent Channel Interference

    mutating func runAdjacentChannelTests() {
        print("--- Adjacent Channel Interference (PSK31) ---")
        let sirLevels: [(offset: Double, sir: Float)] = [
            (100, 10),  // 100 Hz away, 10 dB SIR
            (75, 10),   // 75 Hz away, 10 dB SIR
            (50, 10),   // 50 Hz away, 10 dB SIR
            (50, 6),    // 50 Hz away, 6 dB SIR
            (50, 3),    // 50 Hz away, 3 dB SIR
        ]
        let text = "CQ CQ CQ DE W1AW K"

        for (offset, sir) in sirLevels {
            let result = runSingleTest(
                category: "adj_channel", name: "\(Int(offset))Hz_\(Int(sir))dB_SIR", mode: "PSK31",
                config: .psk31, text: text,
                impairment: { samples in
                    var rng = SeededRandom(seed: 77)
                    return addAdjacentChannelInterference(
                        to: samples, interferenceFreqOffset: offset,
                        centerFreq: 1000, sampleRate: 48000,
                        sirDB: sir, rng: &rng
                    )
                }
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - All Modes Comprehensive

    mutating func runAllModesCleanTests() {
        let text = "CQ CQ DE W1AW K"
        let modes: [(name: String, config: PSKConfiguration)] = [
            ("PSK31", .psk31),
            ("BPSK63", .bpsk63),
            ("QPSK31", .qpsk31),
            ("QPSK63", .qpsk63),
        ]

        // Clean channel
        print("--- All Modes (Clean Channel) ---")
        for (modeName, config) in modes {
            let result = runSingleTest(
                category: "all_modes", name: "clean", mode: modeName,
                config: config, text: text
            )
            results.append(result)
            printResult(result)
        }
        print()

        // Moderate noise
        print("--- All Modes (15 dB SNR) ---")
        for (modeName, config) in modes {
            let result = runSingleTest(
                category: "all_modes_noisy", name: "15dB_SNR", mode: modeName,
                config: config, text: text,
                impairment: { samples in
                    var rng = SeededRandom(seed: 42)
                    return addWhiteNoise(to: samples, snrDB: 15, rng: &rng)
                }
            )
            results.append(result)
            printResult(result)
        }
        print()

        // Frequency offset per mode — tests AFC across all modes
        print("--- All Modes (+5 Hz Offset) ---")
        for (modeName, config) in modes {
            let result = runFreqOffsetTest(
                category: "all_modes_offset", name: "+5Hz", mode: modeName,
                baseConfig: config, text: text, offsetHz: 5
            )
            results.append(result)
            printResult(result)
        }
        print()

        // Fading per mode
        print("--- All Modes (Fading) ---")
        for (modeName, config) in modes {
            let result = runSingleTest(
                category: "all_modes_fading", name: "slow_deep", mode: modeName,
                config: config, text: text,
                impairment: { samples in
                    applyFading(to: samples, fadeRateHz: 0.5, fadeDepth: 0.8, sampleRate: 48000)
                }
            )
            results.append(result)
            printResult(result)
        }
        print()

        // Heavy noise per mode — tests decoder limits
        print("--- All Modes (6 dB SNR) ---")
        for (modeName, config) in modes {
            let result = runSingleTest(
                category: "all_modes_heavy_noise", name: "6dB_SNR", mode: modeName,
                config: config, text: text,
                impairment: { samples in
                    var rng = SeededRandom(seed: 99)
                    return addWhiteNoise(to: samples, snrDB: 6, rng: &rng)
                }
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - BPSK63 Stress Tests

    mutating func runBPSK63StressTests() {
        print("--- BPSK63 Stress Tests ---")
        let text = "CQ CQ CQ DE W1AW K"

        // BPSK63 noise sweep
        for snr: Float in [15, 10, 6, 3] {
            let result = runSingleTest(
                category: "bpsk63_stress", name: "noise_\(Int(snr))dB", mode: "BPSK63",
                config: .bpsk63, text: text,
                impairment: { samples in
                    var rng = SeededRandom(seed: 42 + UInt64(snr))
                    return addWhiteNoise(to: samples, snrDB: snr, rng: &rng)
                }
            )
            results.append(result)
            printResult(result)
        }

        // BPSK63 frequency offsets
        for offset in [5.0, 10.0, 20.0] {
            let result = runFreqOffsetTest(
                category: "bpsk63_stress", name: "+\(Int(offset))Hz", mode: "BPSK63",
                baseConfig: .bpsk63, text: text, offsetHz: offset
            )
            results.append(result)
            printResult(result)
        }

        // BPSK63 noise + offset combo
        let txConfig = PSKConfiguration.bpsk63.withCenterFrequency(1010)
        var modulator = PSKModulator(configuration: txConfig)
        var samples = modulator.modulateTextWithEnvelope(text, preambleMs: 200, postambleMs: 100)
        var rng = SeededRandom(seed: 88)
        samples = addWhiteNoise(to: samples, snrDB: 12, rng: &rng)

        let demodulator = PSKDemodulator(configuration: .bpsk63)
        delegate.reset()
        demodulator.delegate = delegate
        demodulator.squelchLevel = 0.1
        demodulator.process(samples: samples)

        let decoded = delegate.decodedText
        let cer = characterErrorRate(expected: text, actual: decoded)
        let score = cerToScore(cer)
        let result = TestResult(
            category: "bpsk63_stress", name: "12dB_+10Hz", mode: "BPSK63",
            expected: text, decoded: decoded, cer: cer, score: score
        )
        results.append(result)
        printResult(result)
        print()
    }

    // MARK: - Fading Channel Tests

    mutating func runFadingChannelTests() {
        print("--- Fading Channel (PSK31) ---")
        let text = "CQ CQ CQ DE W1AW K"

        // Slow fading: signal level varies sinusoidally (simulates HF propagation)
        let fadeRates: [(rate: Double, depth: Float, name: String)] = [
            (0.5, 0.5, "slow_shallow"),   // 0.5 Hz fade, 50% depth
            (1.0, 0.5, "medium_shallow"), // 1 Hz fade, 50% depth
            (0.5, 0.8, "slow_deep"),      // 0.5 Hz fade, 80% depth
            (2.0, 0.5, "fast_shallow"),   // 2 Hz fade, 50% depth
            (1.0, 0.8, "medium_deep"),    // 1 Hz fade, 80% depth
        ]

        for (rate, depth, name) in fadeRates {
            let result = runSingleTest(
                category: "fading", name: name, mode: "PSK31",
                config: .psk31, text: text,
                impairment: { samples in
                    applyFading(to: samples, fadeRateHz: rate, fadeDepth: depth, sampleRate: 48000)
                }
            )
            results.append(result)
            printResult(result)
        }

        // Fading + noise combo
        let result = runSingleTest(
            category: "fading", name: "medium_shallow_15dB", mode: "PSK31",
            config: .psk31, text: text,
            impairment: { samples in
                var faded = applyFading(to: samples, fadeRateHz: 1.0, fadeDepth: 0.5, sampleRate: 48000)
                var rng = SeededRandom(seed: 33)
                faded = addWhiteNoise(to: faded, snrDB: 15, rng: &rng)
                return faded
            }
        )
        results.append(result)
        printResult(result)
        print()
    }

    // MARK: - ITU Standard HF Channel Tests

    mutating func runITUChannelTests() {
        print("--- ITU/CCIR Standard HF Channels (PSK31, 15 dB SNR) ---")
        let text = "CQ CQ CQ DE W1AW K"

        let channels: [(name: String, channel: () -> WattersonChannel)] = [
            ("itu_good",      { WattersonChannel.good(seed: 200) }),
            ("itu_moderate",  { WattersonChannel.moderate(seed: 201) }),
            ("itu_poor",      { WattersonChannel.poor(seed: 202) }),
            ("itu_disturbed", { WattersonChannel.disturbed(seed: 203) }),
        ]

        for (name, makeChannel) in channels {
            // With noise
            let result = runSingleTest(
                category: "itu_channel", name: name, mode: "PSK31",
                config: .psk31, text: text,
                impairment: { samples in
                    var channel = makeChannel()
                    let faded = channel.process(samples)
                    var rng = SeededRandom(seed: 300 + UInt64(name.count))
                    return addWhiteNoise(to: faded, snrDB: 15, rng: &rng)
                }
            )
            results.append(result)
            printResult(result)
        }

        // Clean (no noise) to isolate multipath effect
        for (name, makeChannel) in channels {
            let result = runSingleTest(
                category: "itu_channel", name: "\(name)_clean", mode: "PSK31",
                config: .psk31, text: text,
                impairment: { samples in
                    var channel = makeChannel()
                    return channel.process(samples)
                }
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Long Message Tests

    mutating func runLongMessageTests() {
        print("--- Long Message Tests ---")

        // Long QSO exchange — tests sustained decoding
        let longText = "CQ CQ CQ DE W1AW W1AW W1AW PSE K " +
            "W1AW DE K1ABC K1ABC UR RST 599 599 QTH BOSTON MA NAME BOB HW CPY K " +
            "K1ABC DE W1AW FB BOB UR RST 589 QTH NEWINGTON CT 73 SK"

        // Clean channel long message
        let result1 = runSingleTest(
            category: "long_msg", name: "clean_long", mode: "PSK31",
            config: .psk31, text: longText
        )
        results.append(result1)
        printResult(result1)

        // Long message with moderate noise
        let result2 = runSingleTest(
            category: "long_msg", name: "15dB_long", mode: "PSK31",
            config: .psk31, text: longText,
            impairment: { samples in
                var rng = SeededRandom(seed: 777)
                return addWhiteNoise(to: samples, snrDB: 15, rng: &rng)
            }
        )
        results.append(result2)
        printResult(result2)

        // Long message with 5 Hz offset
        let result3 = runFreqOffsetTest(
            category: "long_msg", name: "+5Hz_long", mode: "PSK31",
            baseConfig: .psk31, text: longText, offsetHz: 5
        )
        results.append(result3)
        printResult(result3)

        // Long message with fading + noise
        let result4 = runSingleTest(
            category: "long_msg", name: "fading_noise_long", mode: "PSK31",
            config: .psk31, text: longText,
            impairment: { samples in
                var faded = applyFading(to: samples, fadeRateHz: 0.5, fadeDepth: 0.5, sampleRate: 48000)
                var rng = SeededRandom(seed: 888)
                return addWhiteNoise(to: faded, snrDB: 15, rng: &rng)
            }
        )
        results.append(result4)
        printResult(result4)

        // BPSK63 long message
        let bpskResult = runSingleTest(
            category: "long_msg", name: "bpsk63_long", mode: "BPSK63",
            config: .bpsk63, text: longText
        )
        results.append(bpskResult)
        printResult(bpskResult)
        print()
    }

    // MARK: - Noise-Only False Positive Test

    mutating func runNoiseOnlyFalsePositiveTest() {
        print("--- Noise-Only False Positive Test ---")

        // Feed pure noise (no signal) to the demodulator
        // A good decoder should output NOTHING
        let demodulator = PSKDemodulator(configuration: .psk31)
        delegate.reset()
        demodulator.delegate = delegate
        demodulator.squelchLevel = 0.3  // Default squelch

        // Generate 2 seconds of pure white noise at typical microphone level
        var rng = SeededRandom(seed: 12345)
        let noiseLength = 48000 * 2  // 2 seconds
        var noise = [Float](repeating: 0, count: noiseLength)
        for i in 0..<noiseLength {
            noise[i] = Float(rng.nextGaussian()) * 0.1  // Typical mic noise level
        }

        demodulator.process(samples: noise)

        let decoded = delegate.decodedText
        // Perfect score = 0 characters decoded from pure noise
        let falsePositiveCount = decoded.count
        let score = falsePositiveCount == 0 ? 100.0 : max(0.0, 100.0 - Double(falsePositiveCount) * 10.0)
        let result = TestResult(
            category: "false_positive", name: "noise_only_0.3squelch",
            mode: "PSK31", expected: "", decoded: decoded,
            cer: decoded.isEmpty ? 0 : 1, score: score
        )
        results.append(result)
        printResult(result)

        // Test with lower squelch (0.1) — should still reject most noise
        let demodulator2 = PSKDemodulator(configuration: .psk31)
        delegate.reset()
        demodulator2.delegate = delegate
        demodulator2.squelchLevel = 0.1

        rng = SeededRandom(seed: 54321)
        for i in 0..<noiseLength {
            noise[i] = Float(rng.nextGaussian()) * 0.1
        }

        demodulator2.process(samples: noise)

        let decoded2 = delegate.decodedText
        let fp2 = decoded2.count
        let score2 = fp2 == 0 ? 100.0 : max(0.0, 100.0 - Double(fp2) * 5.0)
        let result2 = TestResult(
            category: "false_positive", name: "noise_only_0.1squelch",
            mode: "PSK31", expected: "", decoded: decoded2,
            cer: decoded2.isEmpty ? 0 : 1, score: score2
        )
        results.append(result2)
        printResult(result2)
        print()
    }

    // MARK: - Frequency Offset Test Runner

    mutating func runFreqOffsetTest(
        category: String, name: String, mode: String,
        baseConfig: PSKConfiguration, text: String, offsetHz: Double
    ) -> TestResult {
        // Modulate at offset frequency (signal is at baseFreq + offset)
        let txConfig = baseConfig.withCenterFrequency(baseConfig.centerFrequency + offsetHz)
        var modulator = PSKModulator(configuration: txConfig)
        let samples = modulator.modulateTextWithEnvelope(text, preambleMs: 200, postambleMs: 100)

        // Demodulate at nominal frequency (simulates mistuned radio)
        let demodulator = PSKDemodulator(configuration: baseConfig)
        delegate.reset()
        demodulator.delegate = delegate
        demodulator.squelchLevel = 0.1

        demodulator.process(samples: samples)

        let decoded = delegate.decodedText
        let cer = characterErrorRate(expected: text, actual: decoded)
        let score = cerToScore(cer)

        return TestResult(
            category: category, name: name, mode: mode,
            expected: text, decoded: decoded,
            cer: cer, score: score
        )
    }

    // MARK: - Test Runner

    mutating func runSingleTest(
        category: String, name: String, mode: String,
        config: PSKConfiguration, text: String,
        impairment: (([Float]) -> [Float])? = nil
    ) -> TestResult {
        var modulator = PSKModulator(configuration: config)
        let demodulator = PSKDemodulator(configuration: config)
        delegate.reset()
        demodulator.delegate = delegate
        demodulator.squelchLevel = 0.1  // Lower squelch for benchmark

        // Generate signal with envelope
        var samples = modulator.modulateTextWithEnvelope(text, preambleMs: 200, postambleMs: 100)

        // Apply impairment if any
        if let impair = impairment {
            samples = impair(samples)
        }

        // Decode
        demodulator.process(samples: samples)

        let decoded = delegate.decodedText
        let cer = characterErrorRate(expected: text, actual: decoded)
        let score = cerToScore(cer)

        return TestResult(
            category: category, name: name, mode: mode,
            expected: text, decoded: decoded,
            cer: cer, score: score
        )
    }

    // MARK: - Output

    func printResult(_ r: TestResult) {
        let scoreStr = String(format: "%5.1f", r.score)
        let cerStr = String(format: "%5.1f%%", r.cer * 100)
        let decodedPreview = r.decoded.count > 40
            ? String(r.decoded.prefix(37)) + "..."
            : r.decoded
        print("  [\(r.mode)] \(r.category)/\(r.name): score=\(scoreStr) cer=\(cerStr) decoded=\"\(decodedPreview)\"")
    }

    func printSummary() {
        print(repeatStr("=", 70))
        print("SUMMARY")
        print(repeatStr("=", 70))

        // Category scores
        let categories = Dictionary(grouping: results, by: { $0.category })
        var categoryScores: [(String, Double)] = []

        for (category, tests) in categories.sorted(by: { $0.key < $1.key }) {
            let avgScore = tests.map(\.score).reduce(0, +) / Double(tests.count)
            categoryScores.append((category, avgScore))
            print("  \(category): \(String(format: "%.1f", avgScore))/100 (\(tests.count) tests)")
        }

        // Mode scores
        print()
        print("Per-mode scores:")
        let byMode = Dictionary(grouping: results, by: { $0.mode })
        for (mode, tests) in byMode.sorted(by: { $0.key < $1.key }) {
            let avgScore = tests.map(\.score).reduce(0, +) / Double(tests.count)
            print("  \(mode): \(String(format: "%.1f", avgScore))/100 (\(tests.count) tests)")
        }

        // Composite score (weighted)
        let weights: [String: Double] = [
            "clean": 1.0,           // Baseline correctness
            "noise": 2.0,           // Noise immunity is critical
            "freq_offset": 1.5,     // Frequency tolerance important
            "noise_offset": 2.0,    // Real-world: noise + offset together
            "timing_jitter": 1.0,   // Timing recovery
            "adj_channel": 1.5,     // Selectivity
            "all_modes": 1.0,       // Mode coverage
            "all_modes_noisy": 1.5, // Mode robustness
            "all_modes_offset": 1.5, // Mode AFC coverage
            "all_modes_fading": 1.5, // Mode fading resilience
            "all_modes_heavy_noise": 1.5, // Mode noise floor
            "bpsk63_stress": 1.5,   // BPSK63 under stress
            "fading": 2.0,          // HF fading is critical for real-world
            "itu_channel": 2.5,     // ITU standard HF propagation
            "long_msg": 1.5,        // Sustained decode reliability
            "false_positive": 2.0,  // Must not decode noise as signal
        ]

        var weightedSum = 0.0
        var totalWeight = 0.0
        for (category, tests) in categories {
            let w = weights[category] ?? 1.0
            let avgScore = tests.map(\.score).reduce(0, +) / Double(tests.count)
            weightedSum += avgScore * w
            totalWeight += w
        }

        let compositeScore = totalWeight > 0 ? weightedSum / totalWeight : 0
        print()
        print(repeatStr("=", 70))
        print("COMPOSITE SCORE: \(String(format: "%.1f", compositeScore)) / 100")
        print(repeatStr("=", 70))

        // Write JSON results
        writeJSON(compositeScore: compositeScore)

        // Append to scores history
        appendScoreHistory(compositeScore: compositeScore, categoryScores: categoryScores)
    }

    func writeJSON(compositeScore: Double) {
        var json = "{\n"
        json += "  \"timestamp\": \"\(ISO8601DateFormatter().string(from: Date()))\",\n"
        json += "  \"composite_score\": \(String(format: "%.2f", compositeScore)),\n"
        json += "  \"tests\": [\n"

        for (i, r) in results.enumerated() {
            let escaped_decoded = r.decoded
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
            let escaped_expected = r.expected
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            json += "    {"
            json += "\"category\": \"\(r.category)\", "
            json += "\"name\": \"\(r.name)\", "
            json += "\"mode\": \"\(r.mode)\", "
            json += "\"expected\": \"\(escaped_expected)\", "
            json += "\"decoded\": \"\(escaped_decoded)\", "
            json += "\"cer\": \(String(format: "%.4f", r.cer)), "
            json += "\"score\": \(String(format: "%.2f", r.score))"
            json += "}\(i < results.count - 1 ? "," : "")\n"
        }

        json += "  ]\n"
        json += "}\n"

        let path = "/tmp/psk_benchmark_latest.json"
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
        print("\nDetailed results written to: \(path)")
    }

    func appendScoreHistory(compositeScore: Double, categoryScores: [(String, Double)]) {
        let historyPath = "/tmp/psk_benchmark_history.csv"
        let timestamp = ISO8601DateFormatter().string(from: Date())

        // Create header if file doesn't exist
        if !FileManager.default.fileExists(atPath: historyPath) {
            let header = "timestamp,composite_score,clean,noise,freq_offset,timing_jitter,adj_channel,all_modes,all_modes_noisy\n"
            try? header.write(toFile: historyPath, atomically: true, encoding: .utf8)
        }

        let scoreMap = Dictionary(uniqueKeysWithValues: categoryScores)
        let cats = ["clean", "noise", "freq_offset", "timing_jitter", "adj_channel", "all_modes", "all_modes_noisy"]
        let values = cats.map { String(format: "%.2f", scoreMap[$0] ?? 0) }.joined(separator: ",")
        let line = "\(timestamp),\(String(format: "%.2f", compositeScore)),\(values)\n"

        if let handle = FileHandle(forWritingAtPath: historyPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        }

        print("Score history appended to: \(historyPath)")
    }
}

// MARK: - String repeat helper

func repeatStr(_ s: String, _ count: Int) -> String {
    String(repeating: s, count: count)
}

// MARK: - Main

print("Starting benchmark...")
var suite = BenchmarkSuite()
print("Suite created")
suite.runAll()
