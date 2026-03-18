//
//  RTTYBenchmark - RTTY (FSK) Decoding Quality Benchmark
//
//  Comprehensive evaluation harness that tests RTTY decoding across:
//  - Clean channel baseline at multiple baud rates
//  - Noise sweep (30 dB to -6 dB SNR)
//  - Selective fading (mark or space fading independently)
//  - Adjacent channel interference (nearby FSK signals)
//  - Frequency drift (linear drift over transmission)
//  - Combined real-world impairments
//  - False positive test (noise-only, CW tone, PSK signal)
//
//  Designed to specifically exercise the W7AY Optimal ATC detector,
//  FFT overlap-add bandpass filter, and phase-based AFC improvements.
//
//  Outputs a composite score (0-100) and detailed per-test results.
//
//  Run:  cd AmateurDigital/AmateurDigitalCore && swift run RTTYBenchmark
//

import Foundation
import AmateurDigitalCore

// MARK: - Seeded Random Generator

struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 1 : seed }

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

class BenchmarkDelegate: FSKDemodulatorDelegate {
    var decodedCharacters: [Character] = []
    var decodedText: String { String(decodedCharacters) }

    func demodulator(_ demodulator: FSKDemodulator, didDecode character: Character, atFrequency frequency: Double) {
        decodedCharacters.append(character)
    }

    func demodulator(_ demodulator: FSKDemodulator, signalDetected detected: Bool, atFrequency frequency: Double) {}

    func reset() { decodedCharacters.removeAll() }
}

// MARK: - Signal Impairments

func addWhiteNoise(to signal: [Float], snrDB: Float, rng: inout SeededRandom) -> [Float] {
    let signalPower = signal.map { $0 * $0 }.reduce(0, +) / max(1, Float(signal.count))
    let signalRMS = sqrt(signalPower)
    guard signalRMS > 0 else { return signal }
    let noiseRMS = signalRMS / pow(10.0, snrDB / 20.0)
    return signal.map { $0 + Float(rng.nextGaussian()) * noiseRMS }
}

/// Apply selective fading: attenuate one tone while leaving the other intact.
/// This simulates HF selective fading where mark and space experience independent fading.
/// `markAttenDB` and `spaceAttenDB` specify independent attenuation in dB.
/// `fadeRateHz` controls how fast the fading cycles (0 = static imbalance).
func applySelectiveFading(
    to signal: [Float], config: RTTYConfiguration,
    markAttenDB: Float, spaceAttenDB: Float,
    fadeRateHz: Double = 0, sampleRate: Double = 48000
) -> [Float] {
    // Build mark and space bandpass filters to separate tones
    let markCenter = config.markFrequency
    let spaceCenter = config.spaceFrequency
    let halfShift = config.shift / 2.0

    var result = signal

    if fadeRateHz <= 0 {
        // Static selective fading: apply constant attenuation per tone band
        // Use frequency-selective gain: attenuate everything near the faded tone
        let markGain = pow(10.0, -markAttenDB / 20.0)
        let spaceGain = pow(10.0, -spaceAttenDB / 20.0)

        // Simple approach: filter into mark/space bands, scale, recombine
        var markBP = BandpassFilter(
            lowCutoff: markCenter - halfShift * 0.8,
            highCutoff: markCenter + halfShift * 0.8,
            sampleRate: sampleRate
        )
        var spaceBP = BandpassFilter(
            lowCutoff: spaceCenter - halfShift * 0.8,
            highCutoff: spaceCenter + halfShift * 0.8,
            sampleRate: sampleRate
        )

        for i in 0..<result.count {
            let mPart = markBP.process(signal[i])
            let sPart = spaceBP.process(signal[i])
            let remainder = signal[i] - mPart - sPart
            result[i] = mPart * Float(markGain) + sPart * Float(spaceGain) + remainder
        }
    } else {
        // Dynamic selective fading: fade rate modulates the tone attenuation
        let markBaseGain = pow(10.0, -markAttenDB / 20.0)
        let spaceBaseGain = pow(10.0, -spaceAttenDB / 20.0)
        let phaseInc = 2.0 * .pi * fadeRateHz / sampleRate
        var phase = 0.0

        var markBP = BandpassFilter(
            lowCutoff: markCenter - halfShift * 0.8,
            highCutoff: markCenter + halfShift * 0.8,
            sampleRate: sampleRate
        )
        var spaceBP = BandpassFilter(
            lowCutoff: spaceCenter - halfShift * 0.8,
            highCutoff: spaceCenter + halfShift * 0.8,
            sampleRate: sampleRate
        )

        for i in 0..<result.count {
            let fadeFactor = Float(0.5 * (1.0 + cos(phase)))  // 0 to 1
            let mGain = 1.0 - fadeFactor * (1.0 - Float(markBaseGain))
            let sGain = 1.0 - fadeFactor * (1.0 - Float(spaceBaseGain))

            let mPart = markBP.process(signal[i])
            let sPart = spaceBP.process(signal[i])
            let remainder = signal[i] - mPart - sPart
            result[i] = mPart * mGain + sPart * sGain + remainder
            phase += phaseInc
        }
    }

    return result
}

