//
//  JS8CallDemodulator.swift
//  AmateurDigitalCore
//
//  JS8Call decoder: audio -> spectrogram -> Costas sync -> LDPC decode -> text.
//  Handles noise, fading, frequency drift, clock offset, and multi-signal.
//

import Foundation

// MARK: - Decoded Frame

/// A successfully decoded JS8Call frame.
public struct JS8CallFrame: Equatable, Sendable {
    public let message: String
    public let frameType: Int
    public let frequency: Double
    public let timeOffset: Double
    public let snr: Double
    public let quality: Double
    public let submodeName: String
}

// MARK: - Delegate Protocol

public protocol JS8CallDemodulatorDelegate: AnyObject {
    func demodulator(_ demodulator: JS8CallDemodulator, didDecode frame: JS8CallFrame)
    func demodulator(_ demodulator: JS8CallDemodulator, signalDetected detected: Bool, count: Int)
}

// MARK: - Demodulator

/// Internal candidate signal detected during sync search.
private struct JS8SyncCandidate {
    var freq: Double
    var timeOffset: Double
    var sync: Double
}

public final class JS8CallDemodulator {

    public weak var delegate: JS8CallDemodulatorDelegate?
    public private(set) var currentConfiguration: JS8CallConfiguration
    public private(set) var signalDetected: Bool = false
    public var frequencyRange: (low: Double, high: Double) = (100, 4900)

    /// Ring buffer of audio at the external sample rate (48 kHz).
    /// Size = 60 seconds, matching JS8Call's ring buffer convention.
    private static let ringBufferSeconds = 60
    private var ringBuffer: [Float] = []
    private var ringWritePos: Int = 0
    private var ringInitialized = false

    private let internalRate = JS8CallConstants.internalSampleRate
    private let decimFactor = JS8CallConstants.decimationFactor

    /// Background queue for CPU-intensive decode work.
    private let decodeQueue = DispatchQueue(label: "com.amateurdigital.js8call", qos: .userInitiated)
    private var isDecodeRunning = false

    /// Tracking decode cycle boundaries (UTC-aligned)
    private var lastDecodeCycle: Int = -1

    public init(configuration: JS8CallConfiguration = .standard) {
        self.currentConfiguration = configuration
        let ringSize = Self.ringBufferSeconds * Int(configuration.sampleRate)
        self.ringBuffer = [Float](repeating: 0, count: ringSize)
    }

    // MARK: - UTC Time Alignment

    /// Compute which decode cycle we are in, based on UTC time.
    /// Cycles are aligned to UTC period boundaries (e.g., 0s, 15s, 30s, 45s for Normal).
    private func currentUTCCycle() -> Int {
        let periodMs = currentConfiguration.submode.period * 1000
        let msOfDay = Int(Date().timeIntervalSince1970 * 1000) % (86400 * 1000)
        return msOfDay / periodMs
    }

    /// Compute how many samples into the current period we are, based on UTC.
    private func samplesIntoPeriod() -> Int {
        let periodMs = currentConfiguration.submode.period * 1000
        let msOfDay = Int(Date().timeIntervalSince1970 * 1000) % (86400 * 1000)
        let msIntoPeriod = msOfDay % periodMs
        return Int(Double(msIntoPeriod) / 1000.0 * currentConfiguration.sampleRate)
    }

