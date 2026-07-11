//
//  BenchmarkV2.swift — CWBenchmark suite v2 scenario categories
//
//  Adds the real-world scenarios the original suite was blind to:
//  cold start mid-signal, QRN impulse noise, continuous VFO drift,
//  straight-key swing, Farnsworth spacing, tone-frequency coverage,
//  long-duration false positives, chunked-feed parity, and a
//  callsign-copy metric aligned with the app's routing requirement.
//

import Foundation
import AmateurDigitalCore

// MARK: - Generators

/// QRN: impulsive static crashes (lightning). Broadband damped bursts,
/// Poisson-ish arrivals — structurally unlike white noise, and the most
/// common summer-band impairment.
func addImpulseNoise(to signal: [Float], burstsPerSecond: Double,
                     relativeAmplitude: Float, sampleRate: Double,
                     rng: inout SeededRandom) -> [Float] {
    let signalRMS = sqrt(signal.map { $0 * $0 }.reduce(0, +) / max(1, Float(signal.count)))
    let amp = max(signalRMS, 0.01) * relativeAmplitude
    var out = signal
    let burstCount = Int(Double(signal.count) / sampleRate * burstsPerSecond)
    for _ in 0..<burstCount {
        let pos = Int(rng.nextDouble() * Double(max(1, signal.count - 500)))
        let len = 48 + Int(rng.nextDouble() * 400)          // 1–9 ms
        for k in 0..<min(len, out.count - pos) {
            let decay = exp(-Float(k) / (Float(len) * 0.3))
            out[pos + k] += amp * decay * Float(rng.nextGaussian())
        }
    }
    return out
}

/// CW with a continuously drifting carrier (unstable VFO / thermal drift).
/// Distinct from the static frequency-offset tests: the decoder must track
/// while locked, not just acquire.
func generateDriftingCW(text: String, config: CWConfiguration,
                        driftHzPerSecond: Double) -> [Float] {
    let timings = MorseCodec.encodeToTimings(text)
    let sampleRate = config.sampleRate
    let ditDuration = MorseCodec.ditDuration(forWPM: config.wpm)
    var phase = 0.0
    var t = 0.0
    let dt = 1.0 / sampleRate
    let riseSamples = config.riseSamples
    var samples = [Float]()

    for timing in timings {
        let duration = Double(abs(timing)) * ditDuration
        let count = Int(duration * sampleRate)
        let toneOn = timing > 0
        for i in 0..<count {
            if toneOn {
                let freq = config.toneFrequency + driftHzPerSecond * t
                phase += 2.0 * .pi * freq * dt
                var envelope: Float = 1.0
                if i < riseSamples {
                    envelope = Float(0.5 * (1.0 - cos(.pi * Double(i) / Double(riseSamples))))
                } else if i >= count - riseSamples {
                    let k = i - (count - riseSamples)
                    envelope = Float(0.5 * (1.0 + cos(.pi * Double(k) / Double(riseSamples))))
                }
                samples.append(Float(sin(phase)) * envelope * 0.8)
            } else {
                samples.append(0)
            }
            t += dt
        }
    }
    return samples
}

/// Hand-sent CW with a *systematic* fist profile, unlike the uniform
/// random jitter tests. Real straight-key/bug operators have consistent
/// biases: bugs clip dahs, heavy fists stretch them, and nearly everyone
/// compresses inter-character gaps.
func generateSwingCW(text: String, config: CWConfiguration,
                     ditScale: Double, dahScale: Double,
                     intraGapScale: Double, interGapScale: Double,
                     jitter: Double, rng: inout SeededRandom) -> [Float] {
    let timings = MorseCodec.encodeToTimings(text)
    let sampleRate = config.sampleRate
    let ditDuration = MorseCodec.ditDuration(forWPM: config.wpm)
    var phase = 0.0
    let phaseInc = 2.0 * .pi * config.toneFrequency / sampleRate
    let riseSamples = config.riseSamples
    var samples = [Float]()

    for timing in timings {
        let units = abs(timing)
        var scale: Double
        if timing > 0 {
            scale = units == 1 ? ditScale : dahScale
        } else {
            scale = units == 1 ? intraGapScale : interGapScale
        }
        scale *= 1.0 + jitter * (rng.nextDouble() * 2.0 - 1.0)
        let duration = Double(units) * ditDuration * max(0.3, scale)
        let count = Int(duration * sampleRate)
        if timing > 0 {
            for i in 0..<count {
                var envelope: Float = 1.0
                if i < riseSamples {
                    envelope = Float(0.5 * (1.0 - cos(.pi * Double(i) / Double(riseSamples))))
                } else if i >= count - riseSamples {
                    let k = i - (count - riseSamples)
                    envelope = Float(0.5 * (1.0 + cos(.pi * Double(k) / Double(riseSamples))))
                }
                samples.append(Float(sin(phase)) * envelope)
                phase += phaseInc
                if phase >= 2.0 * .pi { phase -= 2.0 * .pi }
            }
        } else {
            samples.append(contentsOf: [Float](repeating: 0, count: count))
        }
    }
    return samples
}

