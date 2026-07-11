//
//  GenerateModeTrainingData — Generates labeled audio for ML mode classifier training
//
//  Produces thousands of short WAV files (2 seconds each, 48 kHz mono 16-bit)
//  across all supported modes with realistic impairments from the benchmark harnesses.
//
//  Output: /tmp/mode_training_data/<mode>/<condition>_<index>.wav
//  Labels: /tmp/mode_training_data/labels.csv
//
//  Run: cd AmateurDigital/AmateurDigitalCore && swift run GenerateModeTrainingData
//       swift run GenerateModeTrainingData --count 200     # samples per mode per condition
//       swift run GenerateModeTrainingData --output ~/data  # custom output directory
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

// MARK: - WAV Writer

func writeWAV(samples: [Float], sampleRate: Int, path: String) throws {
    let numSamples = samples.count
    let dataSize = numSamples * 2 // 16-bit
    let fileSize = 44 + dataSize - 8

    var data = Data(capacity: 44 + dataSize)

    // RIFF header
    data.append(contentsOf: "RIFF".utf8)
    data.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize).littleEndian) { Array($0) })
    data.append(contentsOf: "WAVE".utf8)

    // fmt chunk
    data.append(contentsOf: "fmt ".utf8)
    data.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // PCM
    data.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) }) // mono
    data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Array($0) }) // byte rate
    data.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) }) // block align
    data.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) }) // bits

    // data chunk
    data.append(contentsOf: "data".utf8)
    data.append(contentsOf: withUnsafeBytes(of: UInt32(dataSize).littleEndian) { Array($0) })

    for sample in samples {
        let clamped = max(-1.0, min(1.0, sample))
        let int16 = Int16(clamped * 32767)
        data.append(contentsOf: withUnsafeBytes(of: int16.littleEndian) { Array($0) })
    }

    try data.write(to: URL(fileURLWithPath: path))
}

// MARK: - Impairments

func addNoise(to signal: [Float], snrDB: Float, rng: inout SeededRandom) -> [Float] {
    let power = signal.map { $0 * $0 }.reduce(0, +) / max(1, Float(signal.count))
    let rms = sqrt(power)
    guard rms > 0 else { return signal }
    let noiseRMS = rms / pow(10.0, snrDB / 20.0)
    return signal.map { $0 + Float(rng.nextGaussian()) * noiseRMS }
}

func applyOffset(to signal: [Float], hz: Double, sr: Double = 48000) -> [Float] {
    let inc = 2.0 * .pi * hz / sr
    return (0..<signal.count).map { i in signal[i] * Float(cos(inc * Double(i))) }
}

func applyFade(to signal: [Float], rate: Double, depth: Float, sr: Double = 48000) -> [Float] {
    let inc = 2.0 * .pi * rate / sr
    var result = [Float](repeating: 0, count: signal.count)
    for i in 0..<signal.count {
        let fade: Float = 1.0 - depth * Float(1.0 + cos(inc * Double(i))) / 2.0
        result[i] = signal[i] * fade
    }
    return result
}

// MARK: - Realistic HF Impairments

/// Simulates receiver AGC pumping: gain varies inversely with signal envelope.
/// Attack ~50ms, decay ~200ms. Creates 10-20 dB level swings on CW/RTTY.
func applyAGC(to signal: [Float], attackMs: Double = 50, decayMs: Double = 200, targetLevel: Float = 0.3) -> [Float] {
    let attackAlpha = Float(1.0 - exp(-1.0 / (attackMs * 48.0)))  // per-sample
    let decayAlpha = Float(1.0 - exp(-1.0 / (decayMs * 48.0)))
    var envelope: Float = targetLevel
    var result = [Float](repeating: 0, count: signal.count)
    for i in 0..<signal.count {
        let mag = abs(signal[i])
        let alpha = mag > envelope ? attackAlpha : decayAlpha
        envelope += alpha * (mag - envelope)
        let gain = envelope > 1e-6 ? targetLevel / envelope : 1.0
        result[i] = signal[i] * min(gain, 10.0)  // cap at 20 dB gain
    }
    return result
}

