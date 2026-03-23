//
//  ModeDetectionTrainer — Data-Driven Classifier Tuning
//
//  Generates hundreds of test signals using the same modulators and impairments
//  as the RTTY, PSK, CW, and JS8Call benchmarks. Extracts spectral features
//  from each signal and computes per-mode statistics to derive optimal
//  classifier thresholds.
//
//  Run:  cd AmateurDigital/AmateurDigitalCore && swift run ModeDetectionTrainer
//        cd AmateurDigital/AmateurDigitalCore && swift run ModeDetectionTrainer --dump-csv
//

import Foundation
import AmateurDigitalCore

// MARK: - Seeded Random

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    mutating func nextDouble() -> Double {
        state ^= state >> 12; state ^= state << 25; state ^= state >> 27
        return Double(state &* 0x2545F4914F6CDD1D) / Double(UInt64.max)
    }
    mutating func nextGaussian() -> Double {
        let u1 = max(nextDouble(), 1e-10); let u2 = nextDouble()
        return sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
    }
}

// MARK: - Signal Impairments (same as existing benchmarks)

func addWhiteNoise(to signal: [Float], snrDB: Float, rng: inout SeededRandom) -> [Float] {
    let power = signal.map { $0 * $0 }.reduce(0, +) / max(1, Float(signal.count))
    let rms = sqrt(power)
    guard rms > 0 else { return signal }
    let noiseRMS = rms / pow(10.0, snrDB / 20.0)
    return signal.map { $0 + Float(rng.nextGaussian()) * noiseRMS }
}

func applyFrequencyOffset(to signal: [Float], offsetHz: Double, sampleRate: Double = 48000) -> [Float] {
    let phaseInc = 2.0 * .pi * offsetHz / sampleRate
    return (0..<signal.count).map { i in signal[i] * Float(cos(phaseInc * Double(i))) }
}

func applyFading(to signal: [Float], fadeRateHz: Double, fadeDepth: Float, sampleRate: Double = 48000) -> [Float] {
    let phaseInc = 2.0 * .pi * fadeRateHz / sampleRate
    return (0..<signal.count).map { i in
        let fade = 1.0 - fadeDepth * Float(1.0 + cos(phaseInc * Double(i))) / 2.0
        return signal[i] * fade
    }
}

// MARK: - Training Sample

struct TrainingSample {
    let mode: String         // "RTTY", "PSK31", "BPSK63", "QPSK31", "QPSK63", "CW", "JS8Call", "noise"
    let condition: String    // "clean", "snr20", "snr10", "snr5", "snr0", "offset+50", "fading", "itu-good", etc.
    let features: SpectralFeatures
    let detectedMode: String
    let detectedConfidence: Float
    let correct: Bool
    let noiseConfidence: Float
}

// MARK: - Signal Generators

let sampleRate: Double = 48000
let testText = "CQ CQ CQ DE W1AW W1AW PSE K"
let minSamples = Int(2.0 * sampleRate) // 2 seconds minimum

func padOrTrim(_ samples: [Float], to count: Int) -> [Float] {
    if samples.count >= count { return Array(samples.prefix(count)) }
    return samples + [Float](repeating: 0, count: count - samples.count)
}

func genRTTY(freq: Double = 2125, shift: Double = 170, baud: Double = 45.45) -> [Float] {
    let config = RTTYConfiguration(baudRate: baud, markFrequency: freq, shift: shift, sampleRate: sampleRate)
    let modem = RTTYModem(configuration: config)
    return padOrTrim(modem.encodeWithIdle(text: testText, preambleMs: 200, postambleMs: 200), to: minSamples)
}

func genPSK31(freq: Double = 1000) -> [Float] {
    var mod = PSKModulator.psk31(centerFrequency: freq)
    return padOrTrim(mod.modulateTextWithEnvelope(testText, preambleMs: 200, postambleMs: 200), to: minSamples)
}

func genBPSK63(freq: Double = 1000) -> [Float] {
    var mod = PSKModulator.bpsk63(centerFrequency: freq)
    return padOrTrim(mod.modulateTextWithEnvelope(testText, preambleMs: 200, postambleMs: 200), to: minSamples)
}

func genQPSK31(freq: Double = 1000) -> [Float] {
    var mod = PSKModulator.qpsk31(centerFrequency: freq)
    return padOrTrim(mod.modulateTextWithEnvelope(testText, preambleMs: 200, postambleMs: 200), to: minSamples)
}

func genQPSK63(freq: Double = 1000) -> [Float] {
    var mod = PSKModulator.qpsk63(centerFrequency: freq)
    return padOrTrim(mod.modulateTextWithEnvelope(testText, preambleMs: 200, postambleMs: 200), to: minSamples)
}

func genCW(freq: Double = 700, wpm: Double = 20) -> [Float] {
    var mod = CWModulator(configuration: CWConfiguration(
        toneFrequency: freq, wpm: wpm, sampleRate: sampleRate, riseTime: 0.005, dashDotRatio: 3.0))
    return padOrTrim(mod.modulateTextWithEnvelope(testText, preambleMs: 300, postambleMs: 300), to: minSamples)
}

func genJS8(freq: Double = 1000) -> [Float] {
    var mod = JS8CallModulator(configuration: JS8CallConfiguration(carrierFrequency: freq, sampleRate: sampleRate))
    return padOrTrim(mod.modulateTextWithEnvelope(testText, preambleMs: 100, postambleMs: 200), to: minSamples)
}

func genNoise(rng: inout SeededRandom) -> [Float] {
    (0..<minSamples).map { _ in Float(rng.nextGaussian()) * 0.1 }
}

func genPinkNoise(rng: inout SeededRandom, amplitude: Float = 0.1) -> [Float] {
    var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
    return (0..<minSamples).map { _ in
        let white = Float(rng.nextGaussian())
        b0 = 0.99886 * b0 + white * 0.0555179
        b1 = 0.99332 * b1 + white * 0.0750759
        b2 = 0.96900 * b2 + white * 0.1538520
        b3 = 0.86650 * b3 + white * 0.3104856
        b4 = 0.55000 * b4 + white * 0.5329522
        b5 = -0.7616 * b5 - white * 0.0168980
        let pink = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362
        b6 = white * 0.115926
        return pink * 0.05 * amplitude
    }
}