/// Farnsworth spacing: characters keyed at `characterWPM`, gaps stretched
/// so the overall rate is `effectiveWPM`. Standard for teaching nets —
/// breaks fixed gap-multiple assumptions.
func generateFarnsworthCW(text: String, characterWPM: Double,
                          effectiveWPM: Double, config: CWConfiguration) -> [Float] {
    let charConfig = config.withWPM(characterWPM)
    let timings = MorseCodec.encodeToTimings(text)
    let sampleRate = charConfig.sampleRate
    let charDit = MorseCodec.ditDuration(forWPM: characterWPM)
    // ARRL Farnsworth: total time per PARIS word at effective speed, with
    // element time at character speed; the surplus is spread over the
    // inter-character (3-unit) and word (7-unit) gaps.
    let gapStretch = (60.0 / effectiveWPM - 31.0 * charDit) / (19.0 * charDit)
    var phase = 0.0
    let phaseInc = 2.0 * .pi * charConfig.toneFrequency / sampleRate
    let riseSamples = charConfig.riseSamples
    var samples = [Float]()

    for timing in timings {
        let units = abs(timing)
        var duration = Double(units) * charDit
        if timing < 0 && units > 1 {
            duration *= max(1.0, gapStretch)
        }
        let count = Int(duration * sampleRate)
        if timing > 0 {
            for i in 0..<count {
                var envelope: Float = 1.0
                if i < riseSamples {
                    envelope = Float(0.5 * (1.0 - cos(.pi * Double(i) / Double(riseSamples))))
                } else if i >= count - riseSamples {
                    let k = i - (count - riseSamples)
                    envelope = Float(0.5 * (1.0 + cos(.pi * Double(k) / Double(riseSamples))))
                }
                samples.append(Float(sin(phase)) * envelope)
                phase += phaseInc
                if phase >= 2.0 * .pi { phase -= 2.0 * .pi }
            }
        } else {
            samples.append(contentsOf: [Float](repeating: 0, count: count))
        }
    }
    return samples
}

// MARK: - Recovery-aware scoring

/// Best CER against any word-boundary suffix of `expected` covering at
/// least `minFraction` of it. For cold-start tests: rewards a decoder
/// that catches on quickly without penalizing early catch, while a
/// decoder that stays deaf scores 0.
func suffixCER(expected: String, actual: String, minFraction: Double) -> Double {
    let words = expected.split(separator: " ").map(String.init)
    guard !words.isEmpty else { return actual.isEmpty ? 0 : 1 }
    var best = 1.0
    for start in 0..<words.count {
        let suffix = words[start...].joined(separator: " ")
        guard Double(suffix.count) >= minFraction * Double(expected.count) else { break }
        best = min(best, characterErrorRate(expected: suffix, actual: actual))
    }
    return best
}

// MARK: - Suite v2 categories

extension BenchmarkSuite {

    // MARK: Cold start (decoder starts while the signal is already up)