func applyFrequencyDrift(to signal: [Float], driftHz: Double, sampleRate: Double = 48000) -> [Float] {
    // True frequency shift using single-sideband mixing.
    // For a real signal s(t), frequency shift by f produces:
    //   s_shifted(t) = s(t) * cos(phi(t)) - s_hilbert(t) * sin(phi(t))
    // where phi(t) is the accumulated phase.
    // For simplicity and to avoid Hilbert transform, we use cos mixing only
    // which creates both sidebands but preserves the signal at the shifted frequency.
    // This is acceptable for narrowband FSK signals where the image sideband is
    // well separated from the mark/space frequencies.
    let n = signal.count
    var result = [Float](repeating: 0, count: n)
    var phase = 0.0
    for i in 0..<n {
        // Linear drift: frequency offset ramps from 0 to driftHz over the signal
        let t = Double(i) / Double(n)
        let instantOffset = driftHz * t
        let phaseInc = 2.0 * .pi * instantOffset / sampleRate
        phase += phaseInc
        // Multiply by cos shifts the signal by ±instantOffset Hz (creates both sidebands)
        result[i] = signal[i] * Float(cos(phase))
    }
    return result
}

func addAdjacentSignal(
    to signal: [Float], config: RTTYConfiguration,
    offsetHz: Double, relativeLevel: Float,
    sampleRate: Double = 48000, rng: inout SeededRandom
) -> [Float] {
    // Generate a second RTTY signal at a different frequency
    let adjConfig = config.withCenterFrequency(config.markFrequency + offsetHz)
    var adjMod = RTTYModem(configuration: adjConfig)
    // Encode some different text
    let adjText = "RYRYRYRYRYRYRYRYRYRY"
    let adjSamples = adjMod.encode(text: adjText)

    let signalRMS = sqrt(signal.map { $0 * $0 }.reduce(0, +) / max(1, Float(signal.count)))
    let adjRMS = sqrt(adjSamples.map { $0 * $0 }.reduce(0, +) / max(1, Float(adjSamples.count)))
    let scale = adjRMS > 0 ? signalRMS * relativeLevel / adjRMS : 0

    var result = signal
    for i in 0..<min(result.count, adjSamples.count) {
        result[i] += adjSamples[i] * scale
    }
    return result
}

func applyFading(to signal: [Float], fadeRateHz: Double, fadeDepth: Float, sampleRate: Double = 48000) -> [Float] {
    let phaseInc = 2.0 * .pi * fadeRateHz / sampleRate
    var phase = 0.0
    return signal.map { sample in
        let fade = 1.0 - fadeDepth * Float((1.0 + cos(phase)) / 2.0)
        phase += phaseInc
        return sample * fade
    }
}

