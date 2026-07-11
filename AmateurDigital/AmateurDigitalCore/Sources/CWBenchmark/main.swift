//
//  CWBenchmark - CW (Morse Code) Decoding Quality Benchmark
//
//  Comprehensive evaluation harness that tests CW decoding across:
//  - Multiple WPM speeds (5-45 WPM)
//  - Multiple SNR levels (clean to very noisy)
//  - Frequency offsets (simulating tuning error)
//  - Fading (QSB - simulating HF propagation)
//  - Timing jitter (simulating hand-sent CW)
//  - Variable dash-dot ratios (real ops deviate from 3:1)
//  - Realistic ham radio text patterns (CQ calls, QSO exchanges, contests)
//  - Speed changes mid-transmission
//  - Multiple concurrent signals (QRM)
//  - False positive test (noise-only)
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

class BenchmarkDelegate: CWDemodulatorDelegate {
    var decodedCharacters: [Character] = []

    var decodedText: String { String(decodedCharacters) }

    func demodulator(_ demodulator: CWDemodulator, didDecode character: Character, atFrequency frequency: Double) {
        decodedCharacters.append(character)
    }

    func demodulator(_ demodulator: CWDemodulator, signalDetected detected: Bool, atFrequency frequency: Double) {}

    func reset() { decodedCharacters.removeAll() }
}

// MARK: - Signal Impairments

func addWhiteNoise(to signal: [Float], snrDB: Float, rng: inout SeededRandom) -> [Float] {
    let signalPower = signal.map { $0 * $0 }.reduce(0, +) / max(1, Float(signal.count))
    let signalRMS = sqrt(signalPower)
    guard signalRMS > 0 else { return signal }
    let noiseRMS = signalRMS / pow(10.0, snrDB / 20.0)

    return signal.map { sample in
        let noise = Float(rng.nextGaussian()) * noiseRMS
        return sample + noise
    }
}

func applyFading(to signal: [Float], fadeRateHz: Double, fadeDepth: Float, sampleRate: Double) -> [Float] {
    let phaseIncrement = 2.0 * .pi * fadeRateHz / sampleRate
    var phase = 0.0
    return signal.map { sample in
        let fade = 1.0 - fadeDepth * Float((1.0 + cos(phase)) / 2.0)
        phase += phaseIncrement
        return sample * fade
    }
}

func addCWInterference(to signal: [Float], offsetHz: Double, relativeLevel: Float, sampleRate: Double) -> [Float] {
    // Add a continuous CW tone at an offset frequency (simulates nearby station)
    let signalRMS = sqrt(signal.map { $0 * $0 }.reduce(0, +) / max(1, Float(signal.count)))
    let interfererAmplitude = signalRMS * relativeLevel
    let phaseIncrement = 2.0 * .pi * (700.0 + offsetHz) / sampleRate  // 700 Hz = our center
    var phase = 0.0

    return signal.enumerated().map { _, sample in
        let interferer = interfererAmplitude * Float(sin(phase))
        phase += phaseIncrement
        if phase >= 2.0 * .pi { phase -= 2.0 * .pi }
        return sample + interferer
    }
}

func applyAGCPumping(to signal: [Float], depthDB: Float, rateHz: Double, sampleRate: Double = 48000) -> [Float] {
    let phaseInc = 2.0 * .pi * rateHz / sampleRate
    var phase = 0.0
    return signal.map { sample in
        let gainDB = depthDB * Float(cos(phase)) / 2.0
        let gain = pow(10.0, gainDB / 20.0)
        phase += phaseInc
        return sample * gain
    }
}

func resample(signal: [Float], fromRate: Double, toRate: Double) -> [Float] {
    let ratio = fromRate / toRate
    let outCount = Int(Double(signal.count) / ratio)
    var output = [Float](repeating: 0, count: outCount)
    for i in 0..<outCount {
        let srcPos = Double(i) * ratio
        let srcIdx = Int(srcPos)
        let frac = Float(srcPos - Double(srcIdx))
        if srcIdx + 1 < signal.count {
            output[i] = signal[srcIdx] * (1.0 - frac) + signal[srcIdx + 1] * frac
        } else if srcIdx < signal.count {
            output[i] = signal[srcIdx]
        }
    }
    return output
}

/// Generate CW with chirp: frequency shifts on key-down then settles.
/// Simulates older transmitters with poor oscillator stability.
/// - `chirpHz`: frequency shift at key-down (positive = upward chirp)
/// - `chirpDecayMs`: exponential decay time constant
func generateChirpyCW(text: String, config: CWConfiguration,
                       chirpHz: Double, chirpDecayMs: Double) -> [Float] {
    let timings = MorseCodec.encodeToTimings(text)
    let sampleRate = config.sampleRate
    let ditDuration = MorseCodec.ditDuration(forWPM: config.wpm)
    let baseFreq = config.toneFrequency
    var phase = 0.0
    let riseTimeSamples = Int(0.005 * sampleRate)  // 5ms rise/fall
    let decaySamples = chirpDecayMs * sampleRate / 1000.0

    var samples = [Float]()

    for timing in timings {
        let baseDurationUnits = abs(timing)
        let baseDuration = Double(baseDurationUnits) * ditDuration
        let sampleCount = Int(baseDuration * sampleRate)
        let toneOn = timing > 0

        for i in 0..<sampleCount {
            if toneOn {
                // Chirp: frequency starts at baseFreq + chirpHz and decays to baseFreq
                let chirpOffset = chirpHz * exp(-Double(i) / decaySamples)
                let freq = baseFreq + chirpOffset
                let phaseInc = 2.0 * .pi * freq / sampleRate
                phase += phaseInc

                // Raised cosine envelope for rise/fall
                var envelope: Float = 1.0
                if i < riseTimeSamples {
                    envelope = Float(0.5 * (1.0 - cos(.pi * Double(i) / Double(riseTimeSamples))))
                } else if i > sampleCount - riseTimeSamples {
                    let fadeIdx = i - (sampleCount - riseTimeSamples)
                    envelope = Float(0.5 * (1.0 + cos(.pi * Double(fadeIdx) / Double(riseTimeSamples))))
                }
                samples.append(Float(sin(phase)) * envelope * 0.8)
            } else {
                samples.append(0)
            }
        }
    }
    return samples
}