    mutating func runColdStartTests() {
        print("--- Cold Start (no silent preamble — the app's post-TX reality) ---")
        let text = "VVV VVV DE W1AW W1AW UR RST 599 599 NAME JOHN JOHN QTH CT CT HW CPY K"

        // Tone starts at sample zero: the 200 ms "noise" preamble is all signal.
        var mod1 = CWModulator(configuration: .standard)
        let hot = mod1.modulateText(text) + [Float](repeating: 0, count: Int(0.5 * 48000))
        let d1 = makeDecoder(configuration: .standard)
        d1.process(samples: hot)
        let cer1 = suffixCER(expected: text, actual: d1.decodedText, minFraction: 0.6)
        let r1 = TestResult(category: "cold_start", name: "tone_at_t0",
                            expected: text, decoded: d1.decodedText, cer: cer1, score: cerToScore(cer1))
        results.append(r1); printResult(r1)

        // Joining mid-transmission: feed from 40% into the audio.
        var mod2 = CWModulator(configuration: .standard)
        let full = mod2.modulateText(text) + [Float](repeating: 0, count: Int(0.5 * 48000))
        let cut = Array(full[(full.count * 4 / 10)...])
        let d2 = makeDecoder(configuration: .standard)
        d2.process(samples: cut)
        let cer2 = suffixCER(expected: text, actual: d2.decodedText, minFraction: 0.3)
        let r2 = TestResult(category: "cold_start", name: "join_mid_transmission",
                            expected: text, decoded: d2.decodedText, cer: cer2, score: cerToScore(cer2))
        results.append(r2); printResult(r2)

        // Same as tone_at_t0 but at 15 dB SNR.
        var rng = SeededRandom(seed: 4242)
        var mod3 = CWModulator(configuration: .standard)
        let noisy = addWhiteNoise(to: mod3.modulateText(text) + [Float](repeating: 0, count: Int(0.5 * 48000)),
                                  snrDB: 15, rng: &rng)
        let d3 = makeDecoder(configuration: .standard)
        d3.process(samples: noisy)
        let cer3 = suffixCER(expected: text, actual: d3.decodedText, minFraction: 0.6)
        let r3 = TestResult(category: "cold_start", name: "tone_at_t0_15dB",
                            expected: text, decoded: d3.decodedText, cer: cer3, score: cerToScore(cer3))
        results.append(r3); printResult(r3)

        print()
    }

    // MARK: QRN (impulse noise / static crashes)