    /// Process incoming audio samples at the external sample rate (48 kHz).
    /// Writes into a ring buffer and triggers decode at UTC period boundaries.
    public func process(samples: [Float]) {
        let ringSize = ringBuffer.count

        // Initialize ring buffer write position based on UTC on first call
        if !ringInitialized {
            ringWritePos = samplesIntoPeriod() % ringSize
            lastDecodeCycle = currentUTCCycle()
            ringInitialized = true
        }

        // Write samples into ring buffer
        for sample in samples {
            ringBuffer[ringWritePos % ringSize] = sample
            ringWritePos = (ringWritePos + 1) % ringSize
        }

        // Check if we've crossed a UTC period boundary
        let cycle = currentUTCCycle()
        guard cycle != lastDecodeCycle else { return }
        lastDecodeCycle = cycle

        // Don't queue if a decode is already running
        guard !isDecodeRunning else { return }

        // Extract the most recent period's worth of samples from the ring buffer.
        // We need framesNeeded samples ending at the current write position.
        let samplesPerPeriod = Int(currentConfiguration.sampleRate) * currentConfiguration.submode.period
        let framesNeeded = min(samplesPerPeriod, ringSize)

        var chunk = [Float](repeating: 0, count: framesNeeded)
        let startPos = (ringWritePos - framesNeeded + ringSize) % ringSize
        for i in 0..<framesNeeded {
            chunk[i] = ringBuffer[(startPos + i) % ringSize]
        }

        isDecodeRunning = true
        decodeQueue.async { [weak self] in
            guard let self = self else { return }
            let frames = self.runDecoderFromChunk(chunk)
            DispatchQueue.main.async {
                self.isDecodeRunning = false
                for frame in frames {
                    self.delegate?.demodulator(self, didDecode: frame)
                }
                let detected = !frames.isEmpty
                if detected != self.signalDetected {
                    self.signalDetected = detected
                    self.delegate?.demodulator(self, signalDetected: detected, count: frames.count)
                }
            }
        }
    }

    /// Trigger decode on ring buffer contents regardless of timing.
    public func decode() {
        let samplesPerPeriod = Int(currentConfiguration.sampleRate) * currentConfiguration.submode.period
        let framesNeeded = min(samplesPerPeriod, ringBuffer.count)
        let startPos = (ringWritePos - framesNeeded + ringBuffer.count) % ringBuffer.count

        var chunk = [Float](repeating: 0, count: framesNeeded)
        for i in 0..<framesNeeded {
            chunk[i] = ringBuffer[(startPos + i) % ringBuffer.count]
        }

        decodeQueue.async { [weak self] in
            guard let self = self else { return }
            let frames = self.runDecoderFromChunk(chunk)
            DispatchQueue.main.async {
                for frame in frames {
                    self.delegate?.demodulator(self, didDecode: frame)
                }
            }
        }
    }

    /// Directly decode a buffer of audio (at external sample rate). Used by benchmark.
    public func decodeBuffer(_ samples: [Float]) -> [JS8CallFrame] {
        let dd = decimate(samples)
        return runDecoder(dd: dd)
    }

    public func reset() {
        ringBuffer = [Float](repeating: 0, count: ringBuffer.count)
        ringWritePos = 0
        ringInitialized = false
        lastDecodeCycle = -1
        signalDetected = false
        isDecodeRunning = false
    }

    public func tune(to frequency: Double) {
        currentConfiguration = currentConfiguration.withCarrierFrequency(frequency)
    }

    // MARK: - Internal Decode Pipeline

    /// Decimate and decode a chunk. Called from background queue.
    private func runDecoderFromChunk(_ samples48k: [Float]) -> [JS8CallFrame] {
        let dd = decimate(samples48k)
        return runDecoder(dd: dd)
    }