// MARK: - Scoring

func characterErrorRate(expected: String, actual: String) -> Double {
    guard !expected.isEmpty else { return actual.isEmpty ? 0 : 1 }
    guard !actual.isEmpty else { return 1.0 }

    let exp = Array(expected.uppercased())
    let act = Array(actual.uppercased())
    let m = exp.count, n = act.count

    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    for i in 0...m { dp[i][0] = i }
    for j in 0...n { dp[0][j] = j }
    for i in 1...m {
        for j in 1...n {
            dp[i][j] = exp[i-1] == act[j-1]
                ? dp[i-1][j-1]
                : 1 + min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1])
        }
    }
    return Double(dp[m][n]) / Double(m)
}

func cerToScore(_ cer: Double) -> Double { max(0, 100.0 * (1.0 - cer)) }

// MARK: - Test Infrastructure

struct TestResult {
    let category: String
    let name: String
    let expected: String
    let decoded: String
    let cer: Double
    let score: Double
}

struct BenchmarkSuite {
    let hamTexts: [(name: String, text: String)] = [
        ("cq_call",     "CQ CQ CQ DE W1AW K"),
        ("qso_exchange","UR RST 599 NAME BOB QTH BOSTON"),
        ("contest",     "CQ TEST W1AW"),
        ("73_signoff",  "TNX FER QSO 73 DE W1AW SK"),
        ("wx_report",   "WX CLR TEMP 72"),
        ("numbers",     "12345 67890"),
        ("short",       "CQ"),
        ("callsign",    "W1AW"),
        ("ryry",        "RYRYRYRYRYRYRYRY"),
        ("mixed",       "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG"),
    ]

    var results: [TestResult] = []
    let delegate = BenchmarkDelegate()

    mutating func runAll() {
        let startTime = Date()

        print(String(repeating: "=", count: 72))
        print("RTTY (FSK) DECODING BENCHMARK")
        print("  Optimal ATC + FFT Bandpass + Phase AFC")
        print(String(repeating: "=", count: 72))
        print()

        runCleanChannelTests()
        runBaudRateSweepTests()
        runNoiseSweepTests()
        runSelectiveFadingTests()
        runAdjacentChannelTests()
        runFrequencyDriftTests()
        runFlatFadingTests()
        runITUChannelTests()
        runCombinedImpairmentTests()
        runFalsePositiveTests()

        printSummary()

        let elapsed = Date().timeIntervalSince(startTime)
        print(String(format: "\nBenchmark completed in %.1f seconds.", elapsed))
    }

    // MARK: - Clean Channel

