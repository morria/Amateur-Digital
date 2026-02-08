//
//  DecodeWAV — Fast RTTY/PSK Audio Decoder
//
//  Uses FFT pre-scan to identify active frequencies, then demodulates
//  only those signals in parallel. Typically 50-100x faster than
//  brute-force frequency scanning.
//
//  Usage:
//    DecodeWAV <file.wav>                    # auto-detect mode
//    DecodeWAV <file.wav> --mode rtty        # force RTTY mode
//    DecodeWAV <file.wav> --mode psk         # force PSK mode
//    DecodeWAV <file.wav> --verbose          # show spectrum details
//

import Foundation
import Accelerate
import AmateurDigitalCore

// MARK: - Timing

func now() -> Double { CFAbsoluteTimeGetCurrent() }

func elapsed(_ start: Double) -> String {
    let ms = (now() - start) * 1000
    if ms < 1000 { return "\(Int(ms))ms" }
    return String(format: "%.2fs", ms / 1000)
}

// MARK: - WAV Reader

func readWAV(from path: String) throws -> (samples: [Float], sampleRate: Double, channels: Int, bits: Int) {
    let url = URL(fileURLWithPath: path)
    guard FileManager.default.fileExists(atPath: url.path) else {
        fputs("Error: file not found: \(path)\n", stderr)
        exit(1)
    }
    let data = try Data(contentsOf: url)

    guard data.count > 44,
          String(data: data[0..<4], encoding: .ascii) == "RIFF",
          String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
        fputs("Error: not a valid WAV file\n", stderr)
        exit(1)
    }

    var audioFormat = Int(data[20..<22].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
    let numChannels = Int(data[22..<24].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
    let sampleRate = Double(data[24..<28].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
    let bitsPerSample = Int(data[34..<36].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })

    // WAVE_FORMAT_EXTENSIBLE: real format in SubFormat GUID
    if audioFormat == 0xFFFE && data.count > 60 {
        audioFormat = Int(data[44..<46].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) })
    }

    guard audioFormat == 1 || audioFormat == 3 else {
        fputs("Error: unsupported WAV format \(audioFormat) (need PCM or IEEE float)\n", stderr)
        exit(1)
    }
    guard [8, 16, 24, 32].contains(bitsPerSample) else {
        fputs("Error: unsupported bit depth \(bitsPerSample)\n", stderr)
        exit(1)
    }

    // Find data chunk
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
        let fo = offset + i * frameSize
        switch (audioFormat, bitsPerSample) {
        case (1, 8):
            samples.append((Float(data[fo]) - 128.0) / 128.0)
        case (1, 16):
            let v = data[fo..<fo+2].withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
            samples.append(Float(v) / 32768.0)
        case (1, 24):
            var v = Int32(data[fo]) | (Int32(data[fo+1]) << 8) | (Int32(data[fo+2]) << 16)
            if v & 0x800000 != 0 { v |= ~0xFFFFFF }
            samples.append(Float(v) / 8388608.0)
        case (_, 32) where audioFormat == 3:
            let v = data[fo..<fo+4].withUnsafeBytes { $0.loadUnaligned(as: Float.self) }
            samples.append(v)
        case (1, 32):
            let v = data[fo..<fo+4].withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
            samples.append(Float(Double(v) / 2147483648.0))
        default:
            break
        }
    }

    return (samples, sampleRate, numChannels, bitsPerSample)
}

// MARK: - FFT Spectrum Analysis