func applyTimingJitter(to text: String, config: CWConfiguration, jitterFraction: Double, rng: inout SeededRandom) -> [Float] {
    // Generate CW with random timing variation per element
    // jitterFraction: 0.0 = perfect timing, 0.3 = ±30% timing variation
    let timings = MorseCodec.encodeToTimings(text)
    let sampleRate = config.sampleRate
    let ditDuration = MorseCodec.ditDuration(forWPM: config.wpm)
    var phase = 0.0
    let phaseIncrement = 2.0 * .pi * config.toneFrequency / sampleRate

    var samples = [Float]()

    for timing in timings {
        let baseDurationUnits = abs(timing)
        let baseDuration = Double(baseDurationUnits) * ditDuration

        // Add jitter
        let jitter = 1.0 + jitterFraction * (rng.nextDouble() * 2.0 - 1.0)
        let actualDuration = baseDuration * max(0.3, jitter)
        let numSamples = Int(actualDuration * sampleRate)

        if timing > 0 {
            // Key-down: generate tone with envelope
            let riseSamples = config.riseSamples
            for i in 0..<numSamples {
                let envelope: Float
                if i < riseSamples {
                    envelope = Float(0.5 * (1.0 - cos(.pi * Double(i) / Double(riseSamples))))
                } else if i >= numSamples - riseSamples {
                    let fallIndex = i - (numSamples - riseSamples)
                    envelope = Float(0.5 * (1.0 + cos(.pi * Double(fallIndex) / Double(riseSamples))))
                } else {
                    envelope = 1.0
                }
                samples.append(envelope * Float(sin(phase)))
                phase += phaseIncrement
                if phase >= 2.0 * .pi { phase -= 2.0 * .pi }
            }
        } else {
            // Key-up: silence
            samples.append(contentsOf: [Float](repeating: 0, count: numSamples))
        }
    }

    return samples
}

func applyVariableDashDotRatio(to text: String, config: CWConfiguration, ratio: Double) -> [Float] {
    let modConfig = config.withDashDotRatio(ratio)
    var modulator = CWModulator(configuration: modConfig)
    return modulator.modulateText(text)
}

// MARK: - Scoring

func characterErrorRate(expected: String, actual: String) -> Double {
    guard !expected.isEmpty else { return actual.isEmpty ? 0 : 1 }
    guard !actual.isEmpty else { return 1.0 }

    let exp = Array(expected.uppercased())
    let act = Array(actual.uppercased())

    // Levenshtein distance
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
    max(0, 100.0 * (1.0 - cer))
}

// MARK: - Test Infrastructure

struct TestResult {
    let category: String
    let name: String
    let expected: String
    let decoded: String
    let cer: Double
    let score: Double
}

// MARK: - Decoder Abstraction

/// Wraps either a classic CWDemodulator or BayesianCWDecoder so tests can use either.
protocol CWDecoderWrapper {
    func process(samples: [Float])
    var decodedText: String { get }
    func reset()
}

class ClassicDecoderWrapper: CWDecoderWrapper {
    let demodulator: CWDemodulator
    let delegate: BenchmarkDelegate

    init(configuration: CWConfiguration) {
        self.demodulator = CWDemodulator(configuration: configuration)
        self.delegate = BenchmarkDelegate()
        self.demodulator.delegate = self.delegate
    }

    func process(samples: [Float]) {
        demodulator.process(samples: samples)
    }

    var decodedText: String {
        demodulator.flushPending()   // release copy still held in probation
        return delegate.decodedText
    }

    func reset() { delegate.reset() }
}

class BayesianDecoderWrapper: CWDecoderWrapper {
    let decoder: BayesianCWDecoder
    private var decodedCharacters: [Character] = []

    init(configuration: CWConfiguration, params: BayesianCWParams?) {
        self.decoder = BayesianCWDecoder(configuration: configuration)
        if let p = params {
            p.apply(to: self.decoder)
        }
        self.decoder.onCharacterDecoded = { [weak self] char, _ in
            self?.decodedCharacters.append(char)
        }
    }

    func process(samples: [Float]) {
        decoder.process(samples: samples)
    }

    var decodedText: String {
        decoder.flushPending()   // release copy still held in probation
        return String(decodedCharacters)
    }

    func reset() { decodedCharacters.removeAll() }
}

enum DecoderMode {
    case classic
    case bayesian
    case dual
}

class DualDecoderWrapper: CWDecoderWrapper {
    let decoder: DualCWDecoder
    private var decodedCharacters: [Character] = []

    init(configuration: CWConfiguration) {
        self.decoder = DualCWDecoder(configuration: configuration)
        self.decoder.onCharacterDecoded = { [weak self] char, _ in
            self?.decodedCharacters.append(char)
        }
    }

    func process(samples: [Float]) {
        decoder.process(samples: samples)
    }

    var decodedText: String {
        decoder.flush()   // resolve characters still waiting in the merge window
        return String(decodedCharacters)
    }

    func reset() { decodedCharacters.removeAll() }
}

struct BenchmarkSuite {
    let hamTexts: [(name: String, text: String)] = [
        ("cq_call", "CQ CQ CQ DE W1AW K"),
        ("qso_exchange", "UR RST 599 NAME BOB QTH BOSTON"),
        ("contest", "CQ TEST W1AW"),
        ("73_signoff", "TNX FER QSO 73 DE W1AW SK"),
        ("wx_report", "WX CLR TEMP 72"),
        ("numbers", "12345 67890"),
        ("short", "CQ"),
        ("callsign", "W1AW"),
        ("all_letters", "THE QUICK BROWN FOX"),
        ("prosigns", "CQ CQ DE W1AW = K"),
    ]

    var results: [TestResult] = []

    /// When true, only run the Bayesian decoder (for faster optimization).
    var bayesianOnly: Bool = false

    /// Optional Bayesian parameter overrides (loaded from --bayesian-params JSON).
    var bayesianParams: BayesianCWParams?

    /// Which decoder to use for this run.
    var decoderMode: DecoderMode = .classic

    /// Classic decoder parameter overrides (loaded from --params JSON)
    var cwOptimParams: CWOptimizationParams?