/// Simulates selective fading: applies a narrow spectral notch at a random frequency
/// within the signal bandwidth. Real HF multipath creates these.
func applySelectiveFade(to signal: [Float], notchFreq: Double, notchBW: Double = 50, depthDB: Float = 12, sr: Double = 48000) -> [Float] {
    // 2nd-order IIR notch filter
    let w0 = 2.0 * .pi * notchFreq / sr
    let Q = notchFreq / max(notchBW, 1)
    let alpha = sin(w0) / (2.0 * Q)
    let depth = pow(10.0, Double(-depthDB) / 20.0)
    let b0 = Float(1.0 - alpha * (1.0 - depth))
    let b1 = Float(-2.0 * cos(w0))
    let b2 = Float(1.0 + alpha * (1.0 - depth))
    let a0 = Float(1.0 + alpha)
    let a1 = Float(-2.0 * cos(w0))
    let a2 = Float(1.0 - alpha)

    var result = [Float](repeating: 0, count: signal.count)
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
    for i in 0..<signal.count {
        let x0 = signal[i]
        result[i] = (b0 * x0 + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2) / a0
        x2 = x1; x1 = x0; y2 = y1; y1 = result[i]
    }
    return result
}

/// Simulates impulsive QRN (lightning/switching noise). Poisson-timed bursts
/// with heavy-tailed amplitude, 5-50ms duration.
func addImpulsiveQRN(to signal: [Float], burstRate: Double = 3.0, peakDB: Float = 15, rng: inout SeededRandom) -> [Float] {
    let sigRMS = sqrt(signal.map { $0 * $0 }.reduce(0, +) / max(1, Float(signal.count)))
    guard sigRMS > 0 else { return signal }
    let burstAmplitude = sigRMS * pow(10.0, peakDB / 20.0)
    var result = signal
    let avgInterval = 48000.0 / burstRate  // samples between bursts
    var nextBurst = Int(rng.nextDouble() * avgInterval)
    while nextBurst < signal.count {
        let duration = Int(rng.nextDouble() * 0.045 * 48000 + 0.005 * 48000)  // 5-50 ms
        let amp = Float(rng.nextDouble() * 0.8 + 0.2) * burstAmplitude
        for j in nextBurst..<min(nextBurst + duration, signal.count) {
            result[j] += amp * Float(rng.nextGaussian()) * 0.3
        }
        nextBurst += Int(-log(max(rng.nextDouble(), 1e-10)) * avgInterval)  // exponential inter-arrival
    }
    return result
}

/// Adds adjacent-channel interference: another digital signal at a different frequency.
func addAdjacentSignal(to signal: [Float], interferer: [Float], offsetHz: Double = 500, levelDB: Float = -10, sr: Double = 48000) -> [Float] {
    let scale = pow(10.0, levelDB / 20.0)
    let shifted = applyOffset(to: interferer, hz: offsetHz, sr: sr)
    var result = signal
    for i in 0..<min(signal.count, shifted.count) {
        result[i] += shifted[i] * scale
    }
    return result
}

/// Simulates slow frequency drift (oscillator instability). Typical: 0.5-2 Hz/sec on HF.
func applyFrequencyDrift(to signal: [Float], driftRateHz: Double = 1.0, sr: Double = 48000) -> [Float] {
    var result = [Float](repeating: 0, count: signal.count)
    for i in 0..<signal.count {
        let t = Double(i) / sr
        // Drift creates a time-varying phase: integral of drift rate gives quadratic phase
        let phase = .pi * driftRateHz * t * t
        result[i] = signal[i] * Float(cos(phase))
    }
    return result
}

/// Simulates phase noise: random jitter on the carrier phase, broadens spectral lines.
func applyPhaseNoise(to signal: [Float], noiseFloorDBcHz: Double = -80, sr: Double = 48000, rng: inout SeededRandom) -> [Float] {
    // Simple random walk phase noise
    let variance = pow(10.0, noiseFloorDBcHz / 10.0) * sr
    let stepStd = sqrt(variance / sr)
    var phase: Double = 0
    var result = [Float](repeating: 0, count: signal.count)
    for i in 0..<signal.count {
        phase += rng.nextGaussian() * stepStd
        result[i] = signal[i] * Float(cos(phase))
    }
    return result
}

