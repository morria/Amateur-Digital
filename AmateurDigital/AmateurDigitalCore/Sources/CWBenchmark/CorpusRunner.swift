//
//  CorpusRunner.swift — score the decoders against real off-air audio.
//
//  Usage: CWBenchmark --corpus <dir> [--dual | --bayesian-only]
//
//  <dir> holds WAV recordings with sidecar ground truth: for every
//  foo.wav, a foo.txt containing the transcript. Tone frequency is
//  auto-detected; sample rate comes from the file. Results print per
//  file plus an aggregate CER — kept OUT of the synthetic composite so
//  held-out recordings stay an honest overfitting check for Optuna runs.
//

import Foundation
import AmateurDigitalCore

enum CorpusRunner {

    static func run(directory: String, mode: DecoderMode, bayesianParams: BayesianCWParams?) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else {
            print("Corpus: cannot read directory \(directory)")
            return
        }
        let wavs = entries.filter { $0.lowercased().hasSuffix(".wav") }.sorted()
        guard !wavs.isEmpty else {
            print("Corpus: no .wav files in \(directory)")
            return
        }

        print(String(repeating: "=", count: 70))
        print("CW CORPUS RUN — \(wavs.count) recording(s) in \(directory)")
        print(String(repeating: "=", count: 70))

        var totalCER = 0.0
        var scored = 0

        for wav in wavs {
            let wavPath = (directory as NSString).appendingPathComponent(wav)
            let txtPath = (wavPath as NSString).deletingPathExtension + ".txt"
            guard let truthRaw = try? String(contentsOfFile: txtPath, encoding: .utf8) else {
                print("  [skip] \(wav): no sidecar .txt ground truth")
                continue
            }
            let truth = truthRaw.uppercased()
                .components(separatedBy: .whitespacesAndNewlines)
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            guard let audio = readWAVFile(path: wavPath) else {
                print("  [skip] \(wav): unreadable WAV")
                continue
            }

            let tone = detectTone(samples: audio.samples, sampleRate: audio.sampleRate)
            let config = CWConfiguration(
                toneFrequency: tone,
                wpm: 20,
                sampleRate: audio.sampleRate
            )

            let decoder: CWDecoderWrapper
            switch mode {
            case .classic:  decoder = ClassicDecoderWrapper(configuration: config)
            case .bayesian: decoder = BayesianDecoderWrapper(configuration: config, params: bayesianParams)
            case .dual:     decoder = DualDecoderWrapper(configuration: config)
            }
            decoder.process(samples: audio.samples)

            let decoded = decoder.decodedText
            let cer = characterErrorRate(expected: truth, actual: decoded)
            totalCER += cer
            scored += 1
            print("  \(wav): tone=\(Int(tone))Hz cer=\(String(format: "%.1f%%", cer * 100))")
            print("    expected: \(truth.prefix(60))")
            print("    decoded:  \(decoded.prefix(60))")
        }

        if scored > 0 {
            let avg = totalCER / Double(scored)
            print(String(repeating: "-", count: 70))
            print("CORPUS AVERAGE CER: \(String(format: "%.1f%%", avg * 100)) over \(scored) recording(s)")
            print("CORPUS SCORE: \(String(format: "%.1f", max(0, 100 * (1 - avg)))) / 100")
        }
    }

    // MARK: - Tone detection

    /// Strongest tone in the CW band via a Goertzel sweep over the first
    /// few seconds (10 Hz steps, 300–1200 Hz).
    static func detectTone(samples: [Float], sampleRate: Double) -> Double {
        let window = Array(samples.prefix(Int(sampleRate * 5)))
        guard window.count > 4800 else { return 700 }
        let blockSize = Int(sampleRate * 0.05)
        var bestFreq = 700.0
        var bestPower: Float = 0
        var freq = 300.0
        while freq <= 1200.0 {
            var total: Float = 0
            var filter = GoertzelFilter(frequency: freq, sampleRate: sampleRate, blockSize: blockSize)
            var index = 0
            while index + blockSize <= window.count {
                total += filter.processBlock(Array(window[index..<index + blockSize]))
                index += blockSize
            }
            if total > bestPower {
                bestPower = total
                bestFreq = freq
            }
            freq += 10
        }
        return bestFreq
    }

    // MARK: - WAV reader (PCM 8/16/24/32-bit int + 32-bit float, mono-mixed)

    static func readWAVFile(path: String) -> (samples: [Float], sampleRate: Double)? {
        guard let data = fm_contents(path), data.count > 44,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else { return nil }

        var audioFormat = 0
        var channels = 1
        var sampleRate = 48000.0
        var bits = 16
        var payload: Data?

        // Walk RIFF chunks (fmt / data can appear in any order, with
        // LIST/fact chunks interleaved).
        var offset = 12
        while offset + 8 <= data.count {
            let chunkID = String(data: data[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = Int(readLE32(data, offset + 4))
            let body = offset + 8
            guard body + size <= data.count || chunkID == "data" else { break }
            switch chunkID {
            case "fmt ":
                audioFormat = Int(readLE16(data, body))
                channels = max(1, Int(readLE16(data, body + 2)))
                sampleRate = Double(readLE32(data, body + 4))
                bits = Int(readLE16(data, body + 14))
                if audioFormat == 0xFFFE, size >= 40 {
                    audioFormat = Int(readLE16(data, body + 24))
                }
            case "data":
                payload = data.subdata(in: body..<min(body + size, data.count))
            default:
                break
            }
            offset = body + size + (size % 2)
        }

        guard let pcm = payload, audioFormat == 1 || audioFormat == 3 else { return nil }

        let bytesPerSample = bits / 8
        let frameCount = pcm.count / (bytesPerSample * channels)
        var mono = [Float](repeating: 0, count: frameCount)

        pcm.withUnsafeBytes { raw in
            for frame in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channels {
                    let i = (frame * channels + ch) * bytesPerSample
                    switch (audioFormat, bits) {
                    case (3, 32):
                        sum += raw.loadUnaligned(fromByteOffset: i, as: Float.self)
                    case (1, 16):
                        sum += Float(raw.loadUnaligned(fromByteOffset: i, as: Int16.self)) / 32768
                    case (1, 8):
                        sum += (Float(raw.loadUnaligned(fromByteOffset: i, as: UInt8.self)) - 128) / 128
                    case (1, 24):
                        let b0 = Int32(raw.loadUnaligned(fromByteOffset: i, as: UInt8.self))
                        let b1 = Int32(raw.loadUnaligned(fromByteOffset: i + 1, as: UInt8.self))
                        let b2 = Int32(raw.loadUnaligned(fromByteOffset: i + 2, as: Int8.self))
                        sum += Float((b2 << 16) | (b1 << 8) | b0) / 8388608
                    case (1, 32):
                        sum += Float(raw.loadUnaligned(fromByteOffset: i, as: Int32.self)) / 2147483648
                    default:
                        break
                    }
                }
                mono[frame] = sum / Float(channels)
            }
        }
        return (mono, sampleRate)
    }

    private static func fm_contents(_ path: String) -> Data? {
        FileManager.default.contents(atPath: path)
    }

    private static func readLE16(_ data: Data, _ offset: Int) -> UInt16 {
        data.subdata(in: offset..<offset + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }
    }

    private static func readLE32(_ data: Data, _ offset: Int) -> UInt32 {
        data.subdata(in: offset..<offset + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
    }
}