    mutating func runQRNTests() {
        print("--- QRN Tests (impulsive static crashes) ---")
        let text = "CQ CQ DE W1AW K"

        let cases: [(name: String, rate: Double, amp: Float)] = [
            ("light_2s_5x", 2, 5),
            ("moderate_5s_10x", 5, 10),
            ("heavy_10s_20x", 10, 20),
        ]
        for (name, rate, amp) in cases {
            let result = runTest(
                category: "qrn", name: name,
                config: .standard, text: text,
                impairment: { samples in
                    var rng = SeededRandom(seed: 7100 + UInt64(rate * 10))
                    return addImpulseNoise(to: samples, burstsPerSecond: rate,
                                           relativeAmplitude: amp, sampleRate: 48000, rng: &rng)
                }
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: Continuous drift

    mutating func runDriftTests() {
        print("--- Continuous Drift Tests (unstable VFO) ---")
        let text = "CQ CQ DE W1AW W1AW UR RST 579 579 NAME BOB QTH BOSTON K"

        let preamble = [Float](repeating: 0, count: Int(0.3 * 48000))
        let postamble = [Float](repeating: 0, count: Int(0.5 * 48000))

        for (name, rate) in [("slow_0.5Hzs", 0.5), ("medium_2Hzs", 2.0), ("fast_5Hzs", 5.0)] {
            let samples = preamble + generateDriftingCW(text: text, config: .standard,
                                                        driftHzPerSecond: rate) + postamble
            let decoder = makeDecoder(configuration: .standard)
            decoder.process(samples: samples)
            let cer = characterErrorRate(expected: text, actual: decoder.decodedText)
            let r = TestResult(category: "drift", name: name,
                               expected: text, decoded: decoder.decodedText,
                               cer: cer, score: cerToScore(cer))
            results.append(r); printResult(r)
        }
        print()
    }

    // MARK: Straight-key swing

    mutating func runSwingTests() {
        print("--- Straight-Key / Bug Swing Tests (systematic fist bias) ---")
        let text = "CQ CQ DE W1AW K"

        let profiles: [(name: String, dit: Double, dah: Double, intra: Double, inter: Double)] = [
            ("bug_short_dahs", 1.05, 0.82, 0.85, 0.80),
            ("heavy_fist", 1.10, 1.20, 1.15, 1.30),
            ("compressed_gaps", 1.00, 1.00, 0.75, 0.65),
        ]
        for (name, dit, dah, intra, inter) in profiles {
            var rng = SeededRandom(seed: 5150 + UInt64(name.count))
            let preamble = [Float](repeating: 0, count: Int(0.3 * 48000))
            let postamble = [Float](repeating: 0, count: Int(0.5 * 48000))
            let samples = preamble + generateSwingCW(
                text: text, config: .standard,
                ditScale: dit, dahScale: dah,
                intraGapScale: intra, interGapScale: inter,
                jitter: 0.08, rng: &rng) + postamble
            let decoder = makeDecoder(configuration: .standard)
            decoder.process(samples: samples)
            let cer = characterErrorRate(expected: text, actual: decoder.decodedText)
            let r = TestResult(category: "swing", name: name,
                               expected: text, decoded: decoder.decodedText,
                               cer: cer, score: cerToScore(cer))
            results.append(r); printResult(r)
        }
        print()
    }

    // MARK: High-speed jitter (where block quantization binds)

    /// At 10 ms blocks, +/-1 block is 25-37% of a dit at 30-45 WPM — jitter
    /// on top of that quantization is what actually limits fast copy. The
    /// original jitter tests only ran at 20 WPM, where quantization is
    /// comfortable; these make the sub-block timing win measurable.
    mutating func runSpeedJitterTests() {
        print("--- High-Speed Jitter Tests ---")
        let text = "CQ CQ DE W1AW K"

        for (wpm, jitter) in [(30.0, 0.15), (35.0, 0.15), (40.0, 0.10)] {
            let config = CWConfiguration.standard.withWPM(wpm)
            var rng = SeededRandom(seed: 3100 + UInt64(wpm))
            let preSamples = Int(0.3 * config.sampleRate)
            let postSamples = Int(0.5 * config.sampleRate)
            var samples = [Float](repeating: 0, count: preSamples)
            samples.append(contentsOf: applyTimingJitter(to: text, config: config,
                                                         jitterFraction: jitter, rng: &rng))
            samples.append(contentsOf: [Float](repeating: 0, count: postSamples))

            let decoder = makeDecoder(configuration: config)
            decoder.process(samples: samples)
            let cer = characterErrorRate(expected: text, actual: decoder.decodedText)
            let r = TestResult(category: "speed_jitter",
                               name: "\(Int(wpm))wpm_\(Int(jitter * 100))pct",
                               expected: text, decoded: decoder.decodedText,
                               cer: cer, score: cerToScore(cer))
            results.append(r); printResult(r)
        }
        print()
    }

    // MARK: Farnsworth

    mutating func runFarnsworthTests() {
        print("--- Farnsworth Spacing Tests ---")
        let text = "CQ CQ DE W1AW K"

        for (name, charWPM, effWPM) in [("18c_8e", 18.0, 8.0), ("25c_12e", 25.0, 12.0)] {
            let preamble = [Float](repeating: 0, count: Int(0.3 * 48000))
            let postamble = [Float](repeating: 0, count: Int(0.5 * 48000))
            let samples = preamble + generateFarnsworthCW(
                text: text, characterWPM: charWPM, effectiveWPM: effWPM,
                config: .standard) + postamble
            // The decoder is configured near the character speed it must copy.
            let decoder = makeDecoder(configuration: CWConfiguration.standard.withWPM(charWPM))
            decoder.process(samples: samples)
            let cer = characterErrorRate(expected: text, actual: decoder.decodedText)
            let r = TestResult(category: "farnsworth", name: name,
                               expected: text, decoded: decoder.decodedText,
                               cer: cer, score: cerToScore(cer))
            results.append(r); printResult(r)
        }
        print()
    }

    // MARK: Tone frequency coverage

    mutating func runToneFrequencyTests() {
        print("--- Tone Frequency Tests (the suite otherwise only runs 700 Hz) ---")
        let text = "CQ CQ DE W1AW K"

        for tone in [450.0, 600.0, 900.0] {
            let config = CWConfiguration.standard.withToneFrequency(tone)
            let result = runTest(category: "tone_freq", name: "\(Int(tone))Hz",
                                 config: config, text: text)
            results.append(result)
            printResult(result)
        }

        // App-default 600 Hz under moderate noise.
        let config = CWConfiguration.standard.withToneFrequency(600)
        let result = runTest(
            category: "tone_freq", name: "600Hz_12dB",
            config: config, text: text,
            impairment: { samples in
                var rng = SeededRandom(seed: 6001)
                return addWhiteNoise(to: samples, snrDB: 12, rng: &rng)
            }
        )
        results.append(result)
        printResult(result)
        print()
    }

    // MARK: Long-duration false positives

    mutating func runLongFalsePositiveTest() {
        print("--- Long False Positive Test (30 s of band noise) ---")
        let decoder = makeDecoder(configuration: .standard)
        var rng = SeededRandom(seed: 54321)
        let chunk = 48000
        var totalChars = 0
        for _ in 0..<30 {
            var noise = [Float](repeating: 0, count: chunk)
            for i in 0..<chunk { noise[i] = Float(rng.nextGaussian()) * 0.1 }
            decoder.process(samples: noise)
        }
        // Spaces are invisible on an idle monitor (whitespace-only
        // segments never commit); count only visible junk characters.
        totalChars = decoder.decodedText.filter { $0 != " " }.count
        // 2 junk chars/minute is tolerable on a live monitor; 25+ is spam.
        let charsPerMinute = Double(totalChars) * 2.0
        let score = max(0.0, 100.0 - charsPerMinute * 4.0)
        let r = TestResult(category: "false_positive", name: "noise_30s",
                           expected: "", decoded: decoder.decodedText,
                           cer: totalChars == 0 ? 0 : 1, score: score)
        results.append(r); printResult(r)
        print()
    }

    // MARK: Acoustic false positives (idle iPhone-mic channel)

    /// Stationary Gaussian noise is the one thing a real idle channel
    /// never is. These scenarios model what the app's microphone hears
    /// when nobody is transmitting — impulsive room noise, slow level
    /// wander, and a fluctuating narrowband component near the decode
    /// tone — the conditions that produced sustained E/T junk in the
    /// field while noise_30s stayed clean.
    mutating func runAcousticFalsePositiveTests() {
        print("--- Acoustic False Positives (30 s idle mic, no signal) ---")
        let seconds = 30
        let n = 48000 * seconds

        // Impulsive room noise: broadband floor plus clicks and thumps
        // (20–200 ms decaying noise bursts, ~1.5/s, 10–25× the floor).
        var impulsive = [Float](repeating: 0, count: n)
        var rng1 = SeededRandom(seed: 7101)
        for i in 0..<n { impulsive[i] = Float(rng1.nextGaussian()) * 0.03 }
        let burstCount = Int(Double(seconds) * 1.5)
        for _ in 0..<burstCount {
            let pos = Int(rng1.nextDouble() * Double(n - 12000))
            let len = 960 + Int(rng1.nextDouble() * 8640)          // 20–200 ms
            let amp = Float(0.03 * (10.0 + rng1.nextDouble() * 15.0))
            for k in 0..<len {
                let decay = exp(-Float(k) / (Float(len) * 0.4))
                impulsive[pos + k] += amp * decay * Float(rng1.nextGaussian())
            }
        }
        scoreAcousticFP(name: "impulsive_room", samples: impulsive)

        // Level wander: the floor drifts ±10 dB over seconds (AGC
        // settling, a fan cycling, someone moving around the shack).
        // Stresses the noise-floor tracker's release time.
        var wander = [Float](repeating: 0, count: n)
        var rng2 = SeededRandom(seed: 7102)
        var levelDB = 0.0
        var target = 0.0
        for i in 0..<n {
            if i % 4800 == 0 {                                     // retarget 10×/s
                if rng2.nextDouble() < 0.05 { target = rng2.nextDouble() * 20.0 - 10.0 }
                levelDB += (target - levelDB) * 0.02
            }
            let level = 0.03 * pow(10.0, levelDB / 20.0)
            wander[i] = Float(rng2.nextGaussian() * level)
        }
        scoreAcousticFP(name: "level_wander", samples: wander)

        // Narrowband flutter at the decode tone: broadband floor plus
        // 700 Hz energy whose amplitude fluctuates slowly (mechanical
        // hum, resonance) — lands straight in the Goertzel bin and
        // gates on and off like keying.
        var hum = [Float](repeating: 0, count: n)
        var rng3 = SeededRandom(seed: 7103)
        var am = 0.0
        var phase = 0.0
        let phaseInc = 2.0 * .pi * 700.0 / 48000.0
        for i in 0..<n {
            if i % 480 == 0 {                                      // AM wanders at ~100 Hz update
                am = max(0, am * 0.98 + rng3.nextGaussian() * 0.02)
            }
            phase += phaseInc
            hum[i] = Float(rng3.nextGaussian()) * 0.03 + Float(sin(phase) * am * 0.15)
        }
        scoreAcousticFP(name: "tone_flutter", samples: hum)
        print()
    }

    private mutating func scoreAcousticFP(name: String, samples: [Float]) {
        let decoder = makeDecoder(configuration: .standard)
        if ProcessInfo.processInfo.environment["FP_DEBUG"] != nil,
           let classic = decoder as? ClassicDecoderWrapper {
            classic.demodulator.probationDebug = true
        }
        var i = 0
        while i < samples.count {                                  // app-sized buffers
            let end = min(i + 4096, samples.count)
            decoder.process(samples: Array(samples[i..<end]))
            i = end
        }
        let junk = decoder.decodedText.filter { $0 != " " }.count
        let charsPerMinute = Double(junk) * 60.0 / (Double(samples.count) / 48000.0)
        let score = max(0.0, 100.0 - charsPerMinute * 4.0)
        let r = TestResult(category: "false_positive", name: name,
                           expected: "", decoded: decoder.decodedText,
                           cer: junk == 0 ? 0 : 1, score: score)
        results.append(r); printResult(r)
    }

    // MARK: Chunked-feed parity

    mutating func runChunkedParityTests() {
        print("--- Chunked-Feed Parity (app-sized buffers vs one shot) ---")
        let text = "CQ CQ DE W1AW UR RST 599 K"
        var modulator = CWModulator(configuration: .standard)
        var samples = modulator.modulateTextWithEnvelope(text, preambleMs: 300, postambleMs: 500)
        var rng = SeededRandom(seed: 2323)
        samples = addWhiteNoise(to: samples, snrDB: 15, rng: &rng)

        let wholeDecoder = makeDecoder(configuration: .standard)
        wholeDecoder.process(samples: samples)
        let whole = wholeDecoder.decodedText

        let chunkedDecoder = makeDecoder(configuration: .standard)
        var i = 0
        while i < samples.count {
            let end = min(i + 4096, samples.count)
            chunkedDecoder.process(samples: Array(samples[i..<end]))
            i = end
        }
        let chunked = chunkedDecoder.decodedText

        let match = whole == chunked
        let cer = characterErrorRate(expected: whole, actual: chunked)
        let r = TestResult(category: "chunked_parity", name: "4096_vs_whole",
                           expected: whole, decoded: chunked,
                           cer: match ? 0 : cer, score: match ? 100 : cerToScore(cer))
        results.append(r); printResult(r)
        print()
    }

    // MARK: Callsign copy (the app's routing currency)

    mutating func runCallsignCopyTests() {
        print("--- Callsign Copy Tests (exact copy or the message is orphaned) ---")
        let calls = ["W1AW", "K1ABC", "DL1ABC", "JA1XYZ", "VK2DEF"]

        for (index, call) in calls.enumerated() {
            let text = "CQ CQ DE \(call) \(call) K"
            var modulator = CWModulator(configuration: .standard)
            var samples = modulator.modulateTextWithEnvelope(text, preambleMs: 300, postambleMs: 500)
            var rng = SeededRandom(seed: 8800 + UInt64(index))
            samples = addWhiteNoise(to: samples, snrDB: 12, rng: &rng)

            let decoder = makeDecoder(configuration: .standard)
            decoder.process(samples: samples)
            let decoded = decoder.decodedText
            let copied = decoded.contains(call)
            let cer = characterErrorRate(expected: text, actual: decoded)
            let r = TestResult(category: "callsign_copy", name: call,
                               expected: text, decoded: decoded,
                               cer: cer, score: copied ? 100 : 0)
            results.append(r); printResult(r)
        }
        print()
    }
}