func genHum(amplitude: Float = 0.05) -> [Float] {
    let inc60 = 2.0 * .pi * 60.0 / sampleRate
    let inc120 = 2.0 * .pi * 120.0 / sampleRate
    let inc180 = 2.0 * .pi * 180.0 / sampleRate
    return (0..<minSamples).map { i in
        let d = Double(i)
        return amplitude * (Float(sin(inc60 * d)) + 0.5 * Float(sin(inc120 * d)) + 0.25 * Float(sin(inc180 * d)))
    }
}

func genAmbientNoise(rng: inout SeededRandom, level: Float = 1.0) -> [Float] {
    let pink = genPinkNoise(rng: &rng, amplitude: level)
    let hum = genHum(amplitude: 0.03 * level)
    let white = (0..<minSamples).map { _ in Float(rng.nextGaussian()) * 0.02 * level }
    return zip(zip(pink, hum), white).map { $0.0.0 + $0.0.1 + $0.1 }
}

func genSilence() -> [Float] {
    [Float](repeating: 0, count: minSamples)
}

func genTone(freq: Double) -> [Float] {
    let phaseInc = 2.0 * .pi * freq / sampleRate
    return (0..<minSamples).map { Float(sin(phaseInc * Double($0))) * 0.3 }
}

// MARK: - Generate All Training Data