// MARK: - Signal Generators

let sampleRate: Double = 48000
let duration: Double = 2.0
let numSamples = Int(duration * sampleRate)

let hamTexts = [
    "CQ CQ CQ DE W1AW W1AW PSE K",
    "DE K1ABC K1ABC RST 599 599 QTH CT CT K",
    "W2ASM DE K3XYZ UR RST 579 579 NAME BOB QTH PA K",
    "CQ DX CQ DX DE VE3ABC VE3ABC K",
    "73 DE N0CALL SK",
    "TEST TEST DE W5ZZZ K",
    "QRZ QRZ DE AA1BB AA1BB K",
    "CQ POTA CQ POTA DE KG7XX KG7XX K",
    "R R TU DE WA6YYY 73 GL SK",
    "CQ CONTEST DE N2MM N2MM K",
]

func pad(_ s: [Float]) -> [Float] {
    if s.count >= numSamples { return Array(s.prefix(numSamples)) }
    return s + [Float](repeating: 0, count: numSamples - s.count)
}

func genRTTY(text: String, freq: Double = 2125, shift: Double = 170, baud: Double = 45.45) -> [Float] {
    let config = RTTYConfiguration(baudRate: baud, markFrequency: freq, shift: shift, sampleRate: sampleRate)
    let modem = RTTYModem(configuration: config)
    return pad(modem.encodeWithIdle(text: text, preambleMs: 200, postambleMs: 200))
}

func genPSK31(text: String, freq: Double = 1000) -> [Float] {
    var mod = PSKModulator.psk31(centerFrequency: freq)
    return pad(mod.modulateTextWithEnvelope(text, preambleMs: 200, postambleMs: 200))
}

func genBPSK63(text: String, freq: Double = 1000) -> [Float] {
    var mod = PSKModulator.bpsk63(centerFrequency: freq)
    return pad(mod.modulateTextWithEnvelope(text, preambleMs: 200, postambleMs: 200))
}

func genQPSK31(text: String, freq: Double = 1000) -> [Float] {
    var mod = PSKModulator.qpsk31(centerFrequency: freq)
    return pad(mod.modulateTextWithEnvelope(text, preambleMs: 200, postambleMs: 200))
}

func genQPSK63(text: String, freq: Double = 1000) -> [Float] {
    var mod = PSKModulator.qpsk63(centerFrequency: freq)
    return pad(mod.modulateTextWithEnvelope(text, preambleMs: 200, postambleMs: 200))
}

func genCW(text: String, freq: Double = 700, wpm: Double = 20) -> [Float] {
    var mod = CWModulator(configuration: CWConfiguration(
        toneFrequency: freq, wpm: wpm, sampleRate: sampleRate, riseTime: 0.005, dashDotRatio: 3.0))
    return pad(mod.modulateTextWithEnvelope(text, preambleMs: 300, postambleMs: 300))
}

func genJS8(text: String, freq: Double = 1000) -> [Float] {
    var mod = JS8CallModulator(configuration: JS8CallConfiguration(carrierFrequency: freq, sampleRate: sampleRate))
    return pad(mod.modulateTextWithEnvelope(text, preambleMs: 100, postambleMs: 200))
}

func genFT8(text: String, freq: Double = 1500) -> [Float] {
    // FT8 uses the same 8-GFSK as JS8Call but with FT8 Costas arrays and 1500 Hz default carrier
    let ft8Config = GFSKConfig(
        sampleRate: sampleRate,
        internalRate: 12000.0,
        toneSpacing: 6.25,
        samplesPerSymbol: 1920,
        costasArrays: .ft8,
        carrierFrequency: freq
    )
    var mod = GFSKModulator(config: ft8Config)
    // Generate random 174-bit codeword (FT8 message content doesn't matter for classification)
    let codeword = (0..<174).map { _ in UInt8.random(in: 0...1) }
    let symbols = mod.mapCodewordToSymbols(codeword)
    let audio = mod.generateAudio(symbols: symbols)

    // Add envelope shaping (raised cosine ramp)
    let rampSamples = Int(0.005 * sampleRate)
    var shaped = audio
    for i in 0..<min(rampSamples, shaped.count) {
        let t = Float(i) / Float(rampSamples)
        shaped[i] *= 0.5 * (1 - cos(.pi * t))
    }
    for i in 0..<min(rampSamples, shaped.count) {
        let idx = shaped.count - 1 - i
        let t = Float(i) / Float(rampSamples)
        shaped[idx] *= 0.5 * (1 - cos(.pi * t))
    }
    return pad(shaped)
}