/// Compute averaged power spectrum using vDSP real-to-complex FFT.
/// Returns power per frequency bin (linear scale), bin width in Hz, and number of windows averaged.
func powerSpectrum(
    samples: [Float], sampleRate: Double, fftSize: Int = 8192
) -> (bins: [Float], binWidth: Double, windowCount: Int) {
    let halfN = fftSize / 2
    let log2n = vDSP_Length(log2(Float(fftSize)))

    guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
        return ([Float](repeating: 0, count: halfN), sampleRate / Double(fftSize), 0)
    }
    defer { vDSP_destroy_fftsetup(setup) }

    // Hann window
    var window = [Float](repeating: 0, count: fftSize)
    vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

    var accumulated = [Float](repeating: 0, count: halfN)
    var windowCount = 0
    let hop = fftSize / 2 // 50% overlap

    // Reusable buffers
    var windowed = [Float](repeating: 0, count: fftSize)
    var realp = [Float](repeating: 0, count: halfN)
    var imagp = [Float](repeating: 0, count: halfN)

    var offset = 0
    while offset + fftSize <= samples.count {
        // Apply window
        for i in 0..<fftSize {
            windowed[i] = samples[offset + i] * window[i]
        }

        // Deinterleave into split complex (even → real, odd → imag)
        for i in 0..<halfN {
            realp[i] = windowed[2 * i]
            imagp[i] = windowed[2 * i + 1]
        }

        realp.withUnsafeMutableBufferPointer { rBuf in
            imagp.withUnsafeMutableBufferPointer { iBuf in
                var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))

                // Accumulate magnitudes squared directly into `accumulated`
                // |X[k]|^2 = re^2 + im^2
                for k in 0..<halfN {
                    accumulated[k] += rBuf[k] * rBuf[k] + iBuf[k] * iBuf[k]
                }
            }
        }

        windowCount += 1
        offset += hop
    }

    // Average
    if windowCount > 0 {
        let scale = 1.0 / Float(windowCount)
        for i in 0..<halfN {
            accumulated[i] *= scale
        }
    }

    return (accumulated, sampleRate / Double(fftSize), windowCount)
}

// MARK: - Candidate Finding

struct SignalCandidate {
    let markFreq: Double
    let spaceFreq: Double // 0 for PSK
    let powerDB: Float
}

/// Find RTTY signal candidates by looking for mark/space frequency pairs in the spectrum.
func findRTTYCandidates(
    bins: [Float], binWidth: Double, shift: Double = 170,
    minFreq: Double = 500, maxFreq: Double = 3500
) -> [SignalCandidate] {
    let shiftBins = Int(round(shift / binWidth))
    let minBin = max(shiftBins, Int(ceil(minFreq / binWidth)))
    let maxBin = min(bins.count - 1, Int(floor(maxFreq / binWidth)))
    guard minBin < maxBin else { return [] }

    // Noise floor = median power in the range
    let sorted = Array(bins[minBin...maxBin]).sorted()
    let noiseFloor = sorted[sorted.count / 2]
    let threshold = noiseFloor * 10 // ~10 dB above noise

    var candidates: [(freq: Double, score: Float)] = []

    for markBin in minBin...maxBin {
        let spaceBin = markBin - shiftBins
        guard spaceBin >= 0 else { continue }

        let markPower = bins[markBin]
        let spacePower = bins[spaceBin]
        guard markPower > threshold && spacePower > threshold else { continue }

        // Geometric mean: both mark and space must be strong
        let score = sqrt(markPower * spacePower)
        candidates.append((Double(markBin) * binWidth, score))
    }

    candidates.sort { $0.score > $1.score }

    // Deduplicate: keep strongest within shift distance (signals can't overlap)
    let dedupeDistance = max(50, shift * 0.6)
    var result: [SignalCandidate] = []
    for c in candidates {
        if result.allSatisfy({ abs($0.markFreq - c.freq) > dedupeDistance }) {
            let db: Float = c.score > 0 ? 10 * log10(c.score / max(noiseFloor, 1e-10)) : -100
            result.append(SignalCandidate(
                markFreq: c.freq, spaceFreq: c.freq - shift, powerDB: db))
        }
        if result.count >= 5 { break }
    }

    // Filter by spectral contrast: real RTTY has a dip between mark and space.
    // Broadband signals (PSK, noise) that coincidentally match the shift don't.
    result = result.filter { candidate in
        let markBin = Int(round(candidate.markFreq / binWidth))
        let spaceBin = Int(round(candidate.spaceFreq / binWidth))
        guard markBin > spaceBin + 4, spaceBin >= 0, markBin < bins.count else { return true }

        // Find minimum power in the valley between mark and space (skip edge bins)
        var valley: Float = .infinity
        for b in (spaceBin + 2)..<(markBin - 1) {
            valley = min(valley, bins[b])
        }
        guard valley < .infinity else { return true }

        // Require peaks to be at least 6 dB above the valley (factor of 4)
        let peakPower = min(bins[markBin], bins[spaceBin])
        return peakPower > valley * 4
    }

    return result
}