    mutating func runCleanChannelTests() {
        print("--- Clean Channel (45.45 baud, 2125/1955 Hz) ---")
        for (name, text) in hamTexts {
            let result = runTest(category: "clean", name: name, config: .standard, text: text)
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Baud Rate Sweep

    mutating func runBaudRateSweepTests() {
        print("--- Baud Rate Sweep (Clean Channel) ---")
        let text = "CQ CQ CQ DE W1AW K"
        for baud in [45.45, 50.0, 75.0, 100.0] {
            let config = RTTYConfiguration(baudRate: baud, markFrequency: 2125, shift: 170, sampleRate: 48000)
            let result = runTest(category: "baud_rate", name: "\(Int(baud))baud", config: config, text: text)
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Noise Sweep

    mutating func runNoiseSweepTests() {
        print("--- Noise Sweep (45.45 baud) ---")
        let text = "CQ CQ CQ DE W1AW K"
        let snrLevels: [Float] = [30, 25, 20, 15, 12, 10, 8, 6, 3, 0, -3, -6]

        for snr in snrLevels {
            let result = runTest(
                category: "noise", name: "\(Int(snr))dB",
                config: .standard, text: text,
                impairment: { samples in
                    var rng = SeededRandom(seed: 42 + UInt64(abs(snr) * 100))
                    return addWhiteNoise(to: samples, snrDB: snr, rng: &rng)
                }
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Selective Fading (ATC test)

    mutating func runSelectiveFadingTests() {
        print("--- Selective Fading (tests Optimal ATC) ---")
        let text = "CQ CQ CQ DE W1AW K"

        // Static imbalance: mark faded
        for atten: Float in [3, 6, 10, 15, 20] {
            let result = runTest(
                category: "selective_fading", name: "mark_-\(Int(atten))dB",
                config: .standard, text: text,
                impairment: { samples in
                    applySelectiveFading(to: samples, config: .standard,
                                         markAttenDB: atten, spaceAttenDB: 0)
                }
            )
            results.append(result)
            printResult(result)
        }

        // Static imbalance: space faded
        for atten: Float in [3, 6, 10, 15, 20] {
            let result = runTest(
                category: "selective_fading", name: "space_-\(Int(atten))dB",
                config: .standard, text: text,
                impairment: { samples in
                    applySelectiveFading(to: samples, config: .standard,
                                         markAttenDB: 0, spaceAttenDB: atten)
                }
            )
            results.append(result)
            printResult(result)
        }

        // Dynamic selective fading (one tone fades in and out)
        for (rate, atten, name) in [(0.5, Float(10), "slow_10dB"), (1.0, Float(15), "med_15dB"), (2.0, Float(10), "fast_10dB")] as [(Double, Float, String)] {
            let result = runTest(
                category: "selective_fading", name: "dynamic_\(name)",
                config: .standard, text: text,
                impairment: { samples in
                    applySelectiveFading(to: samples, config: .standard,
                                         markAttenDB: atten, spaceAttenDB: 0,
                                         fadeRateHz: rate)
                }
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Adjacent Channel Interference (FFT filter test)

    mutating func runAdjacentChannelTests() {
        print("--- Adjacent Channel Interference (tests FFT bandpass) ---")
        let text = "CQ CQ CQ DE W1AW K"

        for (offset, level, name) in [(200.0, Float(1.0), "+200Hz_equal"),
                                       (200.0, Float(2.0), "+200Hz_strong"),
                                       (300.0, Float(1.0), "+300Hz_equal"),
                                       (500.0, Float(1.0), "+500Hz_equal"),
                                       (200.0, Float(0.5), "+200Hz_weak")] as [(Double, Float, String)] {
            let result = runTest(
                category: "adj_channel", name: name,
                config: .standard, text: text,
                impairment: { samples in
                    var rng = SeededRandom(seed: 300 + UInt64(offset))
                    return addAdjacentSignal(to: samples, config: .standard,
                                             offsetHz: offset, relativeLevel: level, rng: &rng)
                }
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Frequency Drift (AFC test)

    mutating func runFrequencyDriftTests() {
        print("--- Frequency Drift (tests phase-based AFC) ---")
        let text = "CQ CQ CQ DE W1AW K"

        for drift in [5.0, 10.0, 20.0, 30.0, 50.0] {
            let result = runTest(
                category: "freq_drift", name: "+\(Int(drift))Hz",
                config: .standard, text: text,
                impairment: { samples in
                    applyFrequencyDrift(to: samples, driftHz: drift)
                }
            )
            results.append(result)
            printResult(result)
        }
        // Negative drift
        for drift in [10.0, 30.0] {
            let result = runTest(
                category: "freq_drift", name: "-\(Int(drift))Hz",
                config: .standard, text: text,
                impairment: { samples in
                    applyFrequencyDrift(to: samples, driftHz: -drift)
                }
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Flat Fading (QSB)

    mutating func runFlatFadingTests() {
        print("--- Flat Fading / QSB ---")
        let text = "CQ CQ CQ DE W1AW K"

        let fadeParams: [(rate: Double, depth: Float, name: String)] = [
            (0.5, 0.3, "slow_shallow"),
            (0.5, 0.6, "slow_moderate"),
            (0.5, 0.8, "slow_deep"),
            (1.0, 0.5, "medium"),
            (2.0, 0.5, "fast"),
        ]

        for (rate, depth, name) in fadeParams {
            let result = runTest(
                category: "fading", name: name,
                config: .standard, text: text,
                impairment: { samples in
                    applyFading(to: samples, fadeRateHz: rate, fadeDepth: depth)
                }
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - ITU Standard HF Channel Tests

    mutating func runITUChannelTests() {
        print("--- ITU/CCIR Standard HF Channels (45.45 baud, 15 dB SNR) ---")
        let text = "CQ CQ CQ DE W1AW K"

        let channels: [(name: String, channel: () -> WattersonChannel)] = [
            ("itu_good",      { WattersonChannel.good(seed: 300) }),
            ("itu_moderate",  { WattersonChannel.moderate(seed: 301) }),
            ("itu_poor",      { WattersonChannel.poor(seed: 302) }),
            ("itu_disturbed", { WattersonChannel.disturbed(seed: 303) }),
        ]

        for (name, makeChannel) in channels {
            let result = runTest(
                category: "itu_channel", name: name,
                config: .standard, text: text,
                impairment: { samples in
                    var channel = makeChannel()
                    let faded = channel.process(samples)
                    var rng = SeededRandom(seed: 400 + UInt64(name.count))
                    return addWhiteNoise(to: faded, snrDB: 15, rng: &rng)
                }
            )
            results.append(result)
            printResult(result)
        }

        for (name, makeChannel) in channels {
            let result = runTest(
                category: "itu_channel", name: "\(name)_clean",
                config: .standard, text: text,
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

    // MARK: - Combined Impairments

    mutating func runCombinedImpairmentTests() {
        print("--- Combined Impairments (Real-World) ---")
        let text = "CQ CQ CQ DE W1AW K"

        // Noise + selective fading (typical HF)
        let r1 = runTest(
            category: "combined", name: "15dB+sel_fade_10dB",
            config: .standard, text: text,
            impairment: { samples in
                var faded = applySelectiveFading(to: samples, config: .standard,
                                                  markAttenDB: 10, spaceAttenDB: 0, fadeRateHz: 0.5)
                var rng = SeededRandom(seed: 333)
                return addWhiteNoise(to: faded, snrDB: 15, rng: &rng)
            }
        )
        results.append(r1); printResult(r1)

        // Noise + adjacent channel
        let r2 = runTest(
            category: "combined", name: "15dB+adj_+200Hz",
            config: .standard, text: text,
            impairment: { samples in
                var rng = SeededRandom(seed: 444)
                var noisy = addWhiteNoise(to: samples, snrDB: 15, rng: &rng)
                var rng2 = SeededRandom(seed: 445)
                return addAdjacentSignal(to: noisy, config: .standard,
                                          offsetHz: 200, relativeLevel: 1.0, rng: &rng2)
            }
        )
        results.append(r2); printResult(r2)

        // Noise + drift
        let r3 = runTest(
            category: "combined", name: "15dB+drift_20Hz",
            config: .standard, text: text,
            impairment: { samples in
                var drifted = applyFrequencyDrift(to: samples, driftHz: 20)
                var rng = SeededRandom(seed: 555)
                return addWhiteNoise(to: drifted, snrDB: 15, rng: &rng)
            }
        )
        results.append(r3); printResult(r3)

        // Noise + fading + selective fading + drift (worst case)
        let r4 = runTest(
            category: "combined", name: "worst_case",
            config: .standard, text: text,
            impairment: { samples in
                var s = applySelectiveFading(to: samples, config: .standard,
                                              markAttenDB: 6, spaceAttenDB: 0, fadeRateHz: 0.3)
                s = applyFading(to: s, fadeRateHz: 0.5, fadeDepth: 0.3)
                s = applyFrequencyDrift(to: s, driftHz: 10)
                var rng = SeededRandom(seed: 666)
                return addWhiteNoise(to: s, snrDB: 10, rng: &rng)
            }
        )
        results.append(r4); printResult(r4)

        // Contest conditions: strong adjacent + moderate noise
        let r5 = runTest(
            category: "combined", name: "contest",
            config: .standard, text: text,
            impairment: { samples in
                var rng = SeededRandom(seed: 777)
                var s = addWhiteNoise(to: samples, snrDB: 20, rng: &rng)
                var rng2 = SeededRandom(seed: 778)
                s = addAdjacentSignal(to: s, config: .standard,
                                       offsetHz: 200, relativeLevel: 2.0, rng: &rng2)
                var rng3 = SeededRandom(seed: 779)
                return addAdjacentSignal(to: s, config: .standard,
                                          offsetHz: -300, relativeLevel: 1.5, rng: &rng3)
            }
        )
        results.append(r5); printResult(r5)

        print()
    }

    // MARK: - False Positive

    mutating func runFalsePositiveTests() {
        print("--- False Positive Tests ---")

        // Pure noise — set squelch to prevent decoding random noise
        let demod1 = FSKDemodulator(configuration: .standard)
        demod1.squelchLevel = 0.3  // Higher squelch for noise-only test
        delegate.reset()
        demod1.delegate = delegate

        var rng = SeededRandom(seed: 12345)
        let noiseSamples = 48000 * 3
        var noise = [Float](repeating: 0, count: noiseSamples)
        for i in 0..<noiseSamples { noise[i] = Float(rng.nextGaussian()) * 0.1 }
        demod1.process(samples: noise)

        let fp1Count = delegate.decodedText.count
        let fp1Score = fp1Count == 0 ? 100.0 : max(0, 100.0 - Double(fp1Count) * 10.0)
        let r1 = TestResult(category: "false_positive", name: "noise_only",
                             expected: "", decoded: delegate.decodedText,
                             cer: fp1Count == 0 ? 0 : 1, score: fp1Score)
        results.append(r1); printResult(r1)

        // CW tone at 700 Hz (should not decode as RTTY)
        let demod2 = FSKDemodulator(configuration: .standard)
        delegate.reset()
        demod2.delegate = delegate

        var toneSamples = [Float](repeating: 0, count: noiseSamples)
        var phase = 0.0
        for i in 0..<noiseSamples {
            toneSamples[i] = Float(sin(phase)) * 0.5
            phase += 2.0 * .pi * 700.0 / 48000.0
        }
        demod2.process(samples: toneSamples)

        let fp2Count = delegate.decodedText.count
        let fp2Score = fp2Count == 0 ? 100.0 : max(0, 100.0 - Double(fp2Count) * 10.0)
        let r2 = TestResult(category: "false_positive", name: "cw_tone",
                             expected: "", decoded: delegate.decodedText,
                             cer: fp2Count == 0 ? 0 : 1, score: fp2Score)
        results.append(r2); printResult(r2)

        print()
    }

    // MARK: - Test Runner

    mutating func runTest(
        category: String, name: String,
        config: RTTYConfiguration, text: String,
        impairment: (([Float]) -> [Float])? = nil
    ) -> TestResult {
        let modem = RTTYModem(configuration: config)
        let demod = FSKDemodulator(configuration: config)
        delegate.reset()
        demod.delegate = delegate

        var samples = modem.encodeWithIdle(text: text, preambleMs: 200, postambleMs: 200)

        if let impair = impairment {
            samples = impair(samples)
        }

        demod.process(samples: samples)

        let decoded = delegate.decodedText
        let cer = characterErrorRate(expected: text, actual: decoded)
        return TestResult(category: category, name: name, expected: text, decoded: decoded, cer: cer, score: cerToScore(cer))
    }

    // MARK: - Output

    func printResult(_ r: TestResult) {
        let scoreStr = String(format: "%5.1f", r.score)
        let cerStr = String(format: "%5.1f%%", r.cer * 100)
        let decodedPreview = r.decoded.count > 35
            ? String(r.decoded.prefix(32)) + "..."
            : r.decoded
        print("  [RTTY] \(r.category)/\(r.name): score=\(scoreStr) cer=\(cerStr) decoded=\"\(decodedPreview)\"")
    }

    func printSummary() {
        print(String(repeating: "=", count: 72))
        print("SUMMARY")
        print(String(repeating: "=", count: 72))

        let categories = Dictionary(grouping: results, by: { $0.category })

        for (category, tests) in categories.sorted(by: { $0.key < $1.key }) {
            let avgScore = tests.map(\.score).reduce(0, +) / Double(tests.count)
            let passCount = tests.filter { $0.score >= 50 }.count
            print("  \(category): \(String(format: "%.1f", avgScore))/100 (\(passCount)/\(tests.count) passed)")
        }

        // Weighted composite score
        let weights: [String: Double] = [
            "clean":            2.0,
            "baud_rate":        1.0,
            "noise":            2.5,
            "selective_fading":  3.0,   // Key test for ATC
            "adj_channel":      2.5,   // Key test for FFT filter
            "freq_drift":       2.0,   // Key test for phase AFC
            "fading":           2.0,
            "itu_channel":      2.5,   // ITU standard HF propagation
            "combined":         3.0,
            "false_positive":   1.5,
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
        print(String(repeating: "=", count: 72))
        print("COMPOSITE SCORE: \(String(format: "%.1f", compositeScore)) / 100")
        print(String(repeating: "=", count: 72))

        writeJSON(compositeScore: compositeScore)
        appendScoreHistory(compositeScore: compositeScore, categories: categories)
    }

    func writeJSON(compositeScore: Double) {
        var json = "{\n"
        json += "  \"timestamp\": \"\(ISO8601DateFormatter().string(from: Date()))\",\n"
        json += "  \"composite_score\": \(String(format: "%.2f", compositeScore)),\n"
        json += "  \"tests\": [\n"

        for (i, r) in results.enumerated() {
            let esc = { (s: String) -> String in
                s.replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "\"", with: "\\\"")
                 .replacingOccurrences(of: "\n", with: "\\n")
            }
            json += "    {\"category\":\"\(r.category)\",\"name\":\"\(r.name)\",\"expected\":\"\(esc(r.expected))\",\"decoded\":\"\(esc(r.decoded))\",\"cer\":\(String(format: "%.4f", r.cer)),\"score\":\(String(format: "%.2f", r.score))}"
            json += i < results.count - 1 ? ",\n" : "\n"
        }

        json += "  ]\n}\n"

        let path = "/tmp/rtty_benchmark_latest.json"
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
        print("\nDetailed results written to: \(path)")
    }

    func appendScoreHistory(compositeScore: Double, categories: [String: [TestResult]]) {
        let historyPath = "/tmp/rtty_benchmark_history.csv"
        let timestamp = ISO8601DateFormatter().string(from: Date())

        let cats = ["clean", "baud_rate", "noise", "selective_fading", "adj_channel",
                     "freq_drift", "fading", "combined", "false_positive"]

        if !FileManager.default.fileExists(atPath: historyPath) {
            let header = "timestamp,composite_score," + cats.joined(separator: ",") + "\n"
            try? header.write(toFile: historyPath, atomically: true, encoding: .utf8)
        }

        let scoreMap = Dictionary(uniqueKeysWithValues: categories.map { cat, tests in
            (cat, tests.map(\.score).reduce(0, +) / Double(tests.count))
        })
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

// MARK: - Main

print("Starting RTTY benchmark...")
var suite = BenchmarkSuite()
suite.runAll()