func genNoise(rng: inout SeededRandom) -> [Float] {
    (0..<numSamples).map { _ in Float(rng.nextGaussian()) * 0.1 }
}

func genTone(freq: Double) -> [Float] {
    let inc = 2.0 * .pi * freq / sampleRate
    return (0..<numSamples).map { Float(sin(inc * Double($0))) * 0.3 }
}

/// Colored noise (1/f pink noise approximation)
func genPinkNoise(rng: inout SeededRandom, amplitude: Float = 0.1) -> [Float] {
    var b0: Float = 0, b1: Float = 0, b2: Float = 0, b3: Float = 0, b4: Float = 0, b5: Float = 0, b6: Float = 0
    return (0..<numSamples).map { _ in
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

/// 60 Hz mains hum with harmonics (common in unshielded audio)
func genHum(amplitude: Float = 0.05) -> [Float] {
    let inc60 = 2.0 * .pi * 60.0 / sampleRate
    let inc120 = 2.0 * .pi * 120.0 / sampleRate
    let inc180 = 2.0 * .pi * 180.0 / sampleRate
    return (0..<numSamples).map { i in
        let d = Double(i)
        return amplitude * (Float(sin(inc60 * d)) + 0.5 * Float(sin(inc120 * d)) + 0.25 * Float(sin(inc180 * d)))
    }
}

/// Realistic ambient mic noise: pink noise + hum + slight level variation
func genAmbientNoise(rng: inout SeededRandom, level: Float = 1.0) -> [Float] {
    let pink = genPinkNoise(rng: &rng, amplitude: level)
    let hum = genHum(amplitude: 0.03 * level)
    let white = (0..<numSamples).map { _ in Float(rng.nextGaussian()) * 0.02 * level }
    return zip(zip(pink, hum), white).map { $0.0.0 + $0.0.1 + $0.1 }
}

// MARK: - Training Data Generation

struct SampleSpec {
    let mode: String
    let condition: String
    let generator: (inout SeededRandom) -> [Float]
}

func buildSpecs() -> [SampleSpec] {
    var specs: [SampleSpec] = []

    // --- Per-mode generators with varied parameters ---

    let freqs: [Double] = [800, 1000, 1200, 1500, 2000, 2500]
    let snrs: [Float] = [30, 20, 15, 10, 5, 3, 0, -3]
    let offsets: [Double] = [-50, -20, -10, -5, 0, 5, 10, 20, 50]
    let fadeParams: [(rate: Double, depth: Float)] = [(0.2, 0.3), (0.5, 0.5), (1.0, 0.5), (2.0, 0.3)]
    let ituChannels: [(name: String, spread: Double, delay: Double)] = [
        ("good", 0.1, 0.0005), ("moderate", 0.5, 0.001), ("poor", 1.0, 0.002)
    ]

    // RTTY
    for freq in [1000.0, 1500.0, 2125.0, 2500.0] {
        specs.append(SampleSpec(mode: "rtty", condition: "clean-\(Int(freq))Hz") { rng in
            genRTTY(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count], freq: freq)
        })
    }
    for baud in [45.45, 50.0, 75.0] {
        specs.append(SampleSpec(mode: "rtty", condition: "baud\(Int(baud))") { rng in
            genRTTY(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count], baud: baud)
        })
    }
    for snr in snrs {
        specs.append(SampleSpec(mode: "rtty", condition: "snr\(Int(snr))") { rng in
            addNoise(to: genRTTY(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count]), snrDB: snr, rng: &rng)
        })
    }
    for (name, spread, delay) in ituChannels {
        specs.append(SampleSpec(mode: "rtty", condition: "itu-\(name)") { rng in
            var ch = WattersonChannel(dopplerSpread: spread, pathDelay: delay, sampleRate: sampleRate)
            return addNoise(to: ch.process(genRTTY(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count])), snrDB: 10, rng: &rng)
        })
    }
    for (rate, depth) in fadeParams {
        specs.append(SampleSpec(mode: "rtty", condition: "fade-\(rate)Hz") { rng in
            applyFade(to: genRTTY(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count]), rate: rate, depth: depth)
        })
    }

    // PSK31
    for freq in freqs {
        specs.append(SampleSpec(mode: "psk31", condition: "clean-\(Int(freq))Hz") { rng in
            genPSK31(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count], freq: freq)
        })
    }
    for snr in snrs {
        specs.append(SampleSpec(mode: "psk31", condition: "snr\(Int(snr))") { rng in
            addNoise(to: genPSK31(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count]), snrDB: snr, rng: &rng)
        })
    }
    for offset in offsets.filter({ abs($0) > 1 }) {
        specs.append(SampleSpec(mode: "psk31", condition: "offset\(Int(offset))Hz") { rng in
            applyOffset(to: genPSK31(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count]), hz: offset)
        })
    }
    for (name, spread, delay) in ituChannels {
        specs.append(SampleSpec(mode: "psk31", condition: "itu-\(name)") { rng in
            var ch = WattersonChannel(dopplerSpread: spread, pathDelay: delay, sampleRate: sampleRate)
            return addNoise(to: ch.process(genPSK31(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count])), snrDB: 10, rng: &rng)
        })
    }

    // BPSK63
    for freq in [800.0, 1000.0, 1500.0, 2000.0] {
        specs.append(SampleSpec(mode: "bpsk63", condition: "clean-\(Int(freq))Hz") { rng in
            genBPSK63(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count], freq: freq)
        })
    }
    for snr in snrs {
        specs.append(SampleSpec(mode: "bpsk63", condition: "snr\(Int(snr))") { rng in
            addNoise(to: genBPSK63(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count]), snrDB: snr, rng: &rng)
        })
    }

    // QPSK31
    for snr in [30, 20, 15, 10, 5, 0] as [Float] {
        specs.append(SampleSpec(mode: "qpsk31", condition: "snr\(Int(snr))") { rng in
            addNoise(to: genQPSK31(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count]), snrDB: snr, rng: &rng)
        })
    }

    // QPSK63
    for snr in [30, 20, 15, 10, 5, 0] as [Float] {
        specs.append(SampleSpec(mode: "qpsk63", condition: "snr\(Int(snr))") { rng in
            addNoise(to: genQPSK63(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count]), snrDB: snr, rng: &rng)
        })
    }

    // CW
    for freq in [500.0, 600.0, 700.0, 800.0, 1000.0] {
        specs.append(SampleSpec(mode: "cw", condition: "clean-\(Int(freq))Hz") { rng in
            genCW(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count], freq: freq)
        })
    }
    for wpm in [8.0, 13.0, 20.0, 25.0, 30.0, 40.0] {
        specs.append(SampleSpec(mode: "cw", condition: "wpm\(Int(wpm))") { rng in
            genCW(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count], wpm: wpm)
        })
    }
    for snr in snrs {
        specs.append(SampleSpec(mode: "cw", condition: "snr\(Int(snr))") { rng in
            addNoise(to: genCW(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count]), snrDB: snr, rng: &rng)
        })
    }
    for (name, spread, delay) in ituChannels {
        specs.append(SampleSpec(mode: "cw", condition: "itu-\(name)") { rng in
            var ch = WattersonChannel(dopplerSpread: spread, pathDelay: delay, sampleRate: sampleRate)
            return addNoise(to: ch.process(genCW(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count])), snrDB: 10, rng: &rng)
        })
    }

    // JS8Call
    for freq in [800.0, 1000.0, 1500.0, 2000.0] {
        specs.append(SampleSpec(mode: "js8call", condition: "clean-\(Int(freq))Hz") { rng in
            genJS8(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count], freq: freq)
        })
    }
    for snr in snrs {
        specs.append(SampleSpec(mode: "js8call", condition: "snr\(Int(snr))") { rng in
            addNoise(to: genJS8(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count]), snrDB: snr, rng: &rng)
        })
    }
    for (name, spread, delay) in ituChannels {
        specs.append(SampleSpec(mode: "js8call", condition: "itu-\(name)") { rng in
            var ch = WattersonChannel(dopplerSpread: spread, pathDelay: delay, sampleRate: sampleRate)
            return addNoise(to: ch.process(genJS8(text: hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count])), snrDB: 10, rng: &rng)
        })
    }

    // FT8 — same GFSK modulation as JS8Call but with FT8 Costas arrays
    for freq in [1000.0, 1500.0, 2000.0, 2500.0] {
        specs.append(SampleSpec(mode: "ft8", condition: "clean-\(Int(freq))Hz") { rng in
            genFT8(text: "", freq: freq)
        })
    }
    for snr in snrs {
        specs.append(SampleSpec(mode: "ft8", condition: "snr\(Int(snr))") { rng in
            addNoise(to: genFT8(text: ""), snrDB: snr, rng: &rng)
        })
    }
    for (name, spread, delay) in ituChannels {
        specs.append(SampleSpec(mode: "ft8", condition: "itu-\(name)") { rng in
            var ch = WattersonChannel(dopplerSpread: spread, pathDelay: delay, sampleRate: sampleRate)
            return addNoise(to: ch.process(genFT8(text: "")), snrDB: 10, rng: &rng)
        })
    }

    // =========================================================================
    // Realistic HF impairments — applied across all modes
    // =========================================================================

    // Helper to pick a random ham text
    func randText(_ rng: inout SeededRandom) -> String {
        hamTexts[Int(rng.nextDouble() * Double(hamTexts.count)) % hamTexts.count]
    }

    // Mode generators for impairment application
    let modeGens: [(mode: String, gen: (inout SeededRandom) -> [Float])] = [
        ("rtty",    { rng in genRTTY(text: randText(&rng)) }),
        ("psk31",   { rng in genPSK31(text: randText(&rng)) }),
        ("bpsk63",  { rng in genBPSK63(text: randText(&rng)) }),
        ("cw",      { rng in genCW(text: randText(&rng)) }),
        ("js8call", { rng in genJS8(text: randText(&rng)) }),
        ("ft8",     { rng in genFT8(text: "") }),
    ]

    for (mode, gen) in modeGens {
        // AGC pumping (fast attack, slow decay — receiver behavior on CW/RTTY)
        specs.append(SampleSpec(mode: mode, condition: "agc-fast") { rng in
            let sig = addNoise(to: gen(&rng), snrDB: 10, rng: &rng)
            return applyAGC(to: sig, attackMs: 20, decayMs: 150)
        })
        specs.append(SampleSpec(mode: mode, condition: "agc-slow") { rng in
            let sig = addNoise(to: gen(&rng), snrDB: 10, rng: &rng)
            return applyAGC(to: sig, attackMs: 100, decayMs: 500)
        })

        // Selective fading (spectral notch within signal BW)
        for depthDB: Float in [6, 12] {
            specs.append(SampleSpec(mode: mode, condition: "selfade-\(Int(depthDB))dB") { rng in
                let sig = gen(&rng)
                let notchFreq = 800 + rng.nextDouble() * 1400  // 800-2200 Hz
                return addNoise(to: applySelectiveFade(to: sig, notchFreq: notchFreq, depthDB: depthDB), snrDB: 10, rng: &rng)
            })
        }

        // Impulsive QRN (lightning crashes)
        specs.append(SampleSpec(mode: mode, condition: "qrn-light") { rng in
            addImpulsiveQRN(to: addNoise(to: gen(&rng), snrDB: 10, rng: &rng), burstRate: 2, peakDB: 10, rng: &rng)
        })
        specs.append(SampleSpec(mode: mode, condition: "qrn-heavy") { rng in
            addImpulsiveQRN(to: addNoise(to: gen(&rng), snrDB: 5, rng: &rng), burstRate: 5, peakDB: 20, rng: &rng)
        })

        // Frequency drift (oscillator instability)
        specs.append(SampleSpec(mode: mode, condition: "drift-1Hz") { rng in
            addNoise(to: applyFrequencyDrift(to: gen(&rng), driftRateHz: 1.0), snrDB: 15, rng: &rng)
        })
        specs.append(SampleSpec(mode: mode, condition: "drift-3Hz") { rng in
            addNoise(to: applyFrequencyDrift(to: gen(&rng), driftRateHz: 3.0), snrDB: 15, rng: &rng)
        })

        // Phase noise (oscillator jitter broadens spectral lines)
        specs.append(SampleSpec(mode: mode, condition: "phasenoise") { rng in
            addNoise(to: applyPhaseNoise(to: gen(&rng), noiseFloorDBcHz: -70, rng: &rng), snrDB: 15, rng: &rng)
        })

        // Combined: AGC + selective fading + noise (realistic worst-case HF)
        specs.append(SampleSpec(mode: mode, condition: "hf-brutal") { rng in
            var sig = gen(&rng)
            var ch = WattersonChannel(dopplerSpread: 1.0, pathDelay: 0.002, sampleRate: sampleRate)
            sig = ch.process(sig)
            let notchFreq = 800 + rng.nextDouble() * 1400
            sig = applySelectiveFade(to: sig, notchFreq: notchFreq, depthDB: 10)
            sig = addNoise(to: sig, snrDB: 5, rng: &rng)
            sig = applyAGC(to: sig, attackMs: 50, decayMs: 200)
            sig = addImpulsiveQRN(to: sig, burstRate: 2, peakDB: 12, rng: &rng)
            return sig
        })
    }

    // Adjacent-channel QRM — signal + different mode at nearby frequency
    specs.append(SampleSpec(mode: "rtty", condition: "qrm-psk") { rng in
        let sig = addNoise(to: genRTTY(text: randText(&rng)), snrDB: 15, rng: &rng)
        let qrm = genPSK31(text: randText(&rng), freq: 1500)
        return addAdjacentSignal(to: sig, interferer: qrm, offsetHz: 0, levelDB: -6)
    })
    specs.append(SampleSpec(mode: "psk31", condition: "qrm-rtty") { rng in
        let sig = addNoise(to: genPSK31(text: randText(&rng)), snrDB: 15, rng: &rng)
        let qrm = genRTTY(text: randText(&rng), freq: 2125)
        return addAdjacentSignal(to: sig, interferer: qrm, offsetHz: 0, levelDB: -6)
    })
    specs.append(SampleSpec(mode: "cw", condition: "qrm-cw") { rng in
        let sig = addNoise(to: genCW(text: randText(&rng)), snrDB: 15, rng: &rng)
        let qrm = genCW(text: randText(&rng), freq: 850)  // nearby CW station
        return addAdjacentSignal(to: sig, interferer: qrm, offsetHz: 0, levelDB: -3)
    })
    specs.append(SampleSpec(mode: "ft8", condition: "qrm-ft8") { rng in
        // Multiple FT8 signals at different frequencies (typical on 20m)
        var sig = addNoise(to: genFT8(text: "", freq: 1500), snrDB: 15, rng: &rng)
        for qrmFreq in [1000.0, 1200.0, 1800.0, 2000.0] {
            let qrm = genFT8(text: "", freq: qrmFreq)
            sig = addAdjacentSignal(to: sig, interferer: qrm, offsetHz: 0, levelDB: -10)
        }
        return sig
    })

    // Noise with QRN (impulsive noise should still be classified as noise)
    specs.append(SampleSpec(mode: "noise", condition: "qrn-crashes") { rng in
        addImpulsiveQRN(to: genNoise(rng: &rng), burstRate: 4, peakDB: 20, rng: &rng)
    })

    // Noise
    specs.append(SampleSpec(mode: "noise", condition: "silence") { _ in
        [Float](repeating: 0, count: numSamples)
    })
    specs.append(SampleSpec(mode: "noise", condition: "white") { rng in
        genNoise(rng: &rng)
    })
    specs.append(SampleSpec(mode: "noise", condition: "faint") { rng in
        genNoise(rng: &rng).map { $0 * 0.01 }
    })
    for freq in [700.0, 1000.0, 1500.0] {
        specs.append(SampleSpec(mode: "noise", condition: "tone-\(Int(freq))Hz") { _ in
            genTone(freq: freq)
        })
    }
    for snr: Float in [20, 10] {
        specs.append(SampleSpec(mode: "noise", condition: "tone-noise-\(Int(snr))dB") { rng in
            addNoise(to: genTone(freq: 1000), snrDB: snr, rng: &rng)
        })
    }
    // Realistic ambient microphone noise (what a silent room actually sounds like)
    for level: Float in [0.5, 1.0, 2.0] {
        specs.append(SampleSpec(mode: "noise", condition: "ambient-\(level)x") { rng in
            genAmbientNoise(rng: &rng, level: level)
        })
    }
    // 60 Hz hum alone (common with unshielded cables)
    for amp: Float in [0.02, 0.05, 0.1] {
        specs.append(SampleSpec(mode: "noise", condition: "hum-\(Int(amp*100))pct") { _ in
            genHum(amplitude: amp)
        })
    }
    // Pink noise alone (1/f, common background)
    for amp: Float in [0.5, 1.0, 2.0] {
        specs.append(SampleSpec(mode: "noise", condition: "pink-\(amp)x") { rng in
            genPinkNoise(rng: &rng, amplitude: amp)
        })
    }
    // Ambient noise + 60 Hz hum (the most realistic "silent room" scenario)
    specs.append(SampleSpec(mode: "noise", condition: "room-quiet") { rng in
        genAmbientNoise(rng: &rng, level: 0.3)
    })
    specs.append(SampleSpec(mode: "noise", condition: "room-normal") { rng in
        genAmbientNoise(rng: &rng, level: 1.0)
    })
    specs.append(SampleSpec(mode: "noise", condition: "room-noisy") { rng in
        genAmbientNoise(rng: &rng, level: 3.0)
    })

    return specs
}