/// Find PSK signal candidates by looking for narrow spectral peaks.
func findPSKCandidates(
    bins: [Float], binWidth: Double,
    minFreq: Double = 200, maxFreq: Double = 3500
) -> [SignalCandidate] {
    let minBin = max(1, Int(ceil(minFreq / binWidth)))
    let maxBin = min(bins.count - 2, Int(floor(maxFreq / binWidth)))
    guard minBin < maxBin else { return [] }

    // Noise floor = median
    let sorted = Array(bins[minBin...maxBin]).sorted()
    let noiseFloor = sorted[sorted.count / 2]
    let threshold = noiseFloor * 5 // ~7 dB above noise

    // Find local maxima above threshold
    var candidates: [(freq: Double, power: Float)] = []
    for bin in (minBin + 1)..<maxBin {
        if bins[bin] > bins[bin - 1] && bins[bin] > bins[bin + 1] && bins[bin] > threshold {
            candidates.append((Double(bin) * binWidth, bins[bin]))
        }
    }

    candidates.sort { $0.power > $1.power }

    // Deduplicate: keep strongest within 30 Hz
    var result: [SignalCandidate] = []
    for c in candidates {
        if result.allSatisfy({ abs($0.markFreq - c.freq) > 30 }) {
            let db: Float = c.power > 0 ? 10 * log10(c.power / max(noiseFloor, 1e-10)) : -100
            result.append(SignalCandidate(markFreq: c.freq, spaceFreq: 0, powerDB: db))
        }
        if result.count >= 5 { break }
    }

    return result
}

// MARK: - Scoring

/// Score decoded text for RTTY plausibility (word structure, letter ratio, ham patterns).
func rttyScore(_ text: String) -> Double {
    guard text.count >= 3 else { return 0 }

    let words = text.split { " \r\n".contains($0) }.map(String.init)
    guard !words.isEmpty else { return 0 }

    let avgWordLen = Double(words.map(\.count).reduce(0, +)) / Double(words.count)
    let wordLenScore = (avgWordLen >= 2 && avgWordLen <= 8) ? 1.0 :
                       (avgWordLen >= 1 && avgWordLen <= 12) ? 0.5 : 0.1

    let letters = text.filter(\.isLetter).count
    let digits = text.filter(\.isNumber).count
    let symbols = text.filter { c in
        guard let a = c.asciiValue else { return false }
        return (a >= 33 && a < 48) || (a >= 58 && a < 65)
    }.count
    let letterRatio = Double(letters) / Double(max(1, letters + digits + symbols))
    let letterScore = min(1.0, letterRatio * 1.5)

    let upper = text.uppercased()
    var patternBonus = 0.0
    if upper.contains("CQ") { patternBonus += 0.3 }
    if upper.contains("DE ") { patternBonus += 0.2 }
    if upper.contains("QRZ") { patternBonus += 0.2 }
    if upper.contains("73") { patternBonus += 0.1 }
    patternBonus = min(1.0, patternBonus)

    let multiWordScore = words.count >= 2 ? 1.0 : 0.3

    return (wordLenScore * 0.25 + letterScore * 0.25 + patternBonus * 0.3 + multiWordScore * 0.2) * Double(text.count)
}

func textQuality(_ text: String) -> Double {
    guard !text.isEmpty else { return 0 }
    let good = text.filter { c in
        guard let a = c.asciiValue else { return false }
        return (a >= 32 && a < 127) || a == 10 || a == 13
    }.count
    return Double(good) / Double(text.count)
}