    /// Decimate 48 kHz -> 12 kHz with simple averaging (low-pass).
    private func decimate(_ samples: [Float]) -> [Double] {
        let n = samples.count / decimFactor
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sum = 0.0
            for j in 0..<decimFactor {
                sum += Double(samples[i * decimFactor + j])
            }
            out[i] = sum / Double(decimFactor)
        }
        return out
    }

    /// Main decoder: multi-pass Costas sync + LDPC decode.
    /// Uses Goertzel filters at exact tone frequencies to avoid FFT bin alignment issues.
    private func runDecoder(dd: [Double]) -> [JS8CallFrame] {
        let sub = currentConfiguration.submode
        let nsps = sub.nsps
        let nstep = sub.nstep
        let nmax = dd.count
        let costas = sub.costas
        let nssy = nsps / nstep
        let toneSpacing = sub.toneSpacing
        let twopi = 2.0 * Double.pi

        guard nmax > nsps * JS8CallConstants.NN else { return [] }

        let nhsym = nmax / nstep - 3
        guard nhsym > 0 else { return [] }

        let tstep = Double(nstep) / internalRate
        let jstrt = Int((sub.startDelay / tstep) + 0.5)

        // Goertzel-based sync: compute power at 8 tones for each carrier frequency.
        // Search carriers in toneSpacing steps across the passband.
        let freqStep = toneSpacing / 2.0  // Half-tone steps for better frequency resolution
        let minFreq = max(frequencyRange.low, 100.0)
        let maxFreq = min(frequencyRange.high, internalRate / 2.0 - 8.0 * toneSpacing)

        // Pre-convert dd to Float for Goertzel (it expects [Float])
        let ddFloat = dd.map { Float($0) }

        var candidates: [JS8SyncCandidate] = []

        var carrierFreq = minFreq
        while carrierFreq <= maxFreq {
            // Compute Goertzel power at 8 tones for each time step
            var tonePower = [[Double]](repeating: [Double](repeating: 0, count: 8), count: nhsym)

            for tone in 0..<8 {
                let freq = carrierFreq + Double(tone) * toneSpacing
                for j in 0..<nhsym {
                    let start = j * nstep
                    guard start + nstep <= nmax else { break }
                    // Inline Goertzel for speed
                    let k = freq * Double(nstep) / internalRate
                    let coeff = Float(2.0 * cos(twopi * k / Double(nstep)))
                    var s0: Float = 0, s1: Float = 0, s2: Float = 0
                    for i in 0..<nstep {
                        s0 = ddFloat[start + i] + coeff * s1 - s2
                        s2 = s1; s1 = s0
                    }
                    tonePower[j][tone] = Double(s1 * s1 + s2 * s2 - coeff * s1 * s2)
                }
            }

            // Search time offsets for Costas sync
            var bestSync = 0.0
            var bestJOff = 0

            for jOff in -sub.jz...sub.jz {
                var ta = 0.0, tb = 0.0, tc = 0.0
                var t0a = 0.0, t0b = 0.0, t0c = 0.0

                for n in 0..<7 {
                    let ka = jOff + jstrt + nssy * n
                    if ka >= 0 && ka < nhsym {
                        ta += tonePower[ka][costas.a[n]]
                        for t in 0..<7 { t0a += tonePower[ka][t] }
                    }
                    let kb = jOff + jstrt + nssy * (n + 36)
                    if kb >= 0 && kb < nhsym {
                        tb += tonePower[kb][costas.b[n]]
                        for t in 0..<7 { t0b += tonePower[kb][t] }
                    }
                    let kc = jOff + jstrt + nssy * (n + 72)
                    if kc >= 0 && kc < nhsym {
                        tc += tonePower[kc][costas.c[n]]
                        for t in 0..<7 { t0c += tonePower[kc][t] }
                    }
                }

                let bg_abc = (t0a + t0b + t0c - ta - tb - tc) / 6.0
                let sync_abc = bg_abc > 0 ? (ta + tb + tc) / bg_abc : 0
                let bg_ab = (t0a + t0b - ta - tb) / 6.0
                let sync_ab = bg_ab > 0 ? (ta + tb) / bg_ab : 0
                let bg_bc = (t0b + t0c - tb - tc) / 6.0
                let sync_bc = bg_bc > 0 ? (tb + tc) / bg_bc : 0

                let sync = max(sync_abc, sync_ab, sync_bc)
                if sync > bestSync { bestSync = sync; bestJOff = jOff }
            }

            if bestSync >= JS8CallConstants.asyncMin {
                candidates.append(JS8SyncCandidate(
                    freq: carrierFreq,
                    timeOffset: Double(bestJOff + jstrt) * tstep,
                    sync: bestSync
                ))
            }

            carrierFreq += freqStep
        }

        // Sort by sync strength (descending)
        candidates.sort { $0.sync > $1.sync }

        // Deduplicate (keep stronger within dedupeHz)
        let dedupeHz = sub.dedupeHz
        var filtered: [JS8SyncCandidate] = []
        for c in candidates {
            if !filtered.contains(where: { abs($0.freq - c.freq) < dedupeHz }) {
                filtered.append(c)
            }
        }
        candidates = Array(filtered.prefix(JS8CallConstants.maxCandidates))

        // Decode each candidate
        var decoded: [JS8CallFrame] = []
        var ddMutable = dd  // For signal subtraction

        let ndepth = currentConfiguration.decodeDepth
        let npass = ndepth >= 3 ? 4 : (ndepth >= 2 ? 3 : 1)

        for ipass in 0..<npass {
            // Re-sync on passes 2+ if we had decodes
            if ipass > 0 && decoded.isEmpty { break }

            // For multi-pass, re-use the initial candidates (signal subtraction
            // modifies ddMutable but we decode at the same frequencies).
            let candidateList = candidates

            for cand in candidateList {
                if let frame = decodeSingleJS8SyncCandidate(
                    dd: &ddMutable, candidate: cand, sub: sub,
                    ipass: ipass, ndepth: ndepth, subtract: ipass < npass - 1
                ) {
                    // Dedupe across passes
                    if !decoded.contains(where: { $0.message == frame.message }) {
                        decoded.append(frame)
                    }
                }
            }
        }

        return decoded
    }

    // MARK: - Single Candidate Decode

    private func decodeSingleJS8SyncCandidate(
        dd: inout [Double], candidate: JS8SyncCandidate,
        sub: JS8CallSubmode, ipass: Int, ndepth: Int, subtract: Bool
    ) -> JS8CallFrame? {
        let nsps = sub.nsps
        let costas = sub.costas
        let twopi = 2.0 * Double.pi
        let twopiOverSR = twopi / internalRate

        let f1 = candidate.freq
        let t0 = candidate.timeOffset
        let symStartBase = Int(t0 * internalRate)

        // Extract 79 symbol spectra using DFT at 8 tone frequencies
        var s2 = [[Double]](repeating: [Double](repeating: 0, count: 8), count: JS8CallConstants.NN)

        for k in 0..<JS8CallConstants.NN {
            let symStart = symStartBase + k * nsps
            guard symStart >= 0 && symStart + nsps <= dd.count else { continue }

            // Goertzel at each of the 8 tone frequencies (exact, no bin mapping)
            for tone in 0..<8 {
                let freq = f1 + Double(tone) * sub.toneSpacing
                let gk = freq * Double(nsps) / internalRate
                let coeff = Float(2.0 * cos(twopi * gk / Double(nsps)))
                var s0: Float = 0, s1: Float = 0, s2v: Float = 0
                for i in 0..<nsps {
                    s0 = Float(dd[symStart + i]) + coeff * s1 - s2v
                    s2v = s1; s1 = s0
                }
                s2[k][tone] = Double(s1 * s1 + s2v * s2v - coeff * s1 * s2v)
            }
        }

        // Hard sync quality check: count matching Costas tones
        var nsync = 0
        for k in 0..<7 {
            if k < s2.count {
                let peak0 = s2[k].enumerated().max(by: { $0.element < $1.element })?.offset ?? -1
                if peak0 == costas.a[k] { nsync += 1 }
            }
            if k + 36 < s2.count {
                let peak36 = s2[k + 36].enumerated().max(by: { $0.element < $1.element })?.offset ?? -1
                if peak36 == costas.b[k] { nsync += 1 }
            }
            if k + 72 < s2.count {
                let peak72 = s2[k + 72].enumerated().max(by: { $0.element < $1.element })?.offset ?? -1
                if peak72 == costas.c[k] { nsync += 1 }
            }
        }
        guard nsync > 6 else { return nil }  // Need at least 7 of 21

        // Extract 58 data symbols (skip Costas)
        var s1 = [[Double]](repeating: [Double](repeating: 0, count: 8), count: JS8CallConstants.ND)
        var j = 0
        for k in 0..<JS8CallConstants.NN {
            if k < 7 { continue }
            if k >= 36 && k <= 42 { continue }
            if k >= 72 { continue }  // Costas C starts at symbol 72
            if j < JS8CallConstants.ND {
                s1[j] = s2[k]
                j += 1
            }
        }

        // Compute soft bit metrics (LLRs)
        var llr = [Double](repeating: 0, count: JS8CallConstants.N)
        for j in 0..<JS8CallConstants.ND {
            let ps = s1[j]
            let r4 = max(ps[4], ps[5], ps[6], ps[7]) - max(ps[0], ps[1], ps[2], ps[3])
            let r2 = max(ps[2], ps[3], ps[6], ps[7]) - max(ps[0], ps[1], ps[4], ps[5])
            let r1 = max(ps[1], ps[3], ps[5], ps[7]) - max(ps[0], ps[2], ps[4], ps[6])
            llr[3 * j]     = r4
            llr[3 * j + 1] = r2
            llr[3 * j + 2] = r1
        }

        // Normalize: zero mean, unit variance, scale by 2.83
        let avg = llr.reduce(0, +) / Double(JS8CallConstants.N)
        let variance = llr.map { ($0 - avg) * ($0 - avg) }.reduce(0, +) / Double(JS8CallConstants.N)
        let sigma = sqrt(max(variance, 1e-10))
        let scalefac = 2.83
        for i in 0..<JS8CallConstants.N {
            llr[i] = scalefac * (llr[i] - avg) / sigma
        }

        // Multi-pass decoding (try different LLR versions)
        for decodePass in 0..<4 {
            var passLLR = llr
            switch decodePass {
            case 1:
                // Log-metric version
                for j in 0..<JS8CallConstants.ND {
                    let ps = s1[j].map { log(max($0, 1e-32)) }
                    let r4 = max(ps[4], ps[5], ps[6], ps[7]) - max(ps[0], ps[1], ps[2], ps[3])
                    let r2 = max(ps[2], ps[3], ps[6], ps[7]) - max(ps[0], ps[1], ps[4], ps[5])
                    let r1 = max(ps[1], ps[3], ps[5], ps[7]) - max(ps[0], ps[2], ps[4], ps[6])
                    passLLR[3 * j]     = r4
                    passLLR[3 * j + 1] = r2
                    passLLR[3 * j + 2] = r1
                }
                let a2 = passLLR.reduce(0, +) / Double(JS8CallConstants.N)
                let v2 = passLLR.map { ($0 - a2) * ($0 - a2) }.reduce(0, +) / Double(JS8CallConstants.N)
                let s2n = sqrt(max(v2, 1e-10))
                for i in 0..<JS8CallConstants.N { passLLR[i] = scalefac * (passLLR[i] - a2) / s2n }
            case 2:
                // Erase first 24 bits
                for i in 0..<24 { passLLR[i] = 0 }
            case 3:
                // Erase first 48 bits
                for i in 0..<48 { passLLR[i] = 0 }
            default:
                break
            }

            // LDPC decode
            let osdDepth = ndepth >= 3 ? 3 : 0
            guard let result = LDPC174_87.decode(
                llr: passLLR, maxBPIterations: 30, osdDepth: osdDepth
            ) else { continue }

            // Quality gates
            let hd = Double(result.nharderrors) + result.dmin
            if hd >= 60.0 { continue }
            if candidate.sync < 2.0 && result.nharderrors > 35 { continue }
            if ipass > 1 && result.nharderrors > 39 { continue }
            if decodePass == 3 && result.nharderrors > 30 { continue }

            // Verify CRC
            guard JS8CallCodec.verifyCRC(result.bits) else { continue }

            // Unpack message
            guard let unpacked = JS8CallCodec.unpack(result.bits) else { continue }

            // SNR estimate
            let snr = 10.0 * log10(max(candidate.sync - 1.0, 0.001)) - 27.0
            let quality = 1.0 - hd / 60.0

            // Signal subtraction (remove decoded signal from audio for next pass)
            if subtract {
                subtractSignal(dd: &dd, message: unpacked.message, frameType: unpacked.frameType,
                               sub: sub, freq: f1, timeOffset: t0)
            }

            return JS8CallFrame(
                message: unpacked.message,
                frameType: unpacked.frameType,
                frequency: f1,
                timeOffset: t0,
                snr: max(snr, -28),
                quality: max(0, min(1, quality)),
                submodeName: sub.name
            )
        }

        return nil
    }

    // MARK: - Signal Subtraction

    /// Reconstruct and subtract a decoded signal from the audio buffer.
    private func subtractSignal(
        dd: inout [Double], message: String, frameType: Int,
        sub: JS8CallSubmode, freq: Double, timeOffset: Double
    ) {
        var mod = JS8CallModulator(configuration: currentConfiguration.withSubmode(sub).withCarrierFrequency(freq))
        let tones = mod.encodeTones(message: message, frameType: frameType)

        let nsps = sub.nsps
        let twopi = 2.0 * Double.pi
        let twopiOverSR = twopi / internalRate
        let symStartBase = Int(timeOffset * internalRate)

        // For each symbol, estimate amplitude and subtract
        var phi = 0.0
        for k in 0..<JS8CallConstants.NN {
            let symStart = symStartBase + k * nsps
            guard symStart >= 0 && symStart + nsps <= dd.count else { continue }

            let toneFreq = freq + Double(tones[k]) * sub.toneSpacing
            let dphi = twopiOverSR * toneFreq

            // Estimate complex amplitude via correlation
            var corrR = 0.0, corrI = 0.0
            for i in 0..<nsps {
                let p = dphi * Double(symStart + i)
                corrR += dd[symStart + i] * cos(p)
                corrI += dd[symStart + i] * sin(p)
            }
            let ampR = 2.0 * corrR / Double(nsps)
            let ampI = 2.0 * corrI / Double(nsps)

            // Subtract reconstructed signal
            for i in 0..<nsps {
                let p = dphi * Double(symStart + i)
                dd[symStart + i] -= ampR * cos(p) + ampI * sin(p)
            }
        }
    }

    // MARK: - Re-Sync (for multi-pass)

    private func findCandidates(
        dd: [Double], sub: JS8CallSubmode, window: [Double], fftSize: Int,
        df: Double, tstep: Double, ia: Int, ib: Int, jstrt: Int, toneStepBins: Double, nssy: Int, nhsym: Int
    ) -> [(freq: Double, timeOffset: Double, sync: Double)] {
        // Recompute spectrogram on subtracted audio
        let nstep = sub.nstep
        let resFftSize = FFTProcessor.nextPow2(sub.nfft1)
        let nh1 = resFftSize / 2
        let costas = sub.costas
        let nmax = dd.count

        var s = [[Double]](repeating: [Double](repeating: 0, count: nh1), count: nhsym)
        for j in 0..<nhsym {
            let ia_s = j * nstep
            let ib_s = ia_s + sub.nfft1
            guard ib_s <= nmax else { break }
            var re = [Double](repeating: 0, count: resFftSize)
            var im = [Double](repeating: 0, count: resFftSize)
            for i in 0..<sub.nfft1 { re[i] = dd[ia_s + i] * window[i] }
            FFTProcessor.fft(&re, &im)
            for i in 0..<nh1 { s[j][i] = re[i] * re[i] + im[i] * im[i] }
        }

        var results: [(freq: Double, timeOffset: Double, sync: Double)] = []

        for i in ia..<ib {
            var bestSync = 0.0
            var bestJOff = 0
            for jOff in -sub.jz...sub.jz {
                var ta = 0.0, tb = 0.0, tc = 0.0
                var t0a = 0.0, t0b = 0.0, t0c = 0.0

                for n in 0..<7 {
                    func toneBinR(_ base: Int, _ tone: Int) -> Int {
                        base + Int(Double(tone) * toneStepBins + 0.5)
                    }
                    let ka = jOff + jstrt + nssy * n
                    if ka >= 0 && ka < nhsym {
                        let tA = toneBinR(i, costas.a[n])
                        if tA >= 0 && tA < nh1 { ta += s[ka][tA] }
                        for tIdx in 0...6 { let t = toneBinR(i, tIdx); if t >= 0 && t < nh1 { t0a += s[ka][t] } }
                    }
                    let kb = jOff + jstrt + nssy * (n + 36)
                    if kb >= 0 && kb < nhsym {
                        let tB = toneBinR(i, costas.b[n])
                        if tB >= 0 && tB < nh1 { tb += s[kb][tB] }
                        for tIdx in 0...6 { let t = toneBinR(i, tIdx); if t >= 0 && t < nh1 { t0b += s[kb][t] } }
                    }
                    let kc = jOff + jstrt + nssy * (n + 72)
                    if kc >= 0 && kc < nhsym {
                        let tC = toneBinR(i, costas.c[n])
                        if tC >= 0 && tC < nh1 { tc += s[kc][tC] }
                        for tIdx in 0...6 { let t = toneBinR(i, tIdx); if t >= 0 && t < nh1 { t0c += s[kc][t] } }
                    }
                }

                let bg = (t0a + t0b + t0c - ta - tb - tc) / 6.0
                let sync = bg > 0 ? (ta + tb + tc) / bg : 0
                if sync > bestSync { bestSync = sync; bestJOff = jOff }
            }
            if bestSync >= JS8CallConstants.asyncMin {
                results.append((Double(i) * df, Double(bestJOff + jstrt) * tstep, bestSync))
            }
        }

        results.sort { $0.sync > $1.sync }
        return Array(results.prefix(JS8CallConstants.maxCandidates))
    }
}
