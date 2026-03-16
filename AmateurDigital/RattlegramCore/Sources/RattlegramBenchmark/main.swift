/*
 RattlegramBenchmark — evaluation harness for Rattlegram OFDM decoder robustness.
 Tests decoding under noise, fading, frequency offset, multipath, level variation,
 and combined impairments. Modeled after the CW benchmark harness.
 */

import Foundation
import RattlegramCore

// MARK: - Seeded PRNG (reproducible noise)

struct XorShift64 {
    var state: UInt64

    init(seed: UInt64 = 12345) {
        state = seed == 0 ? 1 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// Uniform random in [0, 1)
    mutating func uniform() -> Float {
        Float(next() & 0xFFFFFFFF) / Float(UInt32.max)
    }

    /// Gaussian via Box-Muller
    mutating func gaussian() -> Float {
        let u1 = max(uniform(), Float.leastNormalMagnitude)
        let u2 = uniform()
        return sqrt(-2.0 * log(u1)) * cos(2.0 * Float.pi * u2)
    }
}

// MARK: - Test infrastructure

struct TestResult {
    let category: String
    let name: String
    let expected: String
    let decoded: String
    let expectedCall: String
    let decodedCall: String
    let bitFlips: Int       // -1 = CRC fail, 0 = perfect, >0 = corrected errors
    let synced: Bool
    let score: Float        // 0-100
}

let hamTexts: [(text: String, callSign: String)] = [
    ("CQ CQ CQ DE W1AW W1AW K", "W1AW"),
    ("DE K1ABC UR RST 599 599 K", "K1ABC"),
    ("73 DE N0CALL", "N0CALL"),
    ("TEST TEST DE WA2XYZ K", "WA2XYZ"),
    ("CQ CONTEST DE VE3ABC K", "VE3ABC"),
    ("QTH NEW YORK CITY NY K", "W2NYC"),
    ("WX CLEAR TEMP 72F WIND CALM K", "KA1WX"),
    ("HELLO WORLD THIS IS A TEST", "TEST"),
    ("THE QUICK BROWN FOX JUMPED", "W9FOX"),
    ("AMATEUR RADIO DIGITAL MODE", "AA1DM"),
]

// MARK: - Impairment Functions

func addWhiteNoise(_ samples: inout [Int16], snrDB: Float, seed: UInt64 = 42) {
    var rng = XorShift64(seed: seed)

    // Calculate signal RMS
    var sumSq: Float = 0
    var count = 0
    for s in samples where s != 0 {
        let f = Float(s)
        sumSq += f * f
        count += 1
    }
    guard count > 0 else { return }
    let signalRMS = sqrt(sumSq / Float(count))
    let noiseRMS = signalRMS / pow(10, snrDB / 20.0)

    for i in 0..<samples.count {
        let noise = noiseRMS * rng.gaussian()
        let v = Float(samples[i]) + noise
        samples[i] = Int16(clamping: Int(nearbyint(min(max(v, -32768), 32767))))
    }
}

func applyFrequencyShift(_ samples: inout [Int16], shiftHz: Float, sampleRate: Int) {
    let omega = 2.0 * Float.pi * shiftHz / Float(sampleRate)
    for i in 0..<samples.count {
        let f = Float(samples[i])
        let shifted = f * cos(omega * Float(i))
        samples[i] = Int16(clamping: Int(nearbyint(min(max(shifted, -32768), 32767))))
    }
}

func applyFading(_ samples: inout [Int16], fadeRateHz: Float, depth: Float, sampleRate: Int) {
    let omega = 2.0 * Float.pi * fadeRateHz / Float(sampleRate)
    for i in 0..<samples.count {
        let envelope = 1.0 - depth * (1.0 + cos(omega * Float(i))) / 2.0
        let f = Float(samples[i]) * envelope
        samples[i] = Int16(clamping: Int(nearbyint(min(max(f, -32768), 32767))))
    }
}

func applyMultipath(_ samples: inout [Int16], delayMs: Float, attenuation: Float, sampleRate: Int) {
    let delaySamples = Int(delayMs * Float(sampleRate) / 1000.0)
    guard delaySamples > 0 && delaySamples < samples.count else { return }
    // Work backwards to avoid overwriting source samples
    let original = samples
    for i in delaySamples..<samples.count {
        let echo = Float(original[i - delaySamples]) * attenuation
        let combined = Float(samples[i]) + echo
        samples[i] = Int16(clamping: Int(nearbyint(min(max(combined, -32768), 32767))))
    }
}

func scaleAmplitude(_ samples: inout [Int16], factor: Float) {
    for i in 0..<samples.count {
        let f = Float(samples[i]) * factor
        samples[i] = Int16(clamping: Int(nearbyint(min(max(f, -32768), 32767))))
    }
}

func applyClipping(_ samples: inout [Int16], threshold: Float) {
    let limit = Int16(clamping: Int(threshold * 32767))
    for i in 0..<samples.count {
        if samples[i] > limit { samples[i] = limit }
        if samples[i] < -limit { samples[i] = -limit }
    }
}

func applyImpulseNoise(_ samples: inout [Int16], probability: Float, amplitude: Float,
                        seed: UInt64 = 55555) {
    var rng = XorShift64(seed: seed)
    let amp = Int16(clamping: Int(amplitude * 32767))
    for i in 0..<samples.count {
        if rng.uniform() < probability {
            samples[i] = rng.uniform() > 0.5 ? amp : -amp
        }
    }
}

func applyDopplerSpread(_ samples: inout [Int16], spreadHz: Float, sampleRate: Int,
                         seed: UInt64 = 77777) {
    // Simulate Doppler spread by applying random time-varying phase rotation
    var rng = XorShift64(seed: seed)
    let blockSize = max(1, sampleRate / 100)  // 10ms blocks
    var phase: Float = 0
    let maxDPhase = 2.0 * Float.pi * spreadHz / Float(sampleRate) * Float(blockSize)

    for blockStart in stride(from: 0, to: samples.count, by: blockSize) {
        let blockEnd = min(blockStart + blockSize, samples.count)
        let dPhase = (rng.gaussian() * 0.3) * maxDPhase
        for i in blockStart..<blockEnd {
            let f = Float(samples[i])
            let shifted = f * cos(phase)
            samples[i] = Int16(clamping: Int(nearbyint(min(max(shifted, -32768), 32767))))
            phase += dPhase / Float(blockSize)
        }
        phase = phase.truncatingRemainder(dividingBy: 2.0 * Float.pi)
    }
}

// MARK: - Encode helper

func encode(text: String, callSign: String, sampleRate: Int,
            carrierFrequency: Int = 1500) -> [Int16] {
    let encoder = Encoder(sampleRate: sampleRate)
    let utf8 = Array(text.utf8)
    var payload = [UInt8](repeating: 0, count: 170)
    for i in 0..<min(utf8.count, 170) {
        payload[i] = utf8[i]
    }
    encoder.configure(payload: payload, callSign: callSign,
                      carrierFrequency: carrierFrequency)

    var allSamples = [Int16]()
    var audioBuffer = [Int16](repeating: 0, count: encoder.extendedLength)
    while encoder.produce(&audioBuffer) {
        allSamples.append(contentsOf: audioBuffer)
    }
    allSamples.append(contentsOf: audioBuffer) // final silence

    return allSamples
}

// MARK: - Decode helper

struct DecodeResult {
    let synced: Bool
    let done: Bool
    let text: String
    let callSign: String
    let bitFlips: Int   // -1 if CRC fail
}

func decode(samples: [Int16], sampleRate: Int) -> DecodeResult {
    let decoder = Decoder(sampleRate: sampleRate)
    let extLen = decoder.extendedLength

    // Add leading and trailing silence
    let leadingSilence = [Int16](repeating: 0, count: extLen * 2)
    let trailingSilence = [Int16](repeating: 0, count: extLen * 2)
    var input = leadingSilence + samples + trailingSilence

    var offset = 0
    var synced = false
    var done = false
    var decodedText = ""
    var decodedCall = ""
    var bitFlips = -1

    while offset + extLen <= input.count {
        let chunk = Array(input[offset..<(offset + extLen)])
        let ready = decoder.feed(chunk, sampleCount: extLen)
        offset += extLen

        if ready {
            let status = decoder.process()
            switch status {
            case .sync:
                let info = decoder.staged()
                decodedCall = info.callSign.trimmingCharacters(in: .whitespaces)
                synced = true
            case .done:
                var decodedPayload = [UInt8](repeating: 0, count: 170)
                let result = decoder.fetch(&decodedPayload)
                if result >= 0 {
                    var len = 0
                    while len < 170 && decodedPayload[len] != 0 { len += 1 }
                    decodedText = String(bytes: decodedPayload[0..<len], encoding: .utf8) ?? ""
                    bitFlips = result
                    done = true
                }
            default:
                break
            }
        }
        if done { break }
    }

    return DecodeResult(synced: synced, done: done, text: decodedText,
                       callSign: decodedCall, bitFlips: bitFlips)
}

// MARK: - Scoring

func scoreResult(expected: String, expectedCall: String,
                 result: DecodeResult) -> Float {
    if !result.done { return 0 }
    var score: Float = 0
    // Text match: 75 points
    if result.text == expected {
        score += 75
    } else {
        // Partial credit via Levenshtein
        let distance = levenshtein(expected, result.text)
        let maxLen = max(expected.count, 1)
        let cer = Float(distance) / Float(maxLen)
        score += 75 * max(0, 1 - cer)
    }
    // Callsign match: 15 points
    let trimmedExpected = expectedCall.trimmingCharacters(in: .whitespaces)
    if result.callSign.hasPrefix(trimmedExpected) {
        score += 15
    }
    // Bit flips quality: 10 points, logarithmic decay
    // 0 flips = 10, ~3 = 7.5, ~15 = 5, ~90 = 1.8, 255+ = 0
    if result.bitFlips >= 0 {
        let logPenalty = log2(1.0 + Float(result.bitFlips)) / 8.0
        score += 10 * max(0, 1 - logPenalty)
    }
    return min(score, 100)
}

func levenshtein(_ a: String, _ b: String) -> Int {
    let a = Array(a)
    let b = Array(b)
    let m = a.count, n = b.count
    if m == 0 { return n }
    if n == 0 { return m }
    var dp = [[Int]](repeating: [Int](repeating: 0, count: n + 1), count: m + 1)
    for i in 0...m { dp[i][0] = i }
    for j in 0...n { dp[0][j] = j }
    for i in 1...m {
        for j in 1...n {
            let cost = a[i - 1] == b[j - 1] ? 0 : 1
            dp[i][j] = min(dp[i - 1][j] + 1, dp[i][j - 1] + 1, dp[i - 1][j - 1] + cost)
        }
    }
    return dp[m][n]
}

// MARK: - Benchmark Suite

struct BenchmarkSuite {
    let sampleRate = 48000
    var results: [TestResult] = []