// MARK: - Decode Delegates

class RTTYDecodeDelegate: FSKDemodulatorDelegate {
    var decoded = ""
    func demodulator(_ d: FSKDemodulator, didDecode c: Character, atFrequency f: Double) {
        decoded.append(c)
    }
    func demodulator(_ d: FSKDemodulator, signalDetected: Bool, atFrequency f: Double) {}
}

class PSKDecodeDelegate: PSKDemodulatorDelegate {
    var decoded = ""
    func demodulator(_ d: PSKDemodulator, didDecode c: Character, atFrequency f: Double) {
        decoded.append(c)
    }
    func demodulator(_ d: PSKDemodulator, signalDetected: Bool, atFrequency f: Double) {}
}

// MARK: - Parallel Demodulation

struct DecodeResult {
    let frequency: Double
    let text: String
    let score: Double
    let quality: Double
}

/// Helper: run one RTTY demodulation pass and return (text, score, corrected frequency).
func rttyTrial(
    config: RTTYConfiguration, frequency: Double, samples: [Float],
    afc: Bool, inverted: Bool
) -> (text: String, score: Double, freq: Double) {
    let trialConfig = config.withCenterFrequency(frequency)
    let demod = FSKDemodulator(configuration: trialConfig)
    let delegate = RTTYDecodeDelegate()
    demod.delegate = delegate
    demod.afcEnabled = afc
    demod.polarityInverted = inverted
    demod.minCharacterConfidence = 0.3

    demod.process(samples: samples)

    let text = delegate.decoded
    let score = rttyScore(text)
    let freq = afc ? frequency + Double(demod.frequencyCorrection) : frequency
    return (text, score, freq)
}