func generateTrainingSet(rng: inout SeededRandom) -> [(mode: String, condition: String, samples: [Float])] {
    var set: [(String, String, [Float])] = []

    // --- RTTY ---
    // Clean at various frequencies
    for freq in [1000.0, 1500.0, 2125.0, 2500.0, 3000.0] {
        set.append(("RTTY", "clean-\(Int(freq))Hz", genRTTY(freq: freq)))
    }
    // Different baud rates
    for baud in [45.45, 50.0, 75.0] {
        set.append(("RTTY", "baud-\(Int(baud))", genRTTY(baud: baud)))
    }
    // Non-standard shifts
    for shift in [200.0, 425.0, 850.0] {
        set.append(("RTTY", "shift-\(Int(shift))", genRTTY(shift: shift)))
    }
    // Noise sweep
    for snr: Float in [30, 20, 15, 10, 5, 3, 0, -3] {
        set.append(("RTTY", "snr\(Int(snr))", addWhiteNoise(to: genRTTY(), snrDB: snr, rng: &rng)))
    }
    // Frequency offset
    for offset in [50.0, 100.0, -75.0] {
        set.append(("RTTY", "offset\(Int(offset))Hz", applyFrequencyOffset(to: genRTTY(), offsetHz: offset)))
    }
    // Fading
    set.append(("RTTY", "fading-slow", applyFading(to: genRTTY(), fadeRateHz: 0.5, fadeDepth: 0.5)))
    set.append(("RTTY", "fading-fast", applyFading(to: genRTTY(), fadeRateHz: 2.0, fadeDepth: 0.5)))
    // ITU channels
    for (name, spread, delay) in [("good", 0.1, 0.0005), ("moderate", 0.5, 0.001), ("poor", 1.0, 0.002)] {
        var ch = WattersonChannel(dopplerSpread: spread, pathDelay: delay, sampleRate: sampleRate)
        let impaired = ch.process(genRTTY())
        set.append(("RTTY", "itu-\(name)", addWhiteNoise(to: impaired, snrDB: 10, rng: &rng)))
    }

    // --- PSK31 ---
    for freq in [800.0, 1000.0, 1500.0, 2000.0] {
        set.append(("PSK31", "clean-\(Int(freq))Hz", genPSK31(freq: freq)))
    }
    for snr: Float in [30, 20, 15, 10, 5, 0] {
        set.append(("PSK31", "snr\(Int(snr))", addWhiteNoise(to: genPSK31(), snrDB: snr, rng: &rng)))
    }
    for offset in [5.0, 10.0, -10.0] {
        set.append(("PSK31", "offset\(Int(offset))Hz", applyFrequencyOffset(to: genPSK31(), offsetHz: offset)))
    }
    set.append(("PSK31", "fading", applyFading(to: genPSK31(), fadeRateHz: 0.5, fadeDepth: 0.5)))
    for (name, spread, delay) in [("good", 0.1, 0.0005), ("moderate", 0.5, 0.001), ("poor", 1.0, 0.002)] {
        var ch = WattersonChannel(dopplerSpread: spread, pathDelay: delay, sampleRate: sampleRate)
        set.append(("PSK31", "itu-\(name)", addWhiteNoise(to: ch.process(genPSK31()), snrDB: 10, rng: &rng)))
    }

    // --- BPSK63 ---
    for freq in [1000.0, 1500.0] {
        set.append(("BPSK63", "clean-\(Int(freq))Hz", genBPSK63(freq: freq)))
    }
    for snr: Float in [20, 10, 5] {
        set.append(("BPSK63", "snr\(Int(snr))", addWhiteNoise(to: genBPSK63(), snrDB: snr, rng: &rng)))
    }

    // --- QPSK31 ---
    set.append(("QPSK31", "clean", genQPSK31()))
    for snr: Float in [20, 10] {
        set.append(("QPSK31", "snr\(Int(snr))", addWhiteNoise(to: genQPSK31(), snrDB: snr, rng: &rng)))
    }

    // --- QPSK63 ---
    set.append(("QPSK63", "clean", genQPSK63()))
    for snr: Float in [20, 10] {
        set.append(("QPSK63", "snr\(Int(snr))", addWhiteNoise(to: genQPSK63(), snrDB: snr, rng: &rng)))
    }

    // --- CW ---
    for freq in [500.0, 600.0, 700.0, 800.0, 1000.0] {
        set.append(("CW", "clean-\(Int(freq))Hz", genCW(freq: freq)))
    }
    for wpm in [10.0, 13.0, 20.0, 25.0, 30.0, 40.0] {
        set.append(("CW", "wpm\(Int(wpm))", genCW(wpm: wpm)))
    }
    for snr: Float in [30, 20, 15, 10, 5, 0, -3] {
        set.append(("CW", "snr\(Int(snr))", addWhiteNoise(to: genCW(), snrDB: snr, rng: &rng)))
    }
    for offset in [50.0, 100.0, -75.0] {
        set.append(("CW", "offset\(Int(offset))Hz", applyFrequencyOffset(to: genCW(), offsetHz: offset)))
    }
    set.append(("CW", "fading", applyFading(to: genCW(), fadeRateHz: 1.0, fadeDepth: 0.5)))
    for (name, spread, delay) in [("good", 0.1, 0.0005), ("moderate", 0.5, 0.001), ("poor", 1.0, 0.002)] {
        var ch = WattersonChannel(dopplerSpread: spread, pathDelay: delay, sampleRate: sampleRate)
        set.append(("CW", "itu-\(name)", addWhiteNoise(to: ch.process(genCW()), snrDB: 10, rng: &rng)))
    }

    // --- JS8Call ---
    for freq in [1000.0, 1500.0, 2000.0] {
        set.append(("JS8Call", "clean-\(Int(freq))Hz", genJS8(freq: freq)))
    }
    for snr: Float in [20, 10, 5, 0] {
        set.append(("JS8Call", "snr\(Int(snr))", addWhiteNoise(to: genJS8(), snrDB: snr, rng: &rng)))
    }

    // --- Noise / No Signal ---
    set.append(("noise", "silence", genSilence()))
    for i in 0..<5 {
        var localRng = SeededRandom(seed: UInt64(100 + i))
        set.append(("noise", "white-noise-\(i)", genNoise(rng: &localRng)))
    }
    // Faint noise
    for i in 0..<3 {
        var localRng = SeededRandom(seed: UInt64(200 + i))
        set.append(("noise", "faint-noise-\(i)", genNoise(rng: &localRng).map { $0 * 0.01 }))
    }
    // Continuous tones (should be noise-like, not PSK31)
    for freq in [700.0, 1000.0, 1500.0] {
        set.append(("noise", "tone-\(Int(freq))Hz", genTone(freq: freq)))
    }
    // Tone in noise (still should be noise — unmodulated carrier + noise)
    for snr: Float in [20, 10] {
        set.append(("noise", "tone+noise-\(Int(snr))dB", addWhiteNoise(to: genTone(freq: 1000), snrDB: snr, rng: &rng)))
    }

    // --- Cross-mode confusion tests ---
    // RTTY at PSK31 frequency (should still be RTTY)
    set.append(("RTTY", "at-psk-freq", genRTTY(freq: 1085)))
    // PSK31 at RTTY frequency (should still be PSK31)
    set.append(("PSK31", "at-rtty-freq", genPSK31(freq: 2125)))
    // CW at PSK frequency (should still be CW)
    set.append(("CW", "at-psk-freq-1000", genCW(freq: 1000)))
    // CW at RTTY frequency (should still be CW)
    set.append(("CW", "at-rtty-freq-2125", genCW(freq: 2125)))

    // --- Combined impairments ---
    // RTTY with noise + fading
    set.append(("RTTY", "noise+fade", applyFading(to: addWhiteNoise(to: genRTTY(), snrDB: 10, rng: &rng), fadeRateHz: 0.5, fadeDepth: 0.3)))
    // PSK31 with noise + fading
    set.append(("PSK31", "noise+fade", applyFading(to: addWhiteNoise(to: genPSK31(), snrDB: 10, rng: &rng), fadeRateHz: 0.5, fadeDepth: 0.3)))
    // CW with noise + fading
    set.append(("CW", "noise+fade", applyFading(to: addWhiteNoise(to: genCW(), snrDB: 10, rng: &rng), fadeRateHz: 0.5, fadeDepth: 0.3)))
    // CW fast (40 WPM) + noise
    set.append(("CW", "fast-noisy", addWhiteNoise(to: genCW(wpm: 40), snrDB: 10, rng: &rng)))
    // CW slow (10 WPM) + noise
    set.append(("CW", "slow-noisy", addWhiteNoise(to: genCW(wpm: 10), snrDB: 10, rng: &rng)))

    // --- BPSK63 and QPSK with noise (known hard cases) ---
    set.append(("BPSK63", "snr3", addWhiteNoise(to: genBPSK63(), snrDB: 3, rng: &rng)))
    set.append(("BPSK63", "snr0", addWhiteNoise(to: genBPSK63(), snrDB: 0, rng: &rng)))
    set.append(("QPSK31", "snr5", addWhiteNoise(to: genQPSK31(), snrDB: 5, rng: &rng)))
    set.append(("QPSK63", "snr5", addWhiteNoise(to: genQPSK63(), snrDB: 5, rng: &rng)))
    set.append(("QPSK63", "snr0", addWhiteNoise(to: genQPSK63(), snrDB: 0, rng: &rng)))

    // --- JS8Call edge cases ---
    set.append(("JS8Call", "fading", applyFading(to: genJS8(), fadeRateHz: 0.5, fadeDepth: 0.5)))
    set.append(("JS8Call", "snr-3", addWhiteNoise(to: genJS8(), snrDB: -3, rng: &rng)))
    for (name, spread, delay) in [("good", 0.1, 0.0005), ("moderate", 0.5, 0.001)] {
        var ch = WattersonChannel(dopplerSpread: spread, pathDelay: delay, sampleRate: sampleRate)
        set.append(("JS8Call", "itu-\(name)", addWhiteNoise(to: ch.process(genJS8()), snrDB: 10, rng: &rng)))
    }

    // --- Noise edge cases ---
    // Two tones (not FSK — just two unrelated tones)
    let twoTone = zip(genTone(freq: 800), genTone(freq: 1200)).map { $0.0 + $0.1 }
    set.append(("noise", "two-tones", twoTone))
    // Broadband hiss (very weak)
    var hissRng = SeededRandom(seed: 999)
    set.append(("noise", "hiss", genNoise(rng: &hissRng).map { $0 * 0.005 }))

    // Realistic ambient mic noise — what a silent room sounds like
    var ambRng1 = SeededRandom(seed: 500)
    set.append(("noise", "ambient-quiet", genAmbientNoise(rng: &ambRng1, level: 0.3)))
    var ambRng2 = SeededRandom(seed: 501)
    set.append(("noise", "ambient-normal", genAmbientNoise(rng: &ambRng2, level: 1.0)))
    var ambRng3 = SeededRandom(seed: 502)
    set.append(("noise", "ambient-loud", genAmbientNoise(rng: &ambRng3, level: 3.0)))
    // 60 Hz hum (unshielded cable)
    set.append(("noise", "hum-60Hz", genHum(amplitude: 0.05)))
    set.append(("noise", "hum-60Hz-strong", genHum(amplitude: 0.15)))
    // Pink noise
    var pinkRng = SeededRandom(seed: 600)
    set.append(("noise", "pink", genPinkNoise(rng: &pinkRng, amplitude: 1.0)))

    // --- Hard combined impairments ---
    // Signal in ambient noise (realistic: signal + room noise, not just white noise)
    set.append(("RTTY", "in-ambient", {
        var r = rng
        let sig = genRTTY()
        let amb = genAmbientNoise(rng: &r, level: 0.5)
        return zip(sig, amb).map { $0.0 * 0.3 + $0.1 }
    }()))
    set.append(("PSK31", "in-ambient", {
        var r = rng
        let sig = genPSK31()
        let amb = genAmbientNoise(rng: &r, level: 0.5)
        return zip(sig, amb).map { $0.0 * 0.3 + $0.1 }
    }()))
    set.append(("CW", "in-ambient", {
        var r = rng
        let sig = genCW()
        let amb = genAmbientNoise(rng: &r, level: 0.5)
        return zip(sig, amb).map { $0.0 * 0.3 + $0.1 }
    }()))
    set.append(("JS8Call", "in-ambient", {
        var r = rng
        let sig = genJS8()
        let amb = genAmbientNoise(rng: &r, level: 0.5)
        return zip(sig, amb).map { $0.0 * 0.3 + $0.1 }
    }()))

    // Triple impairment: noise + fading + frequency offset
    set.append(("RTTY", "triple", applyFrequencyOffset(to: applyFading(to: addWhiteNoise(to: genRTTY(), snrDB: 8, rng: &rng), fadeRateHz: 1.0, fadeDepth: 0.4), offsetHz: 30)))
    set.append(("PSK31", "triple", applyFrequencyOffset(to: applyFading(to: addWhiteNoise(to: genPSK31(), snrDB: 8, rng: &rng), fadeRateHz: 1.0, fadeDepth: 0.4), offsetHz: 5)))
    set.append(("CW", "triple", applyFrequencyOffset(to: applyFading(to: addWhiteNoise(to: genCW(), snrDB: 8, rng: &rng), fadeRateHz: 1.0, fadeDepth: 0.4), offsetHz: 30)))

    // ITU channels for ALL modes (not just RTTY/PSK/CW)
    for (name, spread, delay) in [("good", 0.1, 0.0005), ("poor", 1.0, 0.002)] {
        var ch1 = WattersonChannel(dopplerSpread: spread, pathDelay: delay, sampleRate: sampleRate)
        set.append(("BPSK63", "itu-\(name)", addWhiteNoise(to: ch1.process(genBPSK63()), snrDB: 10, rng: &rng)))
        var ch2 = WattersonChannel(dopplerSpread: spread, pathDelay: delay, sampleRate: sampleRate)
        set.append(("QPSK31", "itu-\(name)", addWhiteNoise(to: ch2.process(genQPSK31()), snrDB: 10, rng: &rng)))
        var ch3 = WattersonChannel(dopplerSpread: spread, pathDelay: delay, sampleRate: sampleRate)
        set.append(("QPSK63", "itu-\(name)", addWhiteNoise(to: ch3.process(genQPSK63()), snrDB: 10, rng: &rng)))
    }

    // Very weak signals (at detection threshold)
    set.append(("RTTY", "snr-6", addWhiteNoise(to: genRTTY(), snrDB: -6, rng: &rng)))
    set.append(("CW", "snr-6", addWhiteNoise(to: genCW(), snrDB: -6, rng: &rng)))
    set.append(("JS8Call", "snr-6", addWhiteNoise(to: genJS8(), snrDB: -6, rng: &rng)))

    // Different CW speeds in noise
    set.append(("CW", "5wpm-noisy", addWhiteNoise(to: genCW(wpm: 5), snrDB: 10, rng: &rng)))
    set.append(("CW", "45wpm-noisy", addWhiteNoise(to: genCW(wpm: 45), snrDB: 10, rng: &rng)))

    // --- Adjacent channel interference ---
    // RTTY with a PSK31 signal nearby (common on HF)
    set.append(("RTTY", "adj-psk", {
        let rtty = genRTTY()
        var pskMod = PSKModulator.psk31(centerFrequency: 1500)
        let psk = padOrTrim(pskMod.modulateTextWithEnvelope("TEST DE W1XX K", preambleMs: 100, postambleMs: 100), to: minSamples)
        return zip(rtty, psk).map { $0.0 + $0.1 * 0.3 } // PSK at -10 dB relative
    }()))

    // PSK31 with a CW signal nearby
    set.append(("PSK31", "adj-cw", {
        let psk = genPSK31()
        var cwMod = CWModulator(configuration: CWConfiguration(toneFrequency: 800, wpm: 20, sampleRate: sampleRate, riseTime: 0.005, dashDotRatio: 3.0))
        let cw = padOrTrim(cwMod.modulateTextWithEnvelope("TEST", preambleMs: 100, postambleMs: 100), to: minSamples)
        return zip(psk, cw).map { $0.0 + $0.1 * 0.5 }
    }()))

    // --- Modes with pink noise background (more realistic than white noise) ---
    set.append(("RTTY", "pink-noise-bg", {
        var r = rng
        let sig = genRTTY()
        let pink = genPinkNoise(rng: &r, amplitude: 2.0)
        return zip(sig, pink).map { $0.0 * 0.5 + $0.1 }
    }()))
    set.append(("CW", "pink-noise-bg", {
        var r = rng
        let sig = genCW()
        let pink = genPinkNoise(rng: &r, amplitude: 2.0)
        return zip(sig, pink).map { $0.0 * 0.5 + $0.1 }
    }()))
    set.append(("PSK31", "pink-noise-bg", {
        var r = rng
        let sig = genPSK31()
        let pink = genPinkNoise(rng: &r, amplitude: 2.0)
        return zip(sig, pink).map { $0.0 * 0.5 + $0.1 }
    }()))

    // --- Disturbed ITU channel (worst case propagation) ---
    for mode in ["RTTY", "CW", "PSK31"] as [String] {
        var ch = WattersonChannel(dopplerSpread: 2.5, pathDelay: 0.005, sampleRate: sampleRate)
        let sig: [Float]
        switch mode {
        case "RTTY": sig = ch.process(genRTTY())
        case "CW": sig = ch.process(genCW())
        default: sig = ch.process(genPSK31())
        }
        set.append((mode, "itu-disturbed", addWhiteNoise(to: sig, snrDB: 10, rng: &rng)))
    }

    // --- Variable duration tests (3 seconds instead of 2) ---
    // The benchmark uses 3s clips; the trainer uses 2s. Test that classification
    // is robust to trailing silence from longer clips.
    let longSamples = Int(3.0 * sampleRate)
    func padLong(_ s: [Float]) -> [Float] { padOrTrim(s, to: longSamples) }

    set.append(("RTTY", "3sec", padLong(genRTTY())))
    set.append(("PSK31", "3sec", padLong(genPSK31())))
    set.append(("CW", "3sec", padLong(genCW())))
    set.append(("JS8Call", "3sec-clean", padLong(genJS8())))
    // 3-second JS8Call at various SNR — matches official benchmark pattern
    for snr: Float in [20, 10, 5] {
        set.append(("JS8Call", "3sec-snr\(Int(snr))", addWhiteNoise(to: padLong(genJS8()), snrDB: snr, rng: &rng)))
    }
    // 3-second QPSK63 with noise
    set.append(("QPSK63", "3sec-snr20", addWhiteNoise(to: padLong(genQPSK63()), snrDB: 20, rng: &rng)))
    set.append(("BPSK63", "3sec", padLong(genBPSK63())))
    set.append(("noise", "3sec-ambient", {
        var r = rng
        return padOrTrim(genAmbientNoise(rng: &r, level: 1.0), to: longSamples)
    }()))

    // --- Short duration tests (1 second) ---
    let shortSamples = Int(1.0 * sampleRate)
    func padShort(_ s: [Float]) -> [Float] { padOrTrim(s, to: shortSamples) }

    set.append(("RTTY", "1sec", padShort(genRTTY())))
    set.append(("PSK31", "1sec", padShort(genPSK31())))
    set.append(("CW", "1sec", padShort(genCW())))
    set.append(("JS8Call", "1sec", padShort(genJS8())))

    // --- Edge of audio passband ---
    set.append(("RTTY", "low-freq-500", genRTTY(freq: 500)))
    set.append(("PSK31", "low-freq-300", genPSK31(freq: 300)))
    set.append(("CW", "low-freq-400", genCW(freq: 400)))
    set.append(("RTTY", "high-freq-2800", genRTTY(freq: 2800)))
    set.append(("PSK31", "high-freq-2500", genPSK31(freq: 2500)))
    set.append(("CW", "high-freq-2000", genCW(freq: 2000)))

    // --- DC offset (cheap USB soundcards) ---
    set.append(("RTTY", "dc-offset", genRTTY().map { $0 + 0.05 }))
    set.append(("PSK31", "dc-offset", genPSK31().map { $0 + 0.05 }))
    set.append(("CW", "dc-offset", genCW().map { $0 + 0.05 }))

    // --- AGC pumping: signal appears halfway through the clip ---
    set.append(("RTTY", "late-start", {
        let sig = genRTTY()
        let half = sig.count / 2
        var result = [Float](repeating: 0, count: sig.count)
        for i in half..<sig.count { result[i] = sig[i - half] }
        return result
    }()))
    set.append(("CW", "late-start", {
        let sig = genCW()
        let half = sig.count / 2
        var result = [Float](repeating: 0, count: sig.count)
        for i in half..<sig.count { result[i] = sig[i - half] }
        return result
    }()))

    // --- Two signals at different frequencies (dominant mode wins) ---
    set.append(("RTTY", "with-psk-bg", {
        let rtty = genRTTY()
        var pskMod = PSKModulator.psk31(centerFrequency: 2500)
        let psk = padOrTrim(pskMod.modulateTextWithEnvelope("TEST", preambleMs: 100, postambleMs: 100), to: minSamples)
        return zip(rtty, psk).map { $0.0 + $0.1 * 0.15 } // PSK at -16 dB relative
    }()))
    set.append(("CW", "with-rtty-bg", {
        let cw = genCW()
        let config = RTTYConfiguration(baudRate: 45.45, markFrequency: 2125, shift: 170, sampleRate: sampleRate)
        let modem = RTTYModem(configuration: config)
        let rtty = padOrTrim(modem.encodeWithIdle(text: "RYRY", preambleMs: 100, postambleMs: 100), to: minSamples)
        return zip(cw, rtty).map { $0.0 + $0.1 * 0.15 }
    }()))

    // --- Stress tests: mode confusion pairs ---
    // CW vs PSK31 at similar frequencies (both narrow single peaks)
    set.append(("CW", "at-1000Hz-noisy", addWhiteNoise(to: genCW(freq: 1000), snrDB: 8, rng: &rng)))
    set.append(("PSK31", "at-700Hz-noisy", addWhiteNoise(to: genPSK31(freq: 700), snrDB: 8, rng: &rng)))

    // RTTY at non-standard 200 Hz shift with noise (confusable with wideband PSK)
    set.append(("RTTY", "200shift-noisy", addWhiteNoise(to: genRTTY(shift: 200), snrDB: 10, rng: &rng)))
    set.append(("RTTY", "425shift-noisy", addWhiteNoise(to: genRTTY(shift: 425), snrDB: 10, rng: &rng)))

    // BPSK63 vs QPSK63 — spectrally identical, baud rate is the discriminator
    set.append(("BPSK63", "snr8", addWhiteNoise(to: genBPSK63(), snrDB: 8, rng: &rng)))
    set.append(("QPSK63", "snr8", addWhiteNoise(to: genQPSK63(), snrDB: 8, rng: &rng)))

    // CW at extreme speeds in noise
    set.append(("CW", "5wpm-snr5", addWhiteNoise(to: genCW(wpm: 5), snrDB: 5, rng: &rng)))
    set.append(("CW", "45wpm-snr5", addWhiteNoise(to: genCW(wpm: 45), snrDB: 5, rng: &rng)))

    // JS8Call through all ITU channels
    for (name, spread, delay) in [("poor", 1.0, 0.002), ("disturbed", 2.5, 0.005)] as [(String, Double, Double)] {
        var ch = WattersonChannel(dopplerSpread: spread, pathDelay: delay, sampleRate: sampleRate)
        set.append(("JS8Call", "itu-\(name)", addWhiteNoise(to: ch.process(genJS8()), snrDB: 10, rng: &rng)))
    }

    // All modes at exactly 3 dB SNR (marginal detection threshold)
    for (mode, gen) in [("RTTY", genRTTY()), ("PSK31", genPSK31()), ("CW", genCW()), ("JS8Call", genJS8())] as [(String, [Float])] {
        set.append((mode, "snr3-marginal", addWhiteNoise(to: gen, snrDB: 3, rng: &rng)))
    }

    // --- Amplitude/gain variation (real soundcards have different levels) ---
    // Very quiet signal (-30 dB, barely above quantization noise)
    set.append(("RTTY", "quiet", genRTTY().map { $0 * 0.03 }))
    set.append(("PSK31", "quiet", genPSK31().map { $0 * 0.03 }))
    set.append(("CW", "quiet", genCW().map { $0 * 0.03 }))
    // Very loud signal (near clipping)
    set.append(("RTTY", "loud", genRTTY().map { min(0.99, max(-0.99, $0 * 3.0)) }))
    set.append(("PSK31", "loud", genPSK31().map { min(0.99, max(-0.99, $0 * 3.0)) }))
    set.append(("CW", "loud", genCW().map { min(0.99, max(-0.99, $0 * 3.0)) }))
    // Clipped signal (hard clipping at ±0.5 — overdriven soundcard)
    set.append(("RTTY", "clipped", genRTTY().map { min(0.5, max(-0.5, $0)) }))
    set.append(("CW", "clipped", genCW().map { min(0.5, max(-0.5, $0)) }))

    // --- Rapid gain change mid-signal (AGC recovery) ---
    set.append(("RTTY", "agc-step", {
        var sig = genRTTY()
        let mid = sig.count / 2
        for i in 0..<mid { sig[i] *= 0.1 } // quiet first half
        return sig
    }()))
    set.append(("CW", "agc-step", {
        var sig = genCW()
        let mid = sig.count / 2
        for i in 0..<mid { sig[i] *= 0.1 }
        return sig
    }()))

    // --- Real-world WAV samples (if available) ---
    let sampleDir = "/Users/asm/d/Amateur-Digital/research/samples"
    let realSamples: [(file: String, expectedMode: String)] = [
        ("rtty-1-faint.wav", "RTTY"),
        ("rtty-2-strong-with-noise.wav", "RTTY"),
        ("rtty-3-strong.wav", "RTTY"),
        ("rtty-5.wav", "RTTY"),
        ("psk31-2-very-faint.wav", "PSK31"),
    ]

    for (file, mode) in realSamples {
        let path = "\(sampleDir)/\(file)"
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              data.count > 44 else { continue }

        // Read WAV
        let bitsPerSample = Int(data[34..<36].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
        guard bitsPerSample == 16 else { continue }

        // Find data chunk
        var dataOffset = 12
        while dataOffset + 8 < data.count {
            let chunkID = String(data: data[dataOffset..<dataOffset+4], encoding: .ascii) ?? ""
            let chunkSize = Int(data[dataOffset+4..<dataOffset+8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
            if chunkID == "data" { dataOffset += 8; break }
            dataOffset += 8 + chunkSize
        }

        let bytesPerSample = bitsPerSample / 8
        let totalSamples = (data.count - dataOffset) / bytesPerSample
        guard totalSamples > minSamples else { continue }

        // Take a 2-second chunk from the middle (skip start/end)
        let startSample = min(totalSamples / 4, totalSamples - minSamples)
        var wavSamples = [Float](repeating: 0, count: minSamples)
        for i in 0..<minSamples {
            let offset = dataOffset + (startSample + i) * bytesPerSample
            guard offset + 1 < data.count else { break }
            let v = data[offset..<offset+2].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
            wavSamples[i] = Float(v) / 32768.0
        }

        let basename = file.replacingOccurrences(of: ".wav", with: "")
        set.append((mode, "real-\(basename)", wavSamples))
    }

    // SDR corpus samples disabled — the current recordings aren't reliable enough
    // for training. Waiting for properly verified recordings with confirmed signals.
    // The ClassifierConfig + Optuna infrastructure is ready for when good data arrives.

    return set
}

// MARK: - Feature Statistics

struct FeatureStats {
    var count: Int = 0
    var occupiedBW: [Float] = []
    var spectralFlatness: [Float] = []
    var peakCount: [Int] = []
    var topPeakPower: [Float] = []
    var topPeakBW: [Float] = []
    var fskPairCount: [Int] = []
    var fskPairsWithValley: [Int] = []
    var envelopeCV: [Float] = []
    var dutyCycle: [Float] = []
    var transitionRate: [Float] = []
    var hasOOK: [Bool] = []
    // Classification accuracy
    var correctCount: Int = 0

    mutating func add(features f: SpectralFeatures, correct: Bool) {
        count += 1
        occupiedBW.append(Float(f.occupiedBandwidth))
        spectralFlatness.append(f.spectralFlatness)
        peakCount.append(f.peaks.count)
        topPeakPower.append(f.peaks.first?.powerAboveNoise ?? 0)
        topPeakBW.append(Float(f.peaks.first?.bandwidth3dB ?? 0))
        fskPairCount.append(f.fskPairs.count)
        fskPairsWithValley.append(f.fskPairs.filter { $0.hasValley }.count)
        envelopeCV.append(f.envelopeStats.coefficientOfVariation)
        dutyCycle.append(f.envelopeStats.dutyCycle)
        transitionRate.append(f.envelopeStats.transitionRate)
        hasOOK.append(f.envelopeStats.hasOnOffKeying)
        if correct { correctCount += 1 }
    }

    func median(_ arr: [Float]) -> Float {
        let sorted = arr.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }
    func mean(_ arr: [Float]) -> Float {
        arr.isEmpty ? 0 : arr.reduce(0, +) / Float(arr.count)
    }
    func pct(_ arr: [Float], _ p: Double) -> Float {
        let sorted = arr.sorted()
        guard !sorted.isEmpty else { return 0 }
        let idx = min(Int(Double(sorted.count) * p), sorted.count - 1)
        return sorted[idx]
    }

    func summary() -> String {
        let accuracy = count > 0 ? Int(Double(correctCount) / Double(count) * 100) : 0
        let ookPct = hasOOK.isEmpty ? 0 : Int(Double(hasOOK.filter { $0 }.count) / Double(hasOOK.count) * 100)
        return """
          Accuracy: \(accuracy)% (\(correctCount)/\(count))
          BW:       median=\(Int(median(occupiedBW))) p10=\(Int(pct(occupiedBW, 0.1))) p90=\(Int(pct(occupiedBW, 0.9)))
          Flatness: median=\(String(format:"%.3f",median(spectralFlatness))) p90=\(String(format:"%.3f",pct(spectralFlatness, 0.9)))
          Peaks:    median=\(median(peakCount.map{Float($0)})) topPower=\(String(format:"%.0f",median(topPeakPower)))dB topBW=\(String(format:"%.0f",median(topPeakBW)))Hz
          FSK:      pairs=\(String(format:"%.1f",mean(fskPairCount.map{Float($0)}))) withValley=\(String(format:"%.1f",mean(fskPairsWithValley.map{Float($0)})))
          Envelope: CV=\(String(format:"%.2f",median(envelopeCV))) duty=\(String(format:"%.0f",median(dutyCycle)*100))% transitions=\(String(format:"%.0f",median(transitionRate)))/s OOK=\(ookPct)%
        """
    }
}

// MARK: - Main

let dumpCSV = CommandLine.arguments.contains("--dump-csv")

print("Mode Detection Trainer")
print(String(repeating: "=", count: 70))
print()

var rng = SeededRandom(seed: 42)
let trainingSet = generateTrainingSet(rng: &rng)
print("Generated \(trainingSet.count) training signals")
print()

let detector = ModeDetector(sampleRate: sampleRate)
var statsByMode: [String: FeatureStats] = [:]
var samples: [TrainingSample] = []

// Acceptable mode families for accuracy computation
let pskFamily: Set<String> = ["PSK31", "BPSK63", "QPSK31", "QPSK63"]

for (mode, condition, audio) in trainingSet {
    let result = detector.detect(samples: audio)
    let detected = result.bestMatch?.mode.rawValue ?? "none"
    let confidence = result.bestMatch?.confidence ?? 0
    let noiseConf = result.noiseScore.confidence

    // Determine if classification is correct
    let correct: Bool
    if mode == "noise" {
        // For noise, correct if noise confidence > best mode confidence
        correct = noiseConf > confidence || !result.signalDetected
    } else if pskFamily.contains(mode) {
        // PSK family: accept any PSK mode as correct
        correct = pskFamily.contains(detected)
    } else if mode == "FT8" || mode == "JS8Call" {
        // FT8 and JS8Call are spectrally identical — accept either
        correct = detected == "FT8" || detected == "JS8Call"
    } else {
        correct = detected == mode
    }

    let sample = TrainingSample(
        mode: mode, condition: condition,
        features: result.features,
        detectedMode: detected,
        detectedConfidence: confidence,
        correct: correct,
        noiseConfidence: noiseConf
    )
    samples.append(sample)

    statsByMode[mode, default: FeatureStats()].add(features: result.features, correct: correct)
}

// Print per-mode statistics
print("Per-Mode Feature Statistics")
print(String(repeating: "-", count: 70))

let modeOrder = ["RTTY", "PSK31", "BPSK63", "QPSK31", "QPSK63", "CW", "JS8Call", "FT8", "noise"]
for mode in modeOrder {
    guard let stats = statsByMode[mode] else { continue }
    print("\n  \(mode) (\(stats.count) samples):")
    print(stats.summary())
}

// Print confusion summary
print()
print("Classification Results")
print(String(repeating: "-", count: 70))

var totalCorrect = 0
var totalCount = 0
for mode in modeOrder {
    guard let stats = statsByMode[mode] else { continue }
    totalCorrect += stats.correctCount
    totalCount += stats.count
    let pct = stats.count > 0 ? Int(Double(stats.correctCount) / Double(stats.count) * 100) : 0
    let icon = pct == 100 ? "OK" : pct >= 70 ? ".." : "XX"
    print("  [\(icon)] \(mode.padding(toLength: 8, withPad: " ", startingAt: 0)) \(stats.correctCount)/\(stats.count) (\(pct)%)")
}
let overallPct = totalCount > 0 ? Int(Double(totalCorrect) / Double(totalCount) * 100) : 0
print("\n  Overall: \(totalCorrect)/\(totalCount) (\(overallPct)%)")

// Print misclassifications for debugging
print()
print("Misclassifications")
print(String(repeating: "-", count: 70))

let misses = samples.filter { !$0.correct }
for miss in misses {
    let f = miss.features
    print("  \(miss.mode.padding(toLength: 8, withPad: " ", startingAt: 0)) \(miss.condition.padding(toLength: 25, withPad: " ", startingAt: 0)) -> \(miss.detectedMode) (\(Int(miss.detectedConfidence * 100))%) noise=\(Int(miss.noiseConfidence * 100))%  BW=\(Int(f.occupiedBandwidth))Hz OOK=\(f.envelopeStats.hasOnOffKeying) FSK=\(f.fskPairs.count) peaks=\(f.peaks.count)")
    // Show FSK pair shifts for debugging
    if miss.condition.contains("real-") {
        let shiftCounts: [Int: Int] = Dictionary(f.fskPairs.map { (Int($0.shift), 1) }, uniquingKeysWith: +)
        let sorted = shiftCounts.sorted { $0.value > $1.value }
        let shiftSummary = sorted.prefix(4).map { "\($0.key)Hz:\($0.value)" }.joined(separator: " ")
        let valleyCounts: [Int: Int] = Dictionary(f.fskPairs.filter { $0.hasValley }.map { (Int($0.shift), 1) }, uniquingKeysWith: +)
        let valleySummary = valleyCounts.isEmpty ? "none" : valleyCounts.sorted { $0.value > $1.value }.prefix(3).map { "\($0.key)Hz:\($0.value)" }.joined(separator: " ")
        print("           FSK shifts: \(shiftSummary)  valleys: \(valleySummary)")
        print("           Top peaks: \(f.peaks.prefix(3).map { "\(Int($0.frequency))Hz/\(Int($0.bandwidth3dB))bw" }.joined(separator: " "))")
    }
}

// Compute optimal thresholds
print()
print("Derived Thresholds (from data)")
print(String(repeating: "-", count: 70))

// CW vs everything: OOK coefficient of variation
if let cwStats = statsByMode["CW"], let rttyStats = statsByMode["RTTY"], let pskStats = statsByMode["PSK31"] {
    let cwCV = cwStats.envelopeCV.sorted()
    let rttyCV = rttyStats.envelopeCV.sorted()
    let pskCV = pskStats.envelopeCV.sorted()
    print("  CW envelope CV:   min=\(String(format:"%.2f",cwCV.first ?? 0)) p10=\(String(format:"%.2f",cwStats.pct(cwCV, 0.1))) median=\(String(format:"%.2f",cwStats.median(cwCV)))")
    print("  RTTY envelope CV: min=\(String(format:"%.2f",rttyCV.first ?? 0)) p90=\(String(format:"%.2f",rttyStats.pct(rttyCV, 0.9))) max=\(String(format:"%.2f",rttyCV.last ?? 0))")
    print("  PSK31 envelope CV: min=\(String(format:"%.2f",pskCV.first ?? 0)) p90=\(String(format:"%.2f",pskStats.pct(pskCV, 0.9))) max=\(String(format:"%.2f",pskCV.last ?? 0))")
    let cwMinCV = cwStats.pct(cwCV, 0.1)
    let nonCWMaxCV = max(rttyStats.pct(rttyCV, 0.9), pskStats.pct(pskCV, 0.9))
    print("  => OOK threshold: CV > \(String(format:"%.2f",(cwMinCV + nonCWMaxCV) / 2)) (midpoint)")
}

// RTTY vs PSK: FSK pairs with valley
if let rttyStats = statsByMode["RTTY"], let pskStats = statsByMode["PSK31"] {
    let rttyFSK = rttyStats.fskPairsWithValley.map { Float($0) }
    let pskFSK = pskStats.fskPairsWithValley.map { Float($0) }
    print("  RTTY FSK valley pairs: median=\(String(format:"%.1f",rttyStats.median(rttyFSK))) p10=\(String(format:"%.1f",rttyStats.pct(rttyFSK, 0.1)))")
    print("  PSK31 FSK valley pairs: median=\(String(format:"%.1f",pskStats.median(pskFSK))) p90=\(String(format:"%.1f",pskStats.pct(pskFSK, 0.9)))")
}

// Noise detection thresholds
if let noiseStats = statsByMode["noise"] {
    print("  Noise top peak power: median=\(String(format:"%.0f",noiseStats.median(noiseStats.topPeakPower)))dB p90=\(String(format:"%.0f",noiseStats.pct(noiseStats.topPeakPower, 0.9)))dB")
    print("  Noise BW: median=\(Int(noiseStats.median(noiseStats.occupiedBW)))Hz")
}

// CSV dump
if dumpCSV {
    print()
    print("CSV_START")
    print("mode,condition,detected,confidence,noise_conf,correct,bw,flatness,peaks,topPeakPower,topPeakBW,fskPairs,fskValley,cv,duty,transitions,ook,baudRate,baudConf")
    for s in samples {
        let f = s.features
        print("\(s.mode),\(s.condition),\(s.detectedMode),\(String(format:"%.3f",s.detectedConfidence)),\(String(format:"%.3f",s.noiseConfidence)),\(s.correct),\(Int(f.occupiedBandwidth)),\(String(format:"%.4f",f.spectralFlatness)),\(f.peaks.count),\(String(format:"%.1f",f.peaks.first?.powerAboveNoise ?? 0)),\(String(format:"%.1f",f.peaks.first?.bandwidth3dB ?? 0)),\(f.fskPairs.count),\(f.fskPairs.filter{$0.hasValley}.count),\(String(format:"%.3f",f.envelopeStats.coefficientOfVariation)),\(String(format:"%.3f",f.envelopeStats.dutyCycle)),\(String(format:"%.1f",f.envelopeStats.transitionRate)),\(f.envelopeStats.hasOnOffKeying),\(String(format:"%.2f",f.estimatedBaudRate)),\(String(format:"%.3f",f.baudRateConfidence))")
    }
    print("CSV_END")
}