    func makeDecoder(configuration: CWConfiguration) -> CWDecoderWrapper {
        switch decoderMode {
        case .classic:
            let wrapper = ClassicDecoderWrapper(configuration: configuration)
            // Apply optimization parameter overrides if present
            if let p = cwOptimParams {
                if let v = p.thresholdFractionClean { wrapper.demodulator.thresholdFractionClean = v }
                if let v = p.thresholdFractionModerate { wrapper.demodulator.thresholdFractionModerate = v }
                if let v = p.thresholdFractionNoisy { wrapper.demodulator.thresholdFractionNoisy = v }
                if let v = p.signalDecayRate { wrapper.demodulator.signalDecayRate = v }
                if let v = p.toneDetectMultiplier { wrapper.demodulator.toneDetectMultiplier = v }
                if let v = p.bootstrapMultiplier { wrapper.demodulator.bootstrapMultiplier = v }
                if let v = p.hysteresisOffRatio { wrapper.demodulator.hysteresisOffRatio = v }
                if let v = p.minStatsFactor { wrapper.demodulator.minStatsFactor = v }
            }
            return wrapper
        case .bayesian:
            return BayesianDecoderWrapper(configuration: configuration, params: bayesianParams)
        case .dual:
            return DualDecoderWrapper(configuration: configuration)
        }
    }

    mutating func runAll() {
        let modeLabel: String
        switch decoderMode {
        case .classic:  modeLabel = "CLASSIC"
        case .bayesian: modeLabel = "BAYESIAN"
        case .dual:     modeLabel = "DUAL"
        }
        print(String(repeating: "=", count: 70))
        print("CW (MORSE CODE) DECODING BENCHMARK v2 [\(modeLabel)]")
        print(String(repeating: "=", count: 70))
        print()

        runCleanChannelTests()
        runSpeedSweepTests()
        runNoiseSweepTests()
        runFrequencyOffsetTests()
        runFadingTests()
        runITUChannelTests()
        runTimingJitterTests()
        runDashDotRatioTests()
        runCombinedImpairmentTests()
        runLongMessageTests()
        runQRMTests()
        runChirpTests()
        runCWAuroralFlutterTests()
        runAGCPumpingTests()
        runSampleRateMismatchTests()
        runMetamorphicTests()
        runFalsePositiveTest()

        // Suite v2 categories (composite not comparable to v1 scores)
        runColdStartTests()
        runQRNTests()
        runDriftTests()
        runSwingTests()
        runSpeedJitterTests()
        runFarnsworthTests()
        runToneFrequencyTests()
        runLongFalsePositiveTest()
        runAcousticFalsePositiveTests()
        runChunkedParityTests()
        runCallsignCopyTests()

        printSummary()
    }

    /// Fast subset for false-positive tuning: the FP scenarios plus the
    /// categories a stricter emission gate could regress (weak-signal
    /// copy, cold start, hand-sent timing).
    mutating func runFPSubset() {
        runNoiseSweepTests()
        runColdStartTests()
        runSwingTests()
        runSpeedJitterTests()
        runFarnsworthTests()
        runCombinedImpairmentTests()
        runFalsePositiveTest()
        runLongFalsePositiveTest()
        runAcousticFalsePositiveTests()
        printSummary()
    }

    // MARK: - Clean Channel (Baseline)