/// Decode RTTY signals using a two-phase strategy:
///   Phase 1: AFC-enabled decode at FFT frequency (1-2 passes per candidate, parallel).
///   Phase 2: Fine sweep ±10 Hz for candidates with poor Phase 1 results (parallel).
func decodeRTTYSignals(
    candidates: [SignalCandidate], samples: [Float], sampleRate: Double,
    baudRate: Double = 45.45, shift: Double = 170, verbose: Bool
) -> [DecodeResult] {
    guard !candidates.isEmpty else { return [] }

    let config = RTTYConfiguration.standard
        .withSampleRate(sampleRate)
        .withBaudRate(baudRate)
        .withShift(shift)

    let minGoodScore = 5.0 // threshold for "good enough, skip fine sweep"

    // Phase 1: AFC decode at FFT frequency, both polarities (parallel across candidates)
    let p1Ptr = UnsafeMutablePointer<(text: String, score: Double, freq: Double)>
        .allocate(capacity: candidates.count)
    p1Ptr.initialize(repeating: ("", 0, 0), count: candidates.count)
    defer { p1Ptr.deinitialize(count: candidates.count); p1Ptr.deallocate() }

    DispatchQueue.concurrentPerform(iterations: candidates.count) { idx in
        let freq = candidates[idx].markFreq
        // Try normal polarity with AFC
        var best = rttyTrial(config: config, frequency: freq, samples: samples, afc: true, inverted: false)
        // Try inverted polarity
        let inv = rttyTrial(config: config, frequency: freq, samples: samples, afc: true, inverted: true)
        if inv.score > best.score { best = inv }
        p1Ptr[idx] = best
    }

    if verbose {
        print("  Phase 1 (AFC):")
        for i in 0..<candidates.count {
            let r = p1Ptr[i]
            print("    [\(i+1)] \(String(format: "%.0f", candidates[i].markFreq)) Hz → \(String(format: "%.0f", r.freq)) Hz, \(r.text.count) chars, score \(String(format: "%.1f", r.score))\(r.score >= minGoodScore ? " [good]" : "")")
        }
    }

    // Phase 2: Fine sweep for candidates with poor Phase 1 results
    // Flatten all (candidate, freq) trials into a single work list for better parallelization
    struct Trial {
        let candidateIdx: Int
        let frequency: Double
        let inverted: Bool
    }
    var trials: [Trial] = []
    var needsFineSweep = [Bool](repeating: false, count: candidates.count)

    for i in 0..<candidates.count {
        if p1Ptr[i].score < minGoodScore {
            needsFineSweep[i] = true
            let baseFreq = candidates[i].markFreq
            for freq in stride(from: baseFreq - 10, through: baseFreq + 10, by: 2.0) {
                trials.append(Trial(candidateIdx: i, frequency: freq, inverted: false))
                trials.append(Trial(candidateIdx: i, frequency: freq, inverted: true))
            }
        }
    }

    if !trials.isEmpty {
        if verbose {
            let sweepCount = needsFineSweep.filter { $0 }.count
            print("  Phase 2: fine sweep for \(sweepCount) candidate\(sweepCount == 1 ? "" : "s") (\(trials.count) trials)...")
        }

        let trialPtr = UnsafeMutablePointer<(text: String, score: Double, freq: Double)>
            .allocate(capacity: trials.count)
        trialPtr.initialize(repeating: ("", 0, 0), count: trials.count)
        defer { trialPtr.deinitialize(count: trials.count); trialPtr.deallocate() }

        DispatchQueue.concurrentPerform(iterations: trials.count) { i in
            let t = trials[i]
            trialPtr[i] = rttyTrial(
                config: config, frequency: t.frequency, samples: samples,
                afc: false, inverted: t.inverted)
        }

        // Merge Phase 2 results into Phase 1
        for i in 0..<trials.count {
            let cidx = trials[i].candidateIdx
            if trialPtr[i].score > p1Ptr[cidx].score {
                p1Ptr[cidx] = trialPtr[i]
            }
        }

        if verbose {
            print("  Phase 2 results:")
            for i in 0..<candidates.count where needsFineSweep[i] {
                let r = p1Ptr[i]
                print("    [\(i+1)] → \(String(format: "%.0f", r.freq)) Hz, \(r.text.count) chars, score \(String(format: "%.1f", r.score))")
            }
        }
    }

    // Collect results
    var results: [DecodeResult] = []
    for i in 0..<candidates.count {
        let r = p1Ptr[i]
        if !r.text.isEmpty {
            results.append(DecodeResult(
                frequency: r.freq, text: r.text,
                score: r.score, quality: textQuality(r.text)))
        }
    }
    return results.sorted { $0.score > $1.score }
}

