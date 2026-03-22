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
