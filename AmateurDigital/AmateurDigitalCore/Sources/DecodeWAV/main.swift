//
//  DecodeWAV
//  Reads a WAV file and decodes PSK or RTTY signals
//
//  Usage: DecodeWAV [--mode psk|rtty] <file.wav>
//

import Foundation
import AmateurDigitalCore

// MARK: - WAV Reader

func readWAV(from path: String) throws -> (samples: [Float], sampleRate: Double) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        print("Error: file not found: \(path)")
        exit(1)
    }
    let data = try Data(contentsOf: url)

    guard data.count > 44,
          String(data: data[0..<4], encoding: .ascii) == "RIFF",
          String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
        print("Error: not a valid WAV file")
        exit(1)
    }

    var audioFormat = Int(data[20..<22].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
    let numChannels = Int(data[22..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
    let sampleRate = Double(data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    let bitsPerSample = Int(data[34..<36].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })

    // audioFormat 0xFFFE = WAVE_FORMAT_EXTENSIBLE: real format is in SubFormat GUID at byte 44
    if audioFormat == 0xFFFE && data.count > 60 {
        audioFormat = Int(data[44..<46].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
    }

    // audioFormat: 1 = PCM integer, 3 = IEEE float
    guard audioFormat == 1 || audioFormat == 3 else {
        print("Error: unsupported WAV format \(audioFormat) (only PCM and IEEE float supported)")
        exit(1)
    }
    guard [8, 16, 24, 32].contains(bitsPerSample) else {
        print("Error: unsupported bit depth \(bitsPerSample)")
        exit(1)
    }

    print("Format: \(audioFormat == 3 ? "float" : "PCM") \(bitsPerSample)-bit, \(numChannels)ch, \(Int(sampleRate)) Hz")

    var offset = 12
    while offset + 8 < data.count {
        let chunkID = String(data: data[offset..<offset+4], encoding: .ascii) ?? ""
        let chunkSize = Int(data[offset+4..<offset+8].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        if chunkID == "data" { offset += 8; break }
        offset += 8 + chunkSize
    }

    let bytesPerSample = bitsPerSample / 8
    let frameSize = bytesPerSample * numChannels
    let numFrames = (data.count - offset) / frameSize
    var samples = [Float]()
    samples.reserveCapacity(numFrames)

    for i in 0..<numFrames {
        let frameOffset = offset + i * frameSize
        switch (audioFormat, bitsPerSample) {
        case (1, 8):
            // Unsigned 8-bit PCM: 0-255, 128 = silence
            let value = data[frameOffset]
            samples.append((Float(value) - 128.0) / 128.0)
        case (1, 16):
            let value = data[frameOffset..<frameOffset+2].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
            samples.append(Float(value) / 32768.0)
        case (1, 24):
            let b0 = Int32(data[frameOffset])
            let b1 = Int32(data[frameOffset + 1])
            let b2 = Int32(data[frameOffset + 2])
            var value = b0 | (b1 << 8) | (b2 << 16)
            if value & 0x800000 != 0 { value |= ~0xFFFFFF } // sign extend
            samples.append(Float(value) / 8388608.0)
        case (_, 32) where audioFormat == 3:
            let value = data[frameOffset..<frameOffset+4].withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
            samples.append(value)
        case (1, 32):
            let value = data[frameOffset..<frameOffset+4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            samples.append(Float(Double(value) / 2147483648.0))
        default:
            break
        }
    }
    return (samples, sampleRate)
}

// MARK: - Helpers

func printable(_ text: String) -> String {
    text.map { c -> String in
        if let a = c.asciiValue, a >= 32 && a < 127 { return String(c) }
        else if c == "\n" { return "\\n" }
        else if c == "\r" { return "\\r" }
        else { return "." }
    }.joined()
}

func textQuality(_ text: String) -> Double {
    guard !text.isEmpty else { return 0 }
    let good = text.filter { c in
        if let a = c.asciiValue {
            return (a >= 32 && a < 127) || a == 10 || a == 13
        }
        return false
    }.count
    return Double(good) / Double(text.count)
}

/// Score how much decoded text looks like real RTTY traffic vs random Baudot noise.
/// Real RTTY has words separated by spaces, mostly letters, ham radio patterns.
func rttyScore(_ text: String) -> Double {
    guard text.count >= 3 else { return 0 }

    // Split into words by whitespace and control chars
    let words = text.split { c in
        c == " " || c == "\r" || c == "\n"
    }.map { String($0) }

    guard !words.isEmpty else { return 0 }

    // Metric 1: Average word length (real text: 2-8 chars, noise: very long or 1)
    let avgWordLen = Double(words.map(\.count).reduce(0, +)) / Double(words.count)
    let wordLenScore: Double
    if avgWordLen >= 2 && avgWordLen <= 8 {
        wordLenScore = 1.0
    } else if avgWordLen >= 1 && avgWordLen <= 12 {
        wordLenScore = 0.5
    } else {
        wordLenScore = 0.1
    }

    // Metric 2: Letter-to-digit ratio (real RTTY is mostly letters)
    let letters = text.filter { $0.isLetter }.count
    let digits = text.filter { $0.isNumber }.count
    let symbols = text.filter { c in
        if let a = c.asciiValue { return a >= 33 && a < 48 || a >= 58 && a < 65 }
        return false
    }.count
    let letterRatio = Double(letters) / Double(max(1, letters + digits + symbols))
    let letterScore = min(1.0, letterRatio * 1.5)  // bonus for high letter ratio

    // Metric 3: Presence of ham radio patterns (CQ, DE, QRZ, callsign-like sequences)
    let upper = text.uppercased()
    var patternBonus = 0.0
    if upper.contains("CQ") { patternBonus += 0.3 }
    if upper.contains("DE ") { patternBonus += 0.2 }
    if upper.contains("QRZ") { patternBonus += 0.2 }
    if upper.contains("73") { patternBonus += 0.1 }
    patternBonus = min(1.0, patternBonus)

    // Metric 4: Has multiple words (real text has word structure)
    let multiWordScore = words.count >= 2 ? 1.0 : 0.3

    // Composite score
    return (wordLenScore * 0.25 + letterScore * 0.25 + patternBonus * 0.3 + multiWordScore * 0.2) * Double(text.count)
}

// MARK: - PSK Decode

class PSKDecodeDelegate: PSKDemodulatorDelegate {
    var decoded: String = ""

    func demodulator(_ d: PSKDemodulator, didDecode c: Character, atFrequency f: Double) {
        decoded.append(c)
    }
    func demodulator(_ d: PSKDemodulator, signalDetected detected: Bool, atFrequency f: Double) {}
}

func decodePSK(samples: [Float], sampleRate: Double) {
    let baudRate = 31.25
    let samplesPerSymbol = Int(sampleRate / baudRate)
    print("Mode: PSK31 (BPSK, 31.25 baud)")
    print("Samples per symbol: \(samplesPerSymbol)")

    // Coarse scan: 5 Hz spacing, 200-3500 Hz
    print("\n=== Coarse scan: 5 Hz spacing, 200-3500 Hz ===")
    var bestFreqs: [(freq: Double, text: String, quality: Double)] = []

    for freq in stride(from: 200.0, through: 3500.0, by: 5.0) {
        let config = PSKConfiguration(
            modulationType: .bpsk, baudRate: baudRate,
            centerFrequency: freq, sampleRate: sampleRate
        )
        let demod = PSKDemodulator(configuration: config)
        let delegate = PSKDecodeDelegate()
        demod.delegate = delegate
        demod.squelchLevel = 0.0

        let chunkSize = 4096
        var off = 0
        while off < samples.count {
            let end = min(off + chunkSize, samples.count)
            demod.process(samples: Array(samples[off..<end]))
            off = end
        }

        let text = delegate.decoded
        if text.count >= 5 {
            let q = textQuality(text)
            bestFreqs.append((freq, text, q))
        }
    }

    bestFreqs.sort { $0.text.count > $1.text.count }
    print("Frequencies with 5+ chars decoded (\(bestFreqs.count) total):")
    for r in bestFreqs.prefix(20) {
        print("  \(String(format: "%7.0f", r.freq)) Hz: \(r.text.count) chars, quality=\(String(format: "%.0f%%", r.quality*100)) - \"\(printable(String(r.text.prefix(60))))\"")
    }

    // Timing offset sweep for top frequencies
    print("\n=== Timing offset sweep for top frequencies ===")
    let topFreqs = bestFreqs.prefix(5).map { $0.freq }

    for freq in topFreqs {
        print("\n--- \(Int(freq)) Hz: timing offset sweep ---")
        var bestOffset = 0
        var bestText = ""
        var bestQuality = 0.0

        let step = samplesPerSymbol / 16
        for offsetIdx in 0..<16 {
            let skipSamples = offsetIdx * step
            let offsetSamples = Array(samples.dropFirst(skipSamples))

            let config = PSKConfiguration(
                modulationType: .bpsk, baudRate: baudRate,
                centerFrequency: freq, sampleRate: sampleRate
            )
            let demod = PSKDemodulator(configuration: config)
            let delegate = PSKDecodeDelegate()
            demod.delegate = delegate
            demod.squelchLevel = 0.0

            let chunkSize = 4096
            var off = 0
            while off < offsetSamples.count {
                let end = min(off + chunkSize, offsetSamples.count)
                demod.process(samples: Array(offsetSamples[off..<end]))
                off = end
            }

            let text = delegate.decoded
            let q = textQuality(text)
            if text.count > 3 && (text.count > bestText.count || (text.count == bestText.count && q > bestQuality)) {
                bestOffset = offsetIdx
                bestText = text
                bestQuality = q
            }
            if text.count >= 5 {
                print("    offset \(String(format: "%2d", offsetIdx)) (\(String(format: "%4d", skipSamples)) samples): \(text.count) chars, q=\(String(format: "%.0f%%", q*100)) \"\(printable(String(text.prefix(50))))\"")
            }
        }
        print("  Best: offset \(bestOffset), \(bestText.count) chars, quality \(String(format: "%.0f%%", bestQuality*100))")
        print("  Text: \"\(printable(String(bestText.prefix(120))))\"")
    }
}

// MARK: - RTTY Decode

class RTTYDecodeDelegate: FSKDemodulatorDelegate {
    var decoded: String = ""

    func demodulator(_ d: FSKDemodulator, didDecode c: Character, atFrequency f: Double) {
        decoded.append(c)
    }
    func demodulator(_ d: FSKDemodulator, signalDetected detected: Bool, atFrequency f: Double) {}
}

func decodeRTTY(samples: [Float], sampleRate: Double) {
    let config = RTTYConfiguration.standard.withSampleRate(sampleRate)
    print("Mode: RTTY (\(config.baudRate) baud, \(Int(config.shift)) Hz shift)")
    print("Samples per bit: \(config.samplesPerBit)")

    // Scan mark frequencies from 500-3500 Hz at 10 Hz spacing
    print("\n=== Frequency scan: 10 Hz spacing, 500-3500 Hz ===")
    var bestFreqs: [(freq: Double, text: String, score: Double, chars: Int)] = []

    for markFreq in stride(from: 500.0, through: 3500.0, by: 10.0) {
        let scanConfig = config.withCenterFrequency(markFreq)
        let demod = FSKDemodulator(configuration: scanConfig)
        let delegate = RTTYDecodeDelegate()
        demod.delegate = delegate
        demod.afcEnabled = false
        demod.minCharacterConfidence = 0.5

        let chunkSize = 4096
        var off = 0
        while off < samples.count {
            let end = min(off + chunkSize, samples.count)
            demod.process(samples: Array(samples[off..<end]))
            off = end
        }

        let text = delegate.decoded
        if text.count >= 3 {
            let score = rttyScore(text)
            bestFreqs.append((markFreq, text, score, text.count))
        }
    }

    bestFreqs.sort { $0.score > $1.score }
    print("Frequencies with 3+ chars decoded (\(bestFreqs.count) total):")
    for r in bestFreqs.prefix(20) {
        print("  \(String(format: "%7.0f", r.freq)) Hz mark: \(r.chars) chars, score=\(String(format: "%.1f", r.score)) - \"\(printable(String(r.text.prefix(60))))\"")
    }

    // Fine decode for top frequencies: sweep ±20 Hz in 2 Hz steps
    if !bestFreqs.isEmpty {
        print("\n=== Fine decode for top frequencies ===")
        // Deduplicate nearby frequencies (within 50 Hz)
        var topFreqs: [Double] = []
        for r in bestFreqs {
            if topFreqs.count >= 5 { break }
            if topFreqs.allSatisfy({ abs($0 - r.freq) > 50 }) {
                topFreqs.append(r.freq)
            }
        }

        for coarseFreq in topFreqs {
            var bestText = ""
            var bestScore = 0.0
            var bestFineFreq = coarseFreq

            // Fine sweep ±20 Hz in 2 Hz steps
            for fineFreq in stride(from: coarseFreq - 20, through: coarseFreq + 20, by: 2.0) {
                let fineConfig = config.withCenterFrequency(fineFreq)
                let demod = FSKDemodulator(configuration: fineConfig)
                let delegate = RTTYDecodeDelegate()
                demod.delegate = delegate
                demod.afcEnabled = false
                demod.minCharacterConfidence = 0.3

                let chunkSize = 4096
                var off = 0
                while off < samples.count {
                    let end = min(off + chunkSize, samples.count)
                    demod.process(samples: Array(samples[off..<end]))
                    off = end
                }

                let text = delegate.decoded
                let score = rttyScore(text)
                if score > bestScore {
                    bestScore = score
                    bestText = text
                    bestFineFreq = fineFreq
                }
            }

            print("\n--- \(Int(coarseFreq)) Hz mark (fine-tuned to \(String(format: "%.0f", bestFineFreq)) Hz) ---")
            print("  \(bestText.count) chars, score=\(String(format: "%.1f", bestScore))")
            print("  Text: \"\(printable(String(bestText.prefix(200))))\"")
        }
    }
}

// MARK: - Argument Parsing & Main

var mode = "psk"
var wavPath = "/tmp/sample_mono48k.wav"

var args = Array(CommandLine.arguments.dropFirst())
var i = 0
while i < args.count {
    if args[i] == "--mode" && i + 1 < args.count {
        mode = args[i + 1].lowercased()
        i += 2
    } else {
        wavPath = args[i]
        i += 1
    }
}

guard mode == "psk" || mode == "rtty" else {
    print("Unknown mode: \(mode)")
    print("Usage: DecodeWAV [--mode psk|rtty] <file.wav>")
    exit(1)
}

print("Reading: \(wavPath)")
let (samples, sampleRate) = try readWAV(from: wavPath)
print("Loaded \(samples.count) samples, \(String(format: "%.1f", Double(samples.count)/sampleRate))s, \(Int(sampleRate)) Hz\n")

switch mode {
case "rtty":
    decodeRTTY(samples: samples, sampleRate: sampleRate)
default:
    decodePSK(samples: samples, sampleRate: sampleRate)
}

print("\nDone.")