/// Fine-tune and demodulate PSK signals at candidate frequencies in parallel.
/// For each candidate: frequency sweep ±10 Hz, then timing offset sweep at best frequency.
func decodePSKSignals(
    candidates: [SignalCandidate], samples: [Float], sampleRate: Double,
    verbose: Bool
) -> [DecodeResult] {
    guard !candidates.isEmpty else { return [] }

    let baudRate = 31.25
    let samplesPerSymbol = Int(sampleRate / baudRate)

    let resultPtr = UnsafeMutablePointer<DecodeResult?>.allocate(capacity: candidates.count)
    resultPtr.initialize(repeating: nil, count: candidates.count)
    defer {
        resultPtr.deinitialize(count: candidates.count)
        resultPtr.deallocate()
    }

    DispatchQueue.concurrentPerform(iterations: candidates.count) { idx in
        let candidate = candidates[idx]
        var bestText = ""
        var bestFreq = candidate.markFreq

        // Phase 1: Frequency sweep ±10 Hz in 2 Hz steps
        for freq in stride(from: candidate.markFreq - 10, through: candidate.markFreq + 10, by: 2.0) {
            let pskConfig = PSKConfiguration(
                modulationType: .bpsk, baudRate: baudRate,
                centerFrequency: freq, sampleRate: sampleRate)
            let demod = PSKDemodulator(configuration: pskConfig)
            let delegate = PSKDecodeDelegate()
            demod.delegate = delegate
            demod.squelchLevel = 0.0

            demod.process(samples: samples)

            if delegate.decoded.count > bestText.count {
                bestText = delegate.decoded
                bestFreq = freq
            }
        }

        // Phase 2: Timing offset sweep at best frequency
        if !bestText.isEmpty {
            let step = max(1, samplesPerSymbol / 16)
            for offsetIdx in 0..<16 {
                let skip = offsetIdx * step
                guard skip < samples.count else { continue }
                let offsetSamples = Array(samples.dropFirst(skip))

                let pskConfig = PSKConfiguration(
                    modulationType: .bpsk, baudRate: baudRate,
                    centerFrequency: bestFreq, sampleRate: sampleRate)
                let demod = PSKDemodulator(configuration: pskConfig)
                let delegate = PSKDecodeDelegate()
                demod.delegate = delegate
                demod.squelchLevel = 0.0

                demod.process(samples: offsetSamples)

                if delegate.decoded.count > bestText.count {
                    bestText = delegate.decoded
                }
            }
        }

        if verbose {
            print("  [\(idx + 1)] \(String(format: "%.0f", candidate.markFreq)) Hz → \(String(format: "%.0f", bestFreq)) Hz, \(bestText.count) chars")
        }

        resultPtr[idx] = DecodeResult(
            frequency: bestFreq, text: bestText,
            score: Double(bestText.count), quality: textQuality(bestText))
    }

    var results: [DecodeResult] = []
    for i in 0..<candidates.count {
        if let r = resultPtr[i], !r.text.isEmpty {
            results.append(r)
        }
    }
    return results.sorted { $0.score > $1.score }
}

// MARK: - Display

func printCandidates(_ candidates: [SignalCandidate], mode: String) {
    print("  Found \(candidates.count) candidate signal\(candidates.count == 1 ? "" : "s"):")
    if mode == "rtty" {
        for (i, c) in candidates.enumerated() {
            print("    \(i + 1). Mark \(String(format: "%.0f", c.markFreq)) Hz / Space \(String(format: "%.0f", c.spaceFreq)) Hz  (\(String(format: "+%.0f", c.powerDB)) dB)")
        }
    } else {
        for (i, c) in candidates.enumerated() {
            print("    \(i + 1). \(String(format: "%.0f", c.markFreq)) Hz  (\(String(format: "+%.0f", c.powerDB)) dB)")
        }
    }
}

func printable(_ text: String) -> String {
    text.map { c -> String in
        if let a = c.asciiValue, a >= 32 && a < 127 { return String(c) }
        else if c == "\n" { return "\n" }
        else if c == "\r" { return "" }
        else { return "." }
    }.joined()
}

func printSpectrum(bins: [Float], binWidth: Double, candidates: [SignalCandidate]) {
    let maxFreq = 4000.0
    let maxBin = min(bins.count - 1, Int(maxFreq / binWidth))
    guard maxBin > 0 else { return }

    // Convert to dB
    let dbValues = (0...maxBin).map { bins[$0] > 0 ? 10 * log10(bins[$0]) : Float(-100) }
    let peakDB = dbValues.max() ?? 0
    let floorDB = peakDB - 60

    let width = 60
    let binsPerCol = max(1, (maxBin + 1) / width)

    // Downsample to display width
    var display = [Float](repeating: -100, count: width)
    for col in 0..<width {
        let startBin = col * binsPerCol
        let endBin = min(startBin + binsPerCol, maxBin + 1)
        var peak: Float = -100
        for b in startBin..<endBin {
            peak = max(peak, dbValues[b])
        }
        display[col] = peak
    }

    // Mark candidate columns
    var markedCols = Set<Int>()
    for c in candidates {
        let col = Int(c.markFreq / maxFreq * Double(width))
        if col >= 0 && col < width { markedCols.insert(col) }
    }

    let blocks = [" ", "\u{2581}", "\u{2582}", "\u{2583}", "\u{2584}", "\u{2585}", "\u{2586}", "\u{2587}", "\u{2588}"]

    print("\n  Spectrum (0\u{2013}\(Int(maxFreq)) Hz):")
    var line = ""
    for col in 0..<width {
        let normalized = max(0, min(1, (display[col] - floorDB) / (peakDB - floorDB)))
        let blockIdx = Int(normalized * Float(blocks.count - 1))
        line += markedCols.contains(col) ? "\u{25BC}" : blocks[blockIdx]
    }
    print("  0 Hz \u{2502}\(line)\u{2502} \(Int(maxFreq)) Hz")
    if !candidates.isEmpty {
        print("        \u{25BC} = detected signal")
    }
}