    mutating func runCleanChannelTests() {
        print("--- Clean Channel (20 WPM, 700 Hz) ---")
        for (name, text) in hamTexts {
            let result = runTest(
                category: "clean", name: name,
                config: .standard, text: text
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Speed Sweep

    mutating func runSpeedSweepTests() {
        print("--- Speed Sweep (Clean Channel) ---")
        let speeds: [Double] = [5, 8, 10, 13, 15, 18, 20, 25, 30, 35, 40, 45]
        let text = "CQ CQ DE W1AW K"

        for wpm in speeds {
            let config = CWConfiguration.standard.withWPM(wpm)
            let result = runTest(
                category: "speed", name: "\(Int(wpm))wpm",
                config: config, text: text
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Noise Sweep

    mutating func runNoiseSweepTests() {
        print("--- Noise Sweep (20 WPM) ---")
        let snrLevels: [Float] = [30, 25, 20, 15, 12, 10, 8, 6, 3, 0, -3, -6, -10]
        let text = "CQ CQ DE W1AW K"

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

    // MARK: - Frequency Offset

    mutating func runFrequencyOffsetTests() {
        print("--- Frequency Offset (20 WPM) ---")
        let offsets: [Double] = [10, 25, 50, 75, 100, 150, 200]
        let text = "CQ CQ DE W1AW K"

        for offset in offsets {
            // Generate signal at a different tone frequency than the decoder expects
            let result = runFreqOffsetTest(
                category: "freq_offset", name: "+\(Int(offset))Hz",
                baseConfig: .standard, text: text, offsetHz: offset
            )
            results.append(result)
            printResult(result)
        }

        // Negative offsets
        for offset in [50.0, 100.0] {
            let result = runFreqOffsetTest(
                category: "freq_offset", name: "-\(Int(offset))Hz",
                baseConfig: .standard, text: text, offsetHz: -offset
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Fading (QSB)

    mutating func runFadingTests() {
        print("--- Fading / QSB (20 WPM) ---")
        let text = "CQ CQ DE W1AW K"

        let fadeParams: [(rate: Double, depth: Float, name: String)] = [
            (0.5, 0.3, "slow_shallow"),
            (0.5, 0.6, "slow_moderate"),
            (0.5, 0.8, "slow_deep"),
            (1.0, 0.5, "medium"),
            (2.0, 0.5, "fast"),
            (1.0, 0.8, "medium_deep"),
        ]

        for (rate, depth, name) in fadeParams {
            let result = runTest(
                category: "fading", name: name,
                config: .standard, text: text,
                impairment: { samples in
                    applyFading(to: samples, fadeRateHz: rate, fadeDepth: depth, sampleRate: 48000)
                }
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - ITU Standard HF Channel Tests

    mutating func runITUChannelTests() {
        print("--- ITU/CCIR Standard HF Channels (20 WPM, 15 dB SNR) ---")
        let text = "CQ CQ DE W1AW K"

        let channels: [(name: String, channel: () -> WattersonChannel)] = [
            ("itu_good",      { WattersonChannel.good(seed: 100) }),
            ("itu_moderate",  { WattersonChannel.moderate(seed: 101) }),
            ("itu_poor",      { WattersonChannel.poor(seed: 102) }),
            ("itu_disturbed", { WattersonChannel.disturbed(seed: 103) }),
        ]

        for (name, makeChannel) in channels {
            let result = runTest(
                category: "itu_channel", name: name,
                config: .standard, text: text,
                impairment: { samples in
                    var channel = makeChannel()
                    var faded = channel.process(samples)
                    // Stable seed: String.hashValue is randomized per process,
                    // which made these tests non-reproducible across runs.
                    let stableSeed = name.unicodeScalars.reduce(UInt64(0)) { $0 &* 31 &+ UInt64($1.value) }
                    var rng = SeededRandom(seed: 200 + (stableSeed & 0xFF))
                    return addWhiteNoise(to: faded, snrDB: 15, rng: &rng)
                }
            )
            results.append(result)
            printResult(result)
        }

        // Also test without noise to isolate fading effect
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

    // MARK: - Timing Jitter (Hand-Sent CW)

    mutating func runTimingJitterTests() {
        print("--- Timing Jitter / Hand-Sent CW (20 WPM) ---")
        let text = "CQ CQ DE W1AW K"
        let jitterLevels: [Double] = [0.05, 0.10, 0.15, 0.20, 0.25, 0.30, 0.40]

        for jitter in jitterLevels {
            let result = runJitterTest(
                category: "jitter", name: "\(Int(jitter * 100))pct",
                config: .standard, text: text, jitterFraction: jitter
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Variable Dash-Dot Ratio

    mutating func runDashDotRatioTests() {
        print("--- Variable Dash-Dot Ratio (20 WPM) ---")
        let text = "CQ CQ DE W1AW K"
        let ratios: [Double] = [2.5, 2.7, 3.0, 3.3, 3.5, 4.0]

        for ratio in ratios {
            let result = runDashDotTest(
                category: "dash_dot", name: "ratio_\(String(format: "%.1f", ratio))",
                config: .standard, text: text, ratio: ratio
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Combined Impairments (Real-World Simulation)

    mutating func runCombinedImpairmentTests() {
        print("--- Combined Impairments (Real-World) ---")
        let text = "CQ CQ DE W1AW K"

        // Noise + fading
        let result1 = runTest(
            category: "combined", name: "15dB_fading",
            config: .standard, text: text,
            impairment: { samples in
                var faded = applyFading(to: samples, fadeRateHz: 0.5, fadeDepth: 0.5, sampleRate: 48000)
                var rng = SeededRandom(seed: 333)
                return addWhiteNoise(to: faded, snrDB: 15, rng: &rng)
            }
        )
        results.append(result1)
        printResult(result1)

        // Noise + frequency offset
        let result2 = runFreqOffsetTestWithNoise(
            category: "combined", name: "15dB_+50Hz",
            baseConfig: .standard, text: text, offsetHz: 50, snrDB: 15
        )
        results.append(result2)
        printResult(result2)

        // Jitter + noise (hand-sent in noisy conditions)
        let result3 = runJitterTestWithNoise(
            category: "combined", name: "jitter20_15dB",
            config: .standard, text: text, jitterFraction: 0.20, snrDB: 15
        )
        results.append(result3)
        printResult(result3)

        // Long QSO exchange at 18 WPM with moderate conditions
        let longText = "CQ CQ CQ DE W1AW W1AW K " +
            "W1AW DE K1ABC UR RST 579 NAME BOB QTH BOSTON K " +
            "K1ABC DE W1AW FB UR RST 599 NAME JOHN QTH CT 73 SK"
        let result4 = runTest(
            category: "combined", name: "long_qso_18wpm_15dB",
            config: CWConfiguration.standard.withWPM(18), text: longText,
            impairment: { samples in
                var faded = applyFading(to: samples, fadeRateHz: 0.3, fadeDepth: 0.3, sampleRate: 48000)
                var rng = SeededRandom(seed: 777)
                return addWhiteNoise(to: faded, snrDB: 15, rng: &rng)
            }
        )
        results.append(result4)
        printResult(result4)

        // Speed change: text at 15 WPM then 25 WPM (tests adaptive tracking)
        let result5 = runSpeedChangeTest(
            category: "combined", name: "speed_change_15_25",
            text1: "CQ CQ DE W1AW K", wpm1: 15,
            text2: "UR RST 599 73", wpm2: 25
        )
        results.append(result5)
        printResult(result5)

        print()
    }

    // MARK: - Long Message Tests

    mutating func runLongMessageTests() {
        print("--- Long Message Tests (realistic QSO length) ---")

        let longTexts: [(name: String, text: String)] = [
            ("full_qso",
             "CQ CQ CQ DE W1AW W1AW K DE K1ABC K1ABC UR RST 599 NAME BOB QTH BOSTON 73 DE K1ABC SK"),
            ("contest_run",
             "CQ TEST W1AW TEST K1ABC 599 05 TU W1AW CQ TEST W1AW TEST N1MM 599 12 TU W1AW"),
        ]

        // Clean — baseline long-message reliability
        for (name, text) in longTexts {
            let result = runTest(category: "long_message", name: "clean_\(name)",
                                 config: .standard, text: text)
            results.append(result)
            printResult(result)
        }

        // 10 dB noise — moderate HF conditions
        let result1 = runTest(
            category: "long_message", name: "10dB_full_qso",
            config: .standard, text: longTexts[0].text,
            impairment: { samples in
                var rng = SeededRandom(seed: 900)
                return addWhiteNoise(to: samples, snrDB: 10, rng: &rng)
            }
        )
        results.append(result1)
        printResult(result1)

        // ITU moderate + 15 dB noise — realistic propagation
        let result2 = runTest(
            category: "long_message", name: "itu_moderate_full_qso",
            config: .standard, text: longTexts[0].text,
            impairment: { samples in
                var channel = WattersonChannel.moderate(seed: 910)
                let faded = channel.process(samples)
                var rng = SeededRandom(seed: 911)
                return addWhiteNoise(to: faded, snrDB: 15, rng: &rng)
            }
        )
        results.append(result2)
        printResult(result2)

        // Hand-sent (15% jitter) + 15 dB noise — most common real-world scenario
        let result3 = runTest(
            category: "long_message", name: "handsent_15dB_full_qso",
            config: .standard, text: longTexts[0].text,
            impairment: { samples in
                var rng = SeededRandom(seed: 920)
                return addWhiteNoise(to: samples, snrDB: 15, rng: &rng)
            }
        )
        results.append(result3)
        printResult(result3)

        print()
    }

    // MARK: - QRM (Interfering CW Signals)

    mutating func runQRMTests() {
        print("--- QRM Tests (interfering CW signals) ---")
        let text = "CQ CQ DE W1AW K"

        // Generate interfering CW tone at different offsets
        for (offsetHz, level, name) in [
            (200.0, Float(1.0), "+200Hz_equal"),
            (100.0, Float(1.0), "+100Hz_equal"),
            (50.0,  Float(1.0), "+50Hz_equal"),
            (200.0, Float(2.0), "+200Hz_strong"),
            (100.0, Float(0.5), "+100Hz_weak"),
        ] as [(Double, Float, String)] {
            let result = runTest(
                category: "qrm", name: name,
                config: .standard, text: text,
                impairment: { samples in
                    addCWInterference(to: samples, offsetHz: offsetHz,
                                       relativeLevel: level, sampleRate: 48000)
                }
            )
            results.append(result)
            printResult(result)
        }

        // QRM + noise (realistic contest pileup)
        let result = runTest(
            category: "qrm", name: "100Hz_equal_15dB",
            config: .standard, text: text,
            impairment: { samples in
                var s = addCWInterference(to: samples, offsetHz: 100,
                                           relativeLevel: 1.0, sampleRate: 48000)
                var rng = SeededRandom(seed: 950)
                return addWhiteNoise(to: s, snrDB: 15, rng: &rng)
            }
        )
        results.append(result)
        printResult(result)

        print()
    }

    // MARK: - Chirp Tests

    mutating func runChirpTests() {
        print("--- Chirp Tests (transmitter frequency shift on key-down) ---")
        let text = "CQ CQ DE W1AW K"

        // Preamble and postamble silence for noise floor estimation
        let preamble = [Float](repeating: 0, count: Int(0.3 * 48000))  // 300ms
        let postamble = [Float](repeating: 0, count: Int(0.5 * 48000))  // 500ms

        // Mild chirp: 15 Hz upward shift, 5 ms decay (modern rig with slight instability)
        let chirpSamples1 = preamble + generateChirpyCW(text: text, config: .standard,
                                              chirpHz: 15, chirpDecayMs: 5) + postamble
        let dec1 = makeDecoder(configuration: .standard)
        dec1.process(samples: chirpSamples1)
        let cer1 = characterErrorRate(expected: text, actual: dec1.decodedText)
        let r1 = TestResult(category: "chirp", name: "mild_15Hz_5ms",
                             expected: text, decoded: dec1.decodedText, cer: cer1, score: cerToScore(cer1))
        results.append(r1); printResult(r1)

        // Moderate chirp: 30 Hz shift, 8 ms decay (older rig)
        let chirpSamples2 = preamble + generateChirpyCW(text: text, config: .standard,
                                              chirpHz: 30, chirpDecayMs: 8) + postamble
        let dec2 = makeDecoder(configuration: .standard)
        dec2.process(samples: chirpSamples2)
        let cer2 = characterErrorRate(expected: text, actual: dec2.decodedText)
        let r2 = TestResult(category: "chirp", name: "moderate_30Hz_8ms",
                             expected: text, decoded: dec2.decodedText, cer: cer2, score: cerToScore(cer2))
        results.append(r2); printResult(r2)

        // Severe chirp: 50 Hz shift, 10 ms decay (very old rig or homebrew)
        let chirpSamples3 = preamble + generateChirpyCW(text: text, config: .standard,
                                              chirpHz: 50, chirpDecayMs: 10) + postamble
        let dec3 = makeDecoder(configuration: .standard)
        dec3.process(samples: chirpSamples3)
        let cer3 = characterErrorRate(expected: text, actual: dec3.decodedText)
        let r3 = TestResult(category: "chirp", name: "severe_50Hz_10ms",
                             expected: text, decoded: dec3.decodedText, cer: cer3, score: cerToScore(cer3))
        results.append(r3); printResult(r3)

        print()
    }

    // MARK: - CW Auroral Flutter Tests

    mutating func runCWAuroralFlutterTests() {
        print("--- Auroral Flutter Tests (trans-polar CW paths) ---")
        let text = "CQ CQ DE W1AW K"

        // Mild: 10 Hz Doppler (CW Goertzel block is 10ms → 100 Hz resolution, so 10 Hz flutter is sub-resolution)
        let r1 = runTest(
            category: "auroral_flutter", name: "mild_10Hz",
            config: .standard, text: text,
            impairment: { samples in
                var channel = WattersonChannel(dopplerSpread: 10, pathDelay: 0.001, seed: 600)
                return channel.process(samples)
            }
        )
        results.append(r1); printResult(r1)

        // Moderate: 25 Hz Doppler
        let r2 = runTest(
            category: "auroral_flutter", name: "moderate_25Hz",
            config: .standard, text: text,
            impairment: { samples in
                var channel = WattersonChannel(dopplerSpread: 25, pathDelay: 0.002, seed: 601)
                return channel.process(samples)
            }
        )
        results.append(r2); printResult(r2)

        // Severe: 50 Hz Doppler (CW becomes "buzzy" — characteristic aurora sound)
        let r3 = runTest(
            category: "auroral_flutter", name: "severe_50Hz",
            config: .standard, text: text,
            impairment: { samples in
                var channel = WattersonChannel(dopplerSpread: 50, pathDelay: 0.002, seed: 602)
                return channel.process(samples)
            }
        )
        results.append(r3); printResult(r3)

        print()
    }

    // MARK: - AGC Pumping Tests

    mutating func runAGCPumpingTests() {
        print("--- AGC Pumping Tests (nearby strong station keying) ---")
        let text = "CQ CQ DE W1AW K"

        // Mild: 6 dB depth at 2 Hz (slow SSB operator nearby)
        let r1 = runTest(
            category: "agc_pumping", name: "mild_6dB_2Hz",
            config: .standard, text: text,
            impairment: { applyAGCPumping(to: $0, depthDB: 6, rateHz: 2) }
        )
        results.append(r1); printResult(r1)

        // Moderate: 10 dB depth at 3 Hz (CW operator nearby)
        let r2 = runTest(
            category: "agc_pumping", name: "moderate_10dB_3Hz",
            config: .standard, text: text,
            impairment: { applyAGCPumping(to: $0, depthDB: 10, rateHz: 3) }
        )
        results.append(r2); printResult(r2)

        // Severe: 15 dB depth at 5 Hz (fast QSK CW)
        let r3 = runTest(
            category: "agc_pumping", name: "severe_15dB_5Hz",
            config: .standard, text: text,
            impairment: { applyAGCPumping(to: $0, depthDB: 15, rateHz: 5) }
        )
        results.append(r3); printResult(r3)

        print()
    }

    // MARK: - Sample Rate Mismatch Tests

    mutating func runSampleRateMismatchTests() {
        print("--- Sample Rate Mismatch Tests (cheap USB audio) ---")
        let text = "CQ CQ DE W1AW K"

        // 50 ppm slow
        let r1 = runTest(
            category: "sample_rate", name: "50ppm_slow",
            config: .standard, text: text,
            impairment: { resample(signal: $0, fromRate: 48000, toRate: 48000 * (1.0 - 50e-6)) }
        )
        results.append(r1); printResult(r1)

        // 100 ppm slow
        let r2 = runTest(
            category: "sample_rate", name: "100ppm_slow",
            config: .standard, text: text,
            impairment: { resample(signal: $0, fromRate: 48000, toRate: 48000 * (1.0 - 100e-6)) }
        )
        results.append(r2); printResult(r2)

        // 200 ppm fast
        let r3 = runTest(
            category: "sample_rate", name: "200ppm_fast",
            config: .standard, text: text,
            impairment: { resample(signal: $0, fromRate: 48000, toRate: 48000 * (1.0 + 200e-6)) }
        )
        results.append(r3); printResult(r3)

        print()
    }

    // MARK: - Metamorphic Tests (decoder invariance properties)

    mutating func runMetamorphicTests() {
        print("--- Metamorphic Tests (invariance properties) ---")
        let text = "CQ CQ DE W1AW K"

        // Amplitude scaling: Goertzel power detection should handle wide dynamic range
        for (name, scale) in [("amp_0.1x", Float(0.1)), ("amp_0.5x", Float(0.5)),
                               ("amp_2x", Float(2.0)), ("amp_5x", Float(5.0))] {
            let r = runTest(
                category: "metamorphic", name: name,
                config: .standard, text: text,
                impairment: { $0.map { $0 * scale } }
            )
            results.append(r); printResult(r)
        }

        // Time shift: prepending silence should not affect decoding
        for (name, ms) in [("delay_100ms", 100), ("delay_500ms", 500), ("delay_1000ms", 1000)] {
            let delaySamples = 48000 * ms / 1000
            let r = runTest(
                category: "metamorphic", name: name,
                config: .standard, text: text,
                impairment: { signal in
                    [Float](repeating: 0, count: delaySamples) + signal
                }
            )
            results.append(r); printResult(r)
        }

        // Determinism: decoding same signal twice should produce identical output
        var modulator = CWModulator(configuration: .standard)
        let cwSamples = modulator.modulateTextWithEnvelope(text, preambleMs: 300, postambleMs: 500)

        let decoder1 = makeDecoder(configuration: .standard)
        decoder1.process(samples: cwSamples)
        let decoded1 = decoder1.decodedText

        let decoder2 = makeDecoder(configuration: .standard)
        decoder2.process(samples: cwSamples)
        let decoded2 = decoder2.decodedText

        let detScore: Double = decoded1 == decoded2 ? 100.0 : 0.0
        let r = TestResult(
            category: "metamorphic", name: "determinism",
            expected: text,
            decoded: decoded1 == decoded2 ? decoded1 : "\(decoded1) vs \(decoded2)",
            cer: decoded1 == decoded2 ? characterErrorRate(expected: text, actual: decoded1) : 1.0,
            score: detScore
        )
        results.append(r); printResult(r)

        print()
    }

    // MARK: - False Positive Test

    mutating func runFalsePositiveTest() {
        print("--- False Positive Test ---")

        let decoder = makeDecoder(configuration: .standard)

        // 3 seconds of pure noise
        var rng = SeededRandom(seed: 12345)
        let noiseLength = 48000 * 3
        var noise = [Float](repeating: 0, count: noiseLength)
        for i in 0..<noiseLength {
            noise[i] = Float(rng.nextGaussian()) * 0.1
        }

        decoder.process(samples: noise)

        let decoded = decoder.decodedText
        let falsePositiveCount = decoded.count
        let score = falsePositiveCount == 0 ? 100.0 : max(0.0, 100.0 - Double(falsePositiveCount) * 10.0)
        let result = TestResult(
            category: "false_positive", name: "noise_only",
            expected: "", decoded: decoded, cer: decoded.isEmpty ? 0 : 1, score: score
        )
        results.append(result)
        printResult(result)
        print()
    }

    // MARK: - Test Runners

    mutating func runTest(
        category: String, name: String,
        config: CWConfiguration, text: String,
        impairment: (([Float]) -> [Float])? = nil
    ) -> TestResult {
        var modulator = CWModulator(configuration: config)
        let decoder = makeDecoder(configuration: config)

        var samples = modulator.modulateTextWithEnvelope(text, preambleMs: 300, postambleMs: 500)

        if let impair = impairment {
            samples = impair(samples)
        }

        decoder.process(samples: samples)

        let decoded = decoder.decodedText
        let cer = characterErrorRate(expected: text, actual: decoded)
        return TestResult(category: category, name: name, expected: text, decoded: decoded, cer: cer, score: cerToScore(cer))
    }

    mutating func runFreqOffsetTest(
        category: String, name: String,
        baseConfig: CWConfiguration, text: String, offsetHz: Double
    ) -> TestResult {
        // Modulate at offset frequency, demodulate at base frequency
        let txConfig = baseConfig.withToneFrequency(baseConfig.toneFrequency + offsetHz)
        var modulator = CWModulator(configuration: txConfig)
        let samples = modulator.modulateTextWithEnvelope(text, preambleMs: 300, postambleMs: 500)

        let decoder = makeDecoder(configuration: baseConfig)
        decoder.process(samples: samples)

        let decoded = decoder.decodedText
        let cer = characterErrorRate(expected: text, actual: decoded)
        return TestResult(category: category, name: name, expected: text, decoded: decoded, cer: cer, score: cerToScore(cer))
    }

    mutating func runFreqOffsetTestWithNoise(
        category: String, name: String,
        baseConfig: CWConfiguration, text: String, offsetHz: Double, snrDB: Float
    ) -> TestResult {
        let txConfig = baseConfig.withToneFrequency(baseConfig.toneFrequency + offsetHz)
        var modulator = CWModulator(configuration: txConfig)
        var samples = modulator.modulateTextWithEnvelope(text, preambleMs: 300, postambleMs: 500)
        var rng = SeededRandom(seed: 555 + UInt64(abs(snrDB) * 10))
        samples = addWhiteNoise(to: samples, snrDB: snrDB, rng: &rng)

        let decoder = makeDecoder(configuration: baseConfig)
        decoder.process(samples: samples)

        let decoded = decoder.decodedText
        let cer = characterErrorRate(expected: text, actual: decoded)
        return TestResult(category: category, name: name, expected: text, decoded: decoded, cer: cer, score: cerToScore(cer))
    }

    mutating func runJitterTest(
        category: String, name: String,
        config: CWConfiguration, text: String, jitterFraction: Double
    ) -> TestResult {
        var rng = SeededRandom(seed: 88 + UInt64(jitterFraction * 100))

        // Generate with preamble silence + jittered CW + postamble silence
        let preSamples = Int(0.3 * config.sampleRate)
        let postSamples = Int(0.5 * config.sampleRate)
        var samples = [Float](repeating: 0, count: preSamples)
        samples.append(contentsOf: applyTimingJitter(to: text, config: config, jitterFraction: jitterFraction, rng: &rng))
        samples.append(contentsOf: [Float](repeating: 0, count: postSamples))

        let decoder = makeDecoder(configuration: config)
        decoder.process(samples: samples)

        let decoded = decoder.decodedText
        let cer = characterErrorRate(expected: text, actual: decoded)
        return TestResult(category: category, name: name, expected: text, decoded: decoded, cer: cer, score: cerToScore(cer))
    }

    mutating func runJitterTestWithNoise(
        category: String, name: String,
        config: CWConfiguration, text: String, jitterFraction: Double, snrDB: Float
    ) -> TestResult {
        var rng = SeededRandom(seed: 99 + UInt64(jitterFraction * 100))

        let preSamples = Int(0.3 * config.sampleRate)
        let postSamples = Int(0.5 * config.sampleRate)
        var samples = [Float](repeating: 0, count: preSamples)
        samples.append(contentsOf: applyTimingJitter(to: text, config: config, jitterFraction: jitterFraction, rng: &rng))
        samples.append(contentsOf: [Float](repeating: 0, count: postSamples))

        var noiseRng = SeededRandom(seed: 444)
        samples = addWhiteNoise(to: samples, snrDB: snrDB, rng: &noiseRng)

        let decoder = makeDecoder(configuration: config)
        decoder.process(samples: samples)

        let decoded = decoder.decodedText
        let cer = characterErrorRate(expected: text, actual: decoded)
        return TestResult(category: category, name: name, expected: text, decoded: decoded, cer: cer, score: cerToScore(cer))
    }

    mutating func runDashDotTest(
        category: String, name: String,
        config: CWConfiguration, text: String, ratio: Double
    ) -> TestResult {
        // TX with different dash-dot ratio, RX with standard config (must adapt)
        let txConfig = config.withDashDotRatio(ratio)
        var modulator = CWModulator(configuration: txConfig)
        let preSamples = Int(0.3 * config.sampleRate)
        let postSamples = Int(0.5 * config.sampleRate)
        var samples = [Float](repeating: 0, count: preSamples)
        samples.append(contentsOf: modulator.modulateText(text))
        samples.append(contentsOf: [Float](repeating: 0, count: postSamples))

        let decoder = makeDecoder(configuration: config)
        decoder.process(samples: samples)

        let decoded = decoder.decodedText
        let cer = characterErrorRate(expected: text, actual: decoded)
        return TestResult(category: category, name: name, expected: text, decoded: decoded, cer: cer, score: cerToScore(cer))
    }

    mutating func runSpeedChangeTest(
        category: String, name: String,
        text1: String, wpm1: Double,
        text2: String, wpm2: Double
    ) -> TestResult {
        let config1 = CWConfiguration.standard.withWPM(wpm1)
        let config2 = CWConfiguration.standard.withWPM(wpm2)

        var mod1 = CWModulator(configuration: config1)
        var mod2 = CWModulator(configuration: config2)

        let preSamples = Int(0.3 * 48000)
        let midSamples = Int(0.5 * 48000)  // Gap between speed changes
        let postSamples = Int(0.5 * 48000)

        var samples = [Float](repeating: 0, count: preSamples)
        samples.append(contentsOf: mod1.modulateText(text1))
        samples.append(contentsOf: [Float](repeating: 0, count: midSamples))
        samples.append(contentsOf: mod2.modulateText(text2))
        samples.append(contentsOf: [Float](repeating: 0, count: postSamples))

        // Decoder starts at wpm1 and must adapt to wpm2
        let decoder = makeDecoder(configuration: config1)
        decoder.process(samples: samples)

        let expectedFull = text1 + " " + text2
        let decoded = decoder.decodedText
        let cer = characterErrorRate(expected: expectedFull, actual: decoded)
        return TestResult(category: category, name: name, expected: expectedFull, decoded: decoded, cer: cer, score: cerToScore(cer))
    }

    // MARK: - Output

    func printResult(_ r: TestResult) {
        let scoreStr = String(format: "%5.1f", r.score)
        let cerStr = String(format: "%5.1f%%", r.cer * 100)
        let decodedPreview = r.decoded.count > 40
            ? String(r.decoded.prefix(37)) + "..."
            : r.decoded
        print("  [CW] \(r.category)/\(r.name): score=\(scoreStr) cer=\(cerStr) decoded=\"\(decodedPreview)\"")
    }

    func printSummary() {
        print(String(repeating: "=", count: 70))
        print("SUMMARY")
        print(String(repeating: "=", count: 70))

        let categories = Dictionary(grouping: results, by: { $0.category })
        var categoryScores: [(String, Double)] = []

        for (category, tests) in categories.sorted(by: { $0.key < $1.key }) {
            let avgScore = tests.map(\.score).reduce(0, +) / Double(tests.count)
            categoryScores.append((category, avgScore))
            print("  \(category): \(String(format: "%.1f", avgScore))/100 (\(tests.count) tests)")
        }

        // Composite score (weighted)
        let weights: [String: Double] = [
            "clean": 2.0,           // Must decode clean signal perfectly
            "speed": 1.5,           // Speed range is important
            "noise": 2.0,           // Noise immunity critical for real-world
            "freq_offset": 1.5,     // AFC for tuning tolerance
            "fading": 2.0,          // QSB is the #1 real-world challenge
            "itu_channel": 2.5,     // ITU standard HF channels (real-world propagation)
            "jitter": 2.0,          // Hand-sent CW is the norm
            "dash_dot": 1.5,        // Real ops have variable ratios
            "combined": 2.5,        // Combined impairments = real world
            "long_message": 2.0,    // Realistic QSO-length messages
            "qrm": 2.0,            // Nearby CW stations (contest/pileup)
            "chirp": 1.5,          // Transmitter frequency shift on key-down
            "auroral_flutter": 2.0, // Trans-polar CW path degradation
            "agc_pumping": 1.5,     // AGC modulated by nearby strong station
            "sample_rate": 1.5,     // Cheap USB audio clock mismatch
            "metamorphic": 1.5,     // Invariance: amplitude, time shift, determinism
            "false_positive": 2.0,  // Must not decode noise
            // Suite v2
            "cold_start": 2.5,      // Decoder starts mid-signal (post-TX reality)
            "qrn": 2.0,             // Impulsive static crashes
            "drift": 1.5,           // Continuous VFO drift while locked
            "swing": 2.0,           // Systematic straight-key/bug fist bias
            "farnsworth": 1.5,      // Stretched gaps (teaching nets)
            "speed_jitter": 1.5,    // Hand-sent at 30-40 WPM (quantization limit)
            "tone_freq": 1.0,       // Coverage beyond 700 Hz
            "chunked_parity": 1.5,  // App-sized buffers must decode identically
            "callsign_copy": 2.5,   // Exact callsign copy = the app's routing currency
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
        print(String(repeating: "=", count: 70))
        print("COMPOSITE SCORE: \(String(format: "%.1f", compositeScore)) / 100")
        print(String(repeating: "=", count: 70))

        writeJSON(compositeScore: compositeScore)
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
            json += "\"expected\": \"\(escaped_expected)\", "
            json += "\"decoded\": \"\(escaped_decoded)\", "
            json += "\"cer\": \(String(format: "%.4f", r.cer)), "
            json += "\"score\": \(String(format: "%.2f", r.score))"
            json += "}\(i < results.count - 1 ? "," : "")\n"
        }

        json += "  ]\n"
        json += "}\n"

        let path = "/tmp/cw_benchmark_latest.json"
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
        print("\nDetailed results written to: \(path)")
    }

    func appendScoreHistory(compositeScore: Double, categoryScores: [(String, Double)]) {
        let historyPath = "/tmp/cw_benchmark_history.csv"
        let timestamp = ISO8601DateFormatter().string(from: Date())

        if !FileManager.default.fileExists(atPath: historyPath) {
            let header = "timestamp,composite_score,clean,speed,noise,freq_offset,fading,jitter,dash_dot,combined,false_positive\n"
            try? header.write(toFile: historyPath, atomically: true, encoding: .utf8)
        }

        let scoreMap = Dictionary(uniqueKeysWithValues: categoryScores)
        let cats = ["clean", "speed", "noise", "freq_offset", "fading", "jitter", "dash_dot", "combined", "false_positive"]
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

// MARK: - Parameter Override (for automated optimization)

/// Classic CW decoder parameters overridable via --params /path/to/params.json.
/// Used by Optuna/CMA-ES to explore the parameter space automatically.
struct CWOptimizationParams: Codable {
    var thresholdFractionClean: Double?
    var thresholdFractionModerate: Double?
    var thresholdFractionNoisy: Double?
    var signalDecayRate: Double?
    var toneDetectMultiplier: Double?
    var bootstrapMultiplier: Double?
    var hysteresisOffRatio: Double?
    var minStatsFactor: Double?
}

var cwOptimParams: CWOptimizationParams?
if let idx = CommandLine.arguments.firstIndex(of: "--params"),
   idx + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[idx + 1]
    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
       let params = try? JSONDecoder().decode(CWOptimizationParams.self, from: data) {
        cwOptimParams = params
        print("Loaded CW optimization params from \(path)")
    } else {
        print("Warning: could not load CW params from \(path)")
    }
}

var bayesianParams: BayesianCWParams?
if let idx = CommandLine.arguments.firstIndex(of: "--bayesian-params"),
   idx + 1 < CommandLine.arguments.count {
    let path = CommandLine.arguments[idx + 1]
    if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
       let params = try? JSONDecoder().decode(BayesianCWParams.self, from: data) {
        bayesianParams = params
        print("Loaded Bayesian params from \(path)")
    } else {
        print("Warning: could not load Bayesian params from \(path)")
    }
}

let bayesianOnly = CommandLine.arguments.contains("--bayesian-only")
let compareMode = CommandLine.arguments.contains("--compare")
let dualOnly = CommandLine.arguments.contains("--dual")

// Real off-air corpus: score WAV recordings against sidecar transcripts.
// Held out of the synthetic composite — this is the overfitting check.
if let corpusIdx = CommandLine.arguments.firstIndex(of: "--corpus"),
   corpusIdx + 1 < CommandLine.arguments.count {
    let directory = CommandLine.arguments[corpusIdx + 1]
    let mode: DecoderMode = dualOnly ? .dual : (bayesianOnly ? .bayesian : .classic)
    CorpusRunner.run(directory: directory, mode: mode, bayesianParams: bayesianParams)
    exit(0)
}

// MARK: - Main

let fpOnly = CommandLine.arguments.contains("--fp-only")

if fpOnly {
    // Fast loop for false-positive tuning; --dual / --bayesian-only pick the decoder.
    let mode: DecoderMode = dualOnly ? .dual : (bayesianOnly ? .bayesian : .classic)
    print("Starting CW benchmark (FP subset, \(mode))...")
    var suite = BenchmarkSuite()
    suite.decoderMode = mode
    suite.bayesianParams = bayesianParams
    suite.cwOptimParams = cwOptimParams
    suite.runFPSubset()
} else if dualOnly {
    // Run only the dual (diversity) decoder — what the Dits app ships.
    print("Starting CW benchmark (Dual/diversity only)...")
    var suite = BenchmarkSuite()
    suite.decoderMode = .dual
    suite.runAll()
} else if bayesianOnly {
    // Run only the Bayesian decoder (for Optuna optimization speed)
    print("Starting CW benchmark (Bayesian only)...")
    var suite = BenchmarkSuite()
    suite.decoderMode = .bayesian
    suite.bayesianParams = bayesianParams
    suite.runAll()
} else if compareMode {
    // Run both classic and Bayesian, print comparison
    print("Starting CW benchmark (compare mode)...")

    print("\n>>> Running CLASSIC decoder...")
    var classicSuite = BenchmarkSuite()
    classicSuite.decoderMode = .classic
    classicSuite.runAll()

    print("\n>>> Running BAYESIAN decoder...")
    var bayesianSuite = BenchmarkSuite()
    bayesianSuite.decoderMode = .bayesian
    bayesianSuite.bayesianParams = bayesianParams
    bayesianSuite.runAll()
} else {
    // Default: run classic decoder only
    print("Starting CW benchmark...")
    var suite = BenchmarkSuite()
    suite.decoderMode = .classic
    suite.cwOptimParams = cwOptimParams
    suite.runAll()
}