// MARK: - Argument Parsing

var samplesPerSpec = 5
var outputDir = "/tmp/mode_training_data"

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    switch args[i] {
    case "--count":
        i += 1; samplesPerSpec = Int(args[i]) ?? 5
    case "--output":
        i += 1; outputDir = args[i]
    case "--help", "-h":
        print("Usage: GenerateModeTrainingData [--count N] [--output DIR]")
        exit(0)
    default:
        break
    }
    i += 1
}

// MARK: - Main

let specs = buildSpecs()
let totalFiles = specs.count * samplesPerSpec

print("Mode Training Data Generator")
print(String(repeating: "=", count: 60))
print("  Specs:   \(specs.count) conditions")
print("  Per spec: \(samplesPerSpec) samples")
print("  Total:   \(totalFiles) WAV files")
print("  Output:  \(outputDir)")
print()

// Create directories
let fm = FileManager.default
let modes = Set(specs.map(\.mode))
for mode in modes {
    try! fm.createDirectory(atPath: "\(outputDir)/\(mode)", withIntermediateDirectories: true)
}

// Generate and write
var labelLines: [String] = ["file,mode,condition"]
var rng = SeededRandom(seed: 12345)
var count = 0
let startTime = CFAbsoluteTimeGetCurrent()

for spec in specs {
    for j in 0..<samplesPerSpec {
        let filename = "\(spec.condition)_\(j).wav"
        let path = "\(outputDir)/\(spec.mode)/\(filename)"
        let samples = spec.generator(&rng)
        try! writeWAV(samples: samples, sampleRate: Int(sampleRate), path: path)
        labelLines.append("\(spec.mode)/\(filename),\(spec.mode),\(spec.condition)")

        count += 1
        if count % 100 == 0 {
            let pct = Int(Double(count) / Double(totalFiles) * 100)
            print("  [\(pct)%] \(count)/\(totalFiles) files generated...")
        }
    }
}

// Write labels CSV
let labelsPath = "\(outputDir)/labels.csv"
try! labelLines.joined(separator: "\n").write(toFile: labelsPath, atomically: true, encoding: .utf8)

let elapsed = CFAbsoluteTimeGetCurrent() - startTime
print()
print("Done: \(count) files in \(String(format: "%.1f", elapsed))s")
print("Labels: \(labelsPath)")
print()

// Summary
for mode in modes.sorted() {
    let modeSpecs = specs.filter { $0.mode == mode }
    print("  \(mode.padding(toLength: 10, withPad: " ", startingAt: 0)) \(modeSpecs.count * samplesPerSpec) files (\(modeSpecs.count) conditions)")
}