// MARK: - Argument Parsing

func printUsage() {
    let usage = """
    Usage: DecodeWAV <file.wav> [options]

    Options:
      --mode rtty|psk    Force decode mode (default: auto-detect)
      --shift <Hz>       RTTY shift in Hz (default: 170)
      --baud <rate>      RTTY baud rate (default: 45.45)
      --verbose, -v      Show scan details and spectrum
      --help, -h         Show this help
    """
    fputs(usage + "\n", stderr)
}

var wavPath: String?
var forcedMode: String?
var shift = 170.0
var baudRate = 45.45
var verbose = false

var args = Array(CommandLine.arguments.dropFirst())
var argIdx = 0
while argIdx < args.count {
    switch args[argIdx] {
    case "--mode":
        guard argIdx + 1 < args.count else { fputs("Error: --mode requires a value\n", stderr); exit(1) }
        forcedMode = args[argIdx + 1].lowercased()
        argIdx += 2
    case "--shift":
        guard argIdx + 1 < args.count else { fputs("Error: --shift requires a value\n", stderr); exit(1) }
        shift = Double(args[argIdx + 1]) ?? 170
        argIdx += 2
    case "--baud":
        guard argIdx + 1 < args.count else { fputs("Error: --baud requires a value\n", stderr); exit(1) }
        baudRate = Double(args[argIdx + 1]) ?? 45.45
        argIdx += 2
    case "--verbose", "-v":
        verbose = true
        argIdx += 1
    case "--help", "-h":
        printUsage()
        exit(0)
    default:
        if args[argIdx].hasPrefix("-") {
            fputs("Unknown option: \(args[argIdx])\n", stderr)
            printUsage()
            exit(1)
        }
        wavPath = args[argIdx]
        argIdx += 1
    }
}

guard let path = wavPath else {
    fputs("Error: no input file specified\n", stderr)
    printUsage()
    exit(1)
}

if let m = forcedMode, m != "rtty" && m != "psk" {
    fputs("Error: unknown mode '\(m)' (use rtty or psk)\n", stderr)
    exit(1)
}

// MARK: - Main

let bar = String(repeating: "\u{2550}", count: 50)

print("DecodeWAV \u{2014} RTTY/PSK Audio Decoder")
print(bar)

// 1. Read WAV
let t0 = now()
print("\nReading: \(path)")
let (samples, sampleRate, channels, bits) = try readWAV(from: path)
let duration = Double(samples.count) / sampleRate
let formatName = bits == 32 ? "float32" : "int\(bits)"
print("  \(formatName), \(channels)ch, \(Int(sampleRate)) Hz, \(String(format: "%.1f", duration))s (\(samples.count.formatted()) samples)")
print("  Read in \(elapsed(t0))")

// 2. FFT spectrum analysis
print("\nScanning spectrum...", terminator: "")
fflush(stdout)
let t1 = now()
let fftSize = 8192
let (bins, binWidth, windowCount) = powerSpectrum(samples: samples, sampleRate: sampleRate, fftSize: fftSize)
print(" done (\(elapsed(t1)))")
print("  \(fftSize)-point FFT, \(String(format: "%.1f", binWidth)) Hz/bin, \(windowCount) windows averaged")

// 3. Find candidates for both modes
let rttyCands = findRTTYCandidates(bins: bins, binWidth: binWidth, shift: shift)
let pskCands = findPSKCandidates(bins: bins, binWidth: binWidth)