    mutating func runAll() {
        print("╔══════════════════════════════════════════════════════════╗")
        print("║        Rattlegram OFDM Decoder Benchmark                ║")
        print("║        Sample Rate: \(sampleRate) Hz                          ║")
        print("╚══════════════════════════════════════════════════════════╝")
        print()

        runCleanChannel()
        runModeSweep()
        runNoiseSweep()
        runFrequencyOffset()
        runFading()
        runMultipath()
        runLevelVariation()
        runCombinedImpairments()
        runFalsePositive()

        printSummary()
        writeJSON()
    }

    // MARK: - Category: Clean Channel

    mutating func runCleanChannel() {
        printCategory("Clean Channel (Baseline)")
        for (i, msg) in hamTexts.enumerated() {
            let samples = encode(text: msg.text, callSign: msg.callSign,
                                sampleRate: sampleRate)
            let result = decode(samples: samples, sampleRate: sampleRate)
            let score = scoreResult(expected: msg.text, expectedCall: msg.callSign,
                                   result: result)
            let tr = TestResult(category: "clean", name: "clean_\(i)",
                               expected: msg.text, decoded: result.text,
                               expectedCall: msg.callSign, decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }
    }

    // MARK: - Category: Mode Sweep

    mutating func runModeSweep() {
        printCategory("Mode Sweep (14/15/16)")

        // Mode 16: <= 85 bytes (strongest FEC)
        let short = "SHORT MSG"
        runSingle(category: "mode", name: "mode16_short",
                  text: short, callSign: "W1AW")

        let mode16Max = String(repeating: "X", count: 85)
        runSingle(category: "mode", name: "mode16_max",
                  text: mode16Max, callSign: "W1AW")

        // Mode 15: 86-128 bytes
        let mode15 = String(repeating: "Y", count: 120)
        runSingle(category: "mode", name: "mode15_120",
                  text: mode15, callSign: "K1ABC")

        let mode15Max = String(repeating: "Z", count: 128)
        runSingle(category: "mode", name: "mode15_max",
                  text: mode15Max, callSign: "K1ABC")

        // Mode 14: 129-170 bytes (weakest FEC)
        let mode14 = String(repeating: "W", count: 150)
        runSingle(category: "mode", name: "mode14_150",
                  text: mode14, callSign: "N0CALL")

        let mode14Max = String(repeating: "Q", count: 170)
        runSingle(category: "mode", name: "mode14_max",
                  text: mode14Max, callSign: "N0CALL")
    }

    // MARK: - Category: Noise Sweep

    mutating func runNoiseSweep() {
        printCategory("Noise Sweep (SNR)")
        let text = "CQ CQ CQ DE W1AW K"
        let call = "W1AW"
        let snrLevels: [Float] = [30, 25, 20, 15, 12, 10, 8, 6, 3, 0, -3, -6]

        for snr in snrLevels {
            var samples = encode(text: text, callSign: call, sampleRate: sampleRate)
            addWhiteNoise(&samples, snrDB: snr, seed: UInt64(snr.bitPattern))
            let result = decode(samples: samples, sampleRate: sampleRate)
            let score = scoreResult(expected: text, expectedCall: call, result: result)
            let tr = TestResult(category: "noise", name: "snr_\(Int(snr))dB",
                               expected: text, decoded: result.text,
                               expectedCall: call, decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }

        // Mode 14 (weakest FEC) under noise
        let longText = String(repeating: "CQ DE W1AW ", count: 14).prefix(170)
        let lt = String(longText)
        for snr: Float in [15, 10, 6, 3] {
            var samples = encode(text: lt, callSign: call, sampleRate: sampleRate)
            addWhiteNoise(&samples, snrDB: snr, seed: UInt64(snr.bitPattern) &+ 1000)
            let result = decode(samples: samples, sampleRate: sampleRate)
            let score = scoreResult(expected: lt, expectedCall: call, result: result)
            let tr = TestResult(category: "noise", name: "mode14_snr\(Int(snr))dB",
                               expected: lt, decoded: result.text,
                               expectedCall: call, decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }
    }

    // MARK: - Category: Frequency Offset

    mutating func runFrequencyOffset() {
        printCategory("Frequency Offset")
        let text = "CQ CQ DE W1AW K"
        let call = "W1AW"
        // Encode at shifted frequency, decode at standard
        // Max negative offset limited by subcarrier bandwidth (carriers must stay above 0 Hz)
        let offsets: [Int] = [-700, -500, -200, -100, -50, 50, 100, 200, 500, 1000]

        for offset in offsets {
            let txFreq = 1500 + offset
            let samples = encode(text: text, callSign: call, sampleRate: sampleRate,
                                carrierFrequency: txFreq)
            let result = decode(samples: samples, sampleRate: sampleRate)
            let score = scoreResult(expected: text, expectedCall: call, result: result)
            let sign = offset >= 0 ? "+" : ""
            let tr = TestResult(category: "freq_offset",
                               name: "offset_\(sign)\(offset)Hz",
                               expected: text, decoded: result.text,
                               expectedCall: call, decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }
    }

    // MARK: - Category: Fading (QSB)

    mutating func runFading() {
        printCategory("Fading (QSB)")
        let text = "CQ CQ CQ DE W1AW K"
        let call = "W1AW"

        let scenarios: [(name: String, rate: Float, depth: Float)] = [
            ("slow_shallow", 0.5, 0.3),
            ("slow_moderate", 0.5, 0.6),
            ("slow_deep", 0.5, 0.8),
            ("slow_extreme", 0.5, 0.95),
            ("medium_moderate", 1.0, 0.5),
            ("medium_deep", 1.0, 0.8),
            ("fast_moderate", 2.0, 0.5),
            ("fast_deep", 2.0, 0.8),
            ("vfast_moderate", 5.0, 0.5),
            ("vfast_deep", 5.0, 0.8),
            ("extreme_moderate", 10.0, 0.5),
        ]

        for scenario in scenarios {
            var samples = encode(text: text, callSign: call, sampleRate: sampleRate)
            applyFading(&samples, fadeRateHz: scenario.rate,
                       depth: scenario.depth, sampleRate: sampleRate)
            let result = decode(samples: samples, sampleRate: sampleRate)
            let score = scoreResult(expected: text, expectedCall: call, result: result)
            let tr = TestResult(category: "fading", name: scenario.name,
                               expected: text, decoded: result.text,
                               expectedCall: call, decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }
    }

    // MARK: - Category: Multipath

    mutating func runMultipath() {
        printCategory("Multipath (Echo)")
        let text = "CQ CQ CQ DE W1AW K"
        let call = "W1AW"

        let scenarios: [(name: String, delayMs: Float, atten: Float)] = [
            ("short_weak", 0.5, 0.1),
            ("short_moderate", 0.5, 0.3),
            ("short_strong", 0.5, 0.5),
            ("medium_weak", 2.0, 0.1),
            ("medium_moderate", 2.0, 0.3),
            ("long_weak", 5.0, 0.1),
            ("long_moderate", 5.0, 0.3),
            ("vlong_weak", 10.0, 0.1),
        ]

        for scenario in scenarios {
            var samples = encode(text: text, callSign: call, sampleRate: sampleRate)
            applyMultipath(&samples, delayMs: scenario.delayMs,
                          attenuation: scenario.atten, sampleRate: sampleRate)
            let result = decode(samples: samples, sampleRate: sampleRate)
            let score = scoreResult(expected: text, expectedCall: call, result: result)
            let tr = TestResult(category: "multipath", name: scenario.name,
                               expected: text, decoded: result.text,
                               expectedCall: call, decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }
    }

    // MARK: - Category: Level Variation

    mutating func runLevelVariation() {
        printCategory("Level Variation")
        let text = "CQ CQ DE W1AW K"
        let call = "W1AW"

        // Quiet signals
        let quietLevels: [(name: String, factor: Float)] = [
            ("quiet_50pct", 0.5),
            ("quiet_25pct", 0.25),
            ("quiet_10pct", 0.1),
            ("quiet_5pct", 0.05),
            ("quiet_1pct", 0.01),
        ]
        for level in quietLevels {
            var samples = encode(text: text, callSign: call, sampleRate: sampleRate)
            scaleAmplitude(&samples, factor: level.factor)
            let result = decode(samples: samples, sampleRate: sampleRate)
            let score = scoreResult(expected: text, expectedCall: call, result: result)
            let tr = TestResult(category: "level", name: level.name,
                               expected: text, decoded: result.text,
                               expectedCall: call, decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }

        // Clipped signals
        let clipLevels: [(name: String, threshold: Float)] = [
            ("clip_80pct", 0.8),
            ("clip_50pct", 0.5),
            ("clip_30pct", 0.3),
            ("clip_10pct", 0.1),
        ]
        for level in clipLevels {
            var samples = encode(text: text, callSign: call, sampleRate: sampleRate)
            applyClipping(&samples, threshold: level.threshold)
            let result = decode(samples: samples, sampleRate: sampleRate)
            let score = scoreResult(expected: text, expectedCall: call, result: result)
            let tr = TestResult(category: "level", name: level.name,
                               expected: text, decoded: result.text,
                               expectedCall: call, decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }
    }

    // MARK: - Category: Combined Impairments

    mutating func runCombinedImpairments() {
        printCategory("Combined Impairments (Real-World)")
        let text = "CQ CQ CQ DE W1AW W1AW K"
        let call = "W1AW"

        // 1. Noise + fading
        do {
            var samples = encode(text: text, callSign: call, sampleRate: sampleRate)
            addWhiteNoise(&samples, snrDB: 15, seed: 100)
            applyFading(&samples, fadeRateHz: 0.5, depth: 0.3, sampleRate: sampleRate)
            let result = decode(samples: samples, sampleRate: sampleRate)
            let score = scoreResult(expected: text, expectedCall: call, result: result)
            let tr = TestResult(category: "combined", name: "noise15_fade_slow",
                               expected: text, decoded: result.text,
                               expectedCall: call, decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }

        // 2. Noise + freq offset
        do {
            let samples = encode(text: text, callSign: call, sampleRate: sampleRate,
                                carrierFrequency: 1600)
            var noisy = samples
            addWhiteNoise(&noisy, snrDB: 15, seed: 200)
            let result = decode(samples: noisy, sampleRate: sampleRate)
            let score = scoreResult(expected: text, expectedCall: call, result: result)
            let tr = TestResult(category: "combined", name: "noise15_offset100",
                               expected: text, decoded: result.text,
                               expectedCall: call, decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }

        // 3. Noise + multipath
        do {
            var samples = encode(text: text, callSign: call, sampleRate: sampleRate)
            applyMultipath(&samples, delayMs: 1.0, attenuation: 0.2, sampleRate: sampleRate)
            addWhiteNoise(&samples, snrDB: 15, seed: 300)
            let result = decode(samples: samples, sampleRate: sampleRate)
            let score = scoreResult(expected: text, expectedCall: call, result: result)
            let tr = TestResult(category: "combined", name: "noise15_multipath",
                               expected: text, decoded: result.text,
                               expectedCall: call, decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }

        // 4. Fading + multipath + noise (harsh HF)
        do {
            var samples = encode(text: text, callSign: call, sampleRate: sampleRate)
            applyFading(&samples, fadeRateHz: 1.0, depth: 0.5, sampleRate: sampleRate)
            applyMultipath(&samples, delayMs: 2.0, attenuation: 0.2, sampleRate: sampleRate)
            addWhiteNoise(&samples, snrDB: 10, seed: 400)
            let result = decode(samples: samples, sampleRate: sampleRate)
            let score = scoreResult(expected: text, expectedCall: call, result: result)
            let tr = TestResult(category: "combined", name: "harsh_hf",
                               expected: text, decoded: result.text,
                               expectedCall: call, decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }

        // 5. Quiet + noise (weak signal)
        do {
            var samples = encode(text: text, callSign: call, sampleRate: sampleRate)
            scaleAmplitude(&samples, factor: 0.1)
            addWhiteNoise(&samples, snrDB: 12, seed: 500)
            let result = decode(samples: samples, sampleRate: sampleRate)
            let score = scoreResult(expected: text, expectedCall: call, result: result)
            let tr = TestResult(category: "combined", name: "weak_noisy",
                               expected: text, decoded: result.text,
                               expectedCall: call, decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }

        // 6. Clipping + noise (overdriven receiver)
        do {
            var samples = encode(text: text, callSign: call, sampleRate: sampleRate)
            applyClipping(&samples, threshold: 0.5)
            addWhiteNoise(&samples, snrDB: 15, seed: 600)
            let result = decode(samples: samples, sampleRate: sampleRate)
            let score = scoreResult(expected: text, expectedCall: call, result: result)
            let tr = TestResult(category: "combined", name: "clipped_noisy",
                               expected: text, decoded: result.text,
                               expectedCall: call, decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }

        // 7. Long message mode 14 with noise + fading
        do {
            let longText = String(repeating: "CQ DE W1AW ", count: 14).prefix(170)
            let lt = String(longText)
            var samples = encode(text: lt, callSign: call, sampleRate: sampleRate)
            addWhiteNoise(&samples, snrDB: 12, seed: 700)
            applyFading(&samples, fadeRateHz: 0.5, depth: 0.4, sampleRate: sampleRate)
            let result = decode(samples: samples, sampleRate: sampleRate)
            let score = scoreResult(expected: lt, expectedCall: call, result: result)
            let tr = TestResult(category: "combined", name: "long_noisy_fading",
                               expected: lt, decoded: result.text,
                               expectedCall: call, decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }

        // 8. All impairments mild
        do {
            var samples = encode(text: text, callSign: call, sampleRate: sampleRate,
                                carrierFrequency: 1550)
            applyFading(&samples, fadeRateHz: 0.3, depth: 0.2, sampleRate: sampleRate)
            applyMultipath(&samples, delayMs: 0.5, attenuation: 0.1, sampleRate: sampleRate)
            addWhiteNoise(&samples, snrDB: 18, seed: 800)
            scaleAmplitude(&samples, factor: 0.5)
            let result = decode(samples: samples, sampleRate: sampleRate)
            let score = scoreResult(expected: text, expectedCall: call, result: result)
            let tr = TestResult(category: "combined", name: "all_mild",
                               expected: text, decoded: result.text,
                               expectedCall: call, decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }

        // 9. Impulse noise (QRM-like)
        do {
            var samples = encode(text: text, callSign: call, sampleRate: sampleRate)
            applyImpulseNoise(&samples, probability: 0.005, amplitude: 0.8, seed: 900)
            let result = decode(samples: samples, sampleRate: sampleRate)
            let score = scoreResult(expected: text, expectedCall: call, result: result)
            let tr = TestResult(category: "combined", name: "impulse_noise",
                               expected: text, decoded: result.text,
                               expectedCall: call, decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }

        // 10. Doppler spread (ionospheric)
        do {
            var samples = encode(text: text, callSign: call, sampleRate: sampleRate)
            applyDopplerSpread(&samples, spreadHz: 5, sampleRate: sampleRate, seed: 1000)
            let result = decode(samples: samples, sampleRate: sampleRate)
            let score = scoreResult(expected: text, expectedCall: call, result: result)
            let tr = TestResult(category: "combined", name: "doppler_5hz",
                               expected: text, decoded: result.text,
                               expectedCall: call, decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }

        // 11. All impairments moderate (realistic bad HF)
        do {
            var samples = encode(text: text, callSign: call, sampleRate: sampleRate,
                                carrierFrequency: 1550)
            applyFading(&samples, fadeRateHz: 1.0, depth: 0.5, sampleRate: sampleRate)
            applyMultipath(&samples, delayMs: 1.0, attenuation: 0.2, sampleRate: sampleRate)
            applyImpulseNoise(&samples, probability: 0.001, amplitude: 0.5, seed: 1100)
            addWhiteNoise(&samples, snrDB: 10, seed: 1100)
            let result = decode(samples: samples, sampleRate: sampleRate)
            let score = scoreResult(expected: text, expectedCall: call, result: result)
            let tr = TestResult(category: "combined", name: "all_moderate",
                               expected: text, decoded: result.text,
                               expectedCall: call, decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }
    }

    // MARK: - Category: False Positive

    mutating func runFalsePositive() {
        printCategory("False Positive")

        // Test 1: Pure noise
        do {
            var rng = XorShift64(seed: 9999)
            let numSamples = sampleRate * 3  // 3 seconds of noise
            var noiseSamples = [Int16](repeating: 0, count: numSamples)
            for i in 0..<numSamples {
                noiseSamples[i] = Int16(clamping: Int(nearbyint(1000 * rng.gaussian())))
            }
            let result = decode(samples: noiseSamples, sampleRate: sampleRate)
            let score: Float = result.done ? 0 : 100
            let tr = TestResult(category: "false_positive", name: "pure_noise",
                               expected: "", decoded: result.text,
                               expectedCall: "", decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }

        // Test 2: Loud noise
        do {
            var rng = XorShift64(seed: 7777)
            let numSamples = sampleRate * 3
            var noiseSamples = [Int16](repeating: 0, count: numSamples)
            for i in 0..<numSamples {
                noiseSamples[i] = Int16(clamping: Int(nearbyint(10000 * rng.gaussian())))
            }
            let result = decode(samples: noiseSamples, sampleRate: sampleRate)
            let score: Float = result.done ? 0 : 100
            let tr = TestResult(category: "false_positive", name: "loud_noise",
                               expected: "", decoded: result.text,
                               expectedCall: "", decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }

        // Test 3: Tone (CW-like interference)
        do {
            let numSamples = sampleRate * 3
            var toneSamples = [Int16](repeating: 0, count: numSamples)
            let omega = 2.0 * Float.pi * 1500.0 / Float(sampleRate)
            for i in 0..<numSamples {
                toneSamples[i] = Int16(5000 * sin(omega * Float(i)))
            }
            let result = decode(samples: toneSamples, sampleRate: sampleRate)
            let score: Float = result.done ? 0 : 100
            let tr = TestResult(category: "false_positive", name: "cw_tone",
                               expected: "", decoded: result.text,
                               expectedCall: "", decodedCall: result.callSign,
                               bitFlips: result.bitFlips, synced: result.synced,
                               score: score)
            results.append(tr)
            printResult(tr)
        }
    }

    // MARK: - Helpers

    mutating func runSingle(category: String, name: String,
                           text: String, callSign: String,
                           impairment: ((inout [Int16]) -> Void)? = nil) {
        var samples = encode(text: text, callSign: callSign, sampleRate: sampleRate)
        impairment?(&samples)
        let result = decode(samples: samples, sampleRate: sampleRate)
        let score = scoreResult(expected: text, expectedCall: callSign, result: result)
        let tr = TestResult(category: category, name: name,
                           expected: text, decoded: result.text,
                           expectedCall: callSign, decodedCall: result.callSign,
                           bitFlips: result.bitFlips, synced: result.synced,
                           score: score)
        results.append(tr)
        printResult(tr)
    }

    // MARK: - Output

    func printCategory(_ name: String) {
        print("─── \(name) ───")
    }

    func printResult(_ r: TestResult) {
        let status: String
        if r.score >= 85 {
            status = "PASS"
        } else if r.score > 0 {
            status = "PARTIAL"
        } else {
            status = "FAIL"
        }
        let flips = r.bitFlips >= 0 ? "\(r.bitFlips) flips" : "no decode"
        let preview = r.decoded.prefix(30)
        print(String(format: "  %-25s %4s  %5.1f  %-12s  %@",
                     (r.name as NSString).utf8String!,
                     (status as NSString).utf8String!,
                     r.score,
                     (flips as NSString).utf8String!,
                     String(preview)))
        if r.score < 85 {
            print("    >> synced=\(r.synced) decoded=\"\(r.decoded.prefix(40))\"")
        }
    }

    func printSummary() {
        print()
        print("══════════════════════════════════════════════════════════")
        print("                    SUMMARY")
        print("══════════════════════════════════════════════════════════")

        let categories: [(name: String, weight: Float)] = [
            ("clean", 2.0),
            ("mode", 1.5),
            ("noise", 2.0),
            ("freq_offset", 1.5),
            ("fading", 2.0),
            ("multipath", 1.5),
            ("level", 1.5),
            ("combined", 2.5),
            ("false_positive", 2.0),
        ]

        var totalWeightedScore: Float = 0
        var totalWeight: Float = 0
        var passed = 0
        var total = 0

        for (catName, weight) in categories {
            let catResults = results.filter { $0.category == catName }
            guard !catResults.isEmpty else { continue }
            let avg = catResults.reduce(Float(0)) { $0 + $1.score } / Float(catResults.count)
            let catPassed = catResults.filter { $0.score >= 85 }.count
            totalWeightedScore += avg * weight
            totalWeight += weight
            passed += catPassed
            total += catResults.count
            print(String(format: "  %-18s  %2d/%2d passed  avg %5.1f/100  (weight %.1f)",
                         (catName as NSString).utf8String!,
                         catPassed, catResults.count, avg, weight))
        }

        let composite = totalWeight > 0 ? totalWeightedScore / totalWeight : 0
        print("──────────────────────────────────────────────────────────")
        print(String(format: "  COMPOSITE SCORE:  %.1f / 100", composite))
        print(String(format: "  TESTS PASSED:     %d / %d", passed, total))
        print("══════════════════════════════════════════════════════════")
    }

    func writeJSON() {
        var entries: [[String: Any]] = []
        for r in results {
            entries.append([
                "category": r.category,
                "name": r.name,
                "expected": r.expected,
                "decoded": r.decoded,
                "expectedCall": r.expectedCall,
                "decodedCall": r.decodedCall,
                "bitFlips": r.bitFlips,
                "synced": r.synced,
                "score": r.score,
            ])
        }

        let categories: [(String, Float)] = [
            ("clean", 2.0), ("mode", 1.5), ("noise", 2.0),
            ("freq_offset", 1.5), ("fading", 2.0), ("multipath", 1.5),
            ("level", 1.5), ("combined", 2.5), ("false_positive", 2.0),
        ]

        var catScores: [String: Float] = [:]
        var totalW: Float = 0
        var totalWS: Float = 0
        for (name, weight) in categories {
            let catR = results.filter { $0.category == name }
            guard !catR.isEmpty else { continue }
            let avg = catR.reduce(Float(0)) { $0 + $1.score } / Float(catR.count)
            catScores[name] = avg
            totalWS += avg * weight
            totalW += weight
        }
        let composite = totalW > 0 ? totalWS / totalW : Float(0)

        let output: [String: Any] = [
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "sampleRate": sampleRate,
            "compositeScore": composite,
            "categoryScores": catScores,
            "tests": entries,
        ]

        if let data = try? JSONSerialization.data(withJSONObject: output,
                                                   options: [.prettyPrinted, .sortedKeys]) {
            let path = "/tmp/rattlegram_benchmark_latest.json"
            try? data.write(to: URL(fileURLWithPath: path))
            print("\nResults written to \(path)")
        }

        // Append to CSV history
        let csv = "/tmp/rattlegram_benchmark_history.csv"
        let header = "timestamp,composite," + categories.map { $0.0 }.joined(separator: ",")
        let values = ISO8601DateFormatter().string(from: Date()) + ","
            + String(format: "%.1f", composite) + ","
            + categories.map { String(format: "%.1f", catScores[$0.0] ?? 0) }.joined(separator: ",")

        if !FileManager.default.fileExists(atPath: csv) {
            try? (header + "\n" + values + "\n").write(toFile: csv, atomically: true, encoding: .utf8)
        } else {
            if let handle = FileHandle(forWritingAtPath: csv) {
                handle.seekToEndOfFile()
                handle.write((values + "\n").data(using: .utf8)!)
                handle.closeFile()
            }
        }
        print("History appended to \(csv)")
    }
}

// MARK: - Main

var suite = BenchmarkSuite()
suite.runAll()