// 4. Decode
let t2 = now()
var mode: String
var results: [DecodeResult]

if let m = forcedMode {
    // Mode forced by user
    mode = m
    let candidates = mode == "rtty" ? rttyCands : pskCands

    if candidates.isEmpty {
        print("\n  No \(mode.uppercased()) signals detected in spectrum.")
        print("  Try the other mode, or verify the file contains valid signals.")
        exit(0)
    }

    printCandidates(candidates, mode: mode)
    if verbose { printSpectrum(bins: bins, binWidth: binWidth, candidates: candidates) }

    let signalWord = candidates.count == 1 ? "signal" : "signals"
    print("\nDecoding \(candidates.count) \(signalWord)...", terminator: "")
    fflush(stdout)

    if mode == "rtty" {
        results = decodeRTTYSignals(
            candidates: candidates, samples: samples, sampleRate: sampleRate,
            baudRate: baudRate, shift: shift, verbose: verbose)
    } else {
        results = decodePSKSignals(
            candidates: candidates, samples: samples, sampleRate: sampleRate,
            verbose: verbose)
    }
    print(" done (\(elapsed(t2)))")

} else {
    // Auto-detect: try both modes, keep the one with better results
    if rttyCands.isEmpty && pskCands.isEmpty {
        print("\n  No signals detected in spectrum.")
        print("  Try --mode rtty or --mode psk, or verify the file contains valid signals.")
        exit(0)
    }

    print("\nAuto-detecting mode...", terminator: "")
    fflush(stdout)

    var rttyResults: [DecodeResult] = []
    var pskResults: [DecodeResult] = []

    if !rttyCands.isEmpty {
        rttyResults = decodeRTTYSignals(
            candidates: rttyCands, samples: samples, sampleRate: sampleRate,
            baudRate: baudRate, shift: shift, verbose: false)
    }
    if !pskCands.isEmpty {
        pskResults = decodePSKSignals(
            candidates: pskCands, samples: samples, sampleRate: sampleRate,
            verbose: false)
    }

    // Compare using the same text-quality scoring function for both modes,
    // so we're comparing apples to apples (not RTTY score vs PSK char count).
    let rttyBestScore = rttyResults.first?.score ?? 0
    let pskBestText = pskResults.first?.text ?? ""
    let pskTextScore = rttyScore(pskBestText) // Score PSK output with same function

    if rttyBestScore >= pskTextScore && rttyBestScore > 0 {
        mode = "rtty"
        results = rttyResults
    } else if !pskResults.isEmpty {
        mode = "psk"
        results = pskResults
    } else {
        mode = "rtty"
        results = rttyResults
    }

    let candidates = mode == "rtty" ? rttyCands : pskCands
    print(" \(mode.uppercased()) (\(elapsed(t2)))")
    printCandidates(candidates, mode: mode)
    if verbose { printSpectrum(bins: bins, binWidth: binWidth, candidates: candidates) }
}

// 5. Display results
if results.isEmpty {
    print("\n  No decodable text found.")
    print("  The detected signals may be too weak or not \(mode.uppercased()).")
} else {
    for (i, r) in results.enumerated() {
        let divider = String(repeating: "\u{2500}", count: 50)
        print("\n\(divider)")
        print("Signal \(i + 1): \(String(format: "%.0f", r.frequency)) Hz | \(r.text.count) chars | score \(String(format: "%.1f", r.score)) | quality \(String(format: "%.0f%%", r.quality * 100))")
        print(divider)

        let clean = printable(r.text)
        // Word-wrap at 70 characters
        var pos = clean.startIndex
        while pos < clean.endIndex {
            let end = clean.index(pos, offsetBy: 70, limitedBy: clean.endIndex) ?? clean.endIndex
            print("  \(clean[pos..<end])")
            pos = end
        }
    }
}

print("\n\(bar)")
print("Total: \(elapsed(t0))")
