//
//  JS8CallDemodulator.swift
//  AmateurDigitalCore
//
//  JS8Call decoder: audio -> spectrogram -> Costas sync -> LDPC decode -> text.
//  Handles noise, fading, frequency drift, clock offset, and multi-signal.
//  Delegates the shared 8-GFSK physical layer to GFSKSyncSearch, GFSKSymbolExtractor,
//  and GFSKDecoder. Applies JS8Call-specific CRC and message unpacking on top.
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
    /// Uses .utility QoS to avoid starving the UI thread during the Goertzel sync search
    /// which can peg a core at 100% for 10-20 seconds.
    private let decodeQueue = DispatchQueue(label: "com.amateurdigital.js8call", qos: .utility)
    private var isDecodeRunning = false

    /// Tracking decode cycle boundaries (UTC-aligned)
    private var lastDecodeCycle: Int = -1

    public init(configuration: JS8CallConfiguration = .standard) {
        self.currentConfiguration = configuration
        // Ring buffer is allocated lazily on first process() call to avoid
        // blocking app launch with an 11.5MB allocation.
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
        // Lazy ring buffer allocation (11.5MB — don't allocate during app launch)
        if ringBuffer.isEmpty {
            let ringSize = Self.ringBufferSeconds * Int(currentConfiguration.sampleRate)
            ringBuffer = [Float](repeating: 0, count: ringSize)
        }
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

    /// Build the shared GFSK components configured for the current JS8Call submode.
    private func makeGFSKComponents() -> (syncSearch: GFSKSyncSearch, symbolExtractor: GFSKSymbolExtractor) {
        let sub = currentConfiguration.submode
        let gfskConfig = currentConfiguration.gfskConfig

        let nstep = sub.nstep
        let tstep = Double(nstep) / internalRate
        let jstrt = Int((sub.startDelay / tstep) + 0.5)

        let syncSearch = GFSKSyncSearch(
            config: gfskConfig,
            frequencyRange: frequencyRange,
            frequencyStep: sub.toneSpacing / 2.0,
            timeSearchRange: sub.jz,
            timeStartOffset: jstrt,
            minSyncMetric: JS8CallConstants.asyncMin,
            maxCandidates: JS8CallConstants.maxCandidates,
            dedupeHz: sub.dedupeHz
        )

        let symbolExtractor = GFSKSymbolExtractor(config: gfskConfig, minSyncTones: 7)

        return (syncSearch, symbolExtractor)
    }

    /// Main decoder: uses shared GFSK sync search + symbol extraction + LDPC decode,
    /// then applies JS8Call-specific CRC verification and message unpacking.
    private func runDecoder(dd: [Double]) -> [JS8CallFrame] {
        let sub = currentConfiguration.submode
        let ndepth = currentConfiguration.decodeDepth

        let (syncSearch, symbolExtractor) = makeGFSKComponents()

        // Step 1: Find sync candidates using the shared GFSK sync search
        let candidates = syncSearch.findCandidates(dd: dd)
        guard !candidates.isEmpty else { return [] }

        // Step 2: Decode each candidate with JS8Call-specific CRC and unpacking
        var decoded: [JS8CallFrame] = []
        var ddMutable = dd  // For signal subtraction

        let npass = ndepth >= 3 ? 4 : (ndepth >= 2 ? 3 : 1)

        for ipass in 0..<npass {
            // Re-sync on passes 2+ if we had decodes
            if ipass > 0 && decoded.isEmpty { break }

            for candidate in candidates {
                if let frame = decodeSingleCandidate(
                    dd: &ddMutable, candidate: candidate, symbolExtractor: symbolExtractor,
                    sub: sub, ipass: ipass, ndepth: ndepth, subtract: ipass < npass - 1
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

    /// Decode a single candidate: extract LLRs via the shared symbol extractor,
    /// run LDPC decode, then apply JS8Call CRC and message unpacking.
    private func decodeSingleCandidate(
        dd: inout [Double], candidate: GFSKSyncCandidate,
        symbolExtractor: GFSKSymbolExtractor,
        sub: JS8CallSubmode, ipass: Int, ndepth: Int, subtract: Bool
    ) -> JS8CallFrame? {
        // Use shared symbol extractor to get LLRs and data spectra
        guard let extraction = symbolExtractor.extract(dd: dd, candidate: candidate) else {
            return nil
        }

        let osdDepth = ndepth >= 3 ? 3 : 0

        // Multi-pass decoding (try different LLR versions)
        for decodePass in 0..<4 {
            var passLLR: [Double]
            switch decodePass {
            case 0:
                passLLR = extraction.llr
            case 1:
                // Log-metric version via the shared extractor
                passLLR = symbolExtractor.computeLogLLRs(dataSpectra: extraction.dataSpectra)
            case 2:
                // Erase first 24 bits
                passLLR = extraction.llr
                for i in 0..<24 { passLLR[i] = 0 }
            case 3:
                // Erase first 48 bits
                passLLR = extraction.llr
                for i in 0..<48 { passLLR[i] = 0 }
            default:
                passLLR = extraction.llr
            }

            // LDPC decode
            guard let result = LDPC174_87.decode(
                llr: passLLR, maxBPIterations: 30, osdDepth: osdDepth
            ) else { continue }

            // Quality gates
            let hd = Double(result.nharderrors) + result.dmin
            if hd >= 60.0 { continue }
            if candidate.syncStrength < 2.0 && result.nharderrors > 35 { continue }
            if ipass > 1 && result.nharderrors > 39 { continue }
            if decodePass == 3 && result.nharderrors > 30 { continue }

            // JS8Call-specific: Verify CRC-12 XOR 42
            guard JS8CallCodec.verifyCRC(result.bits) else { continue }

            // JS8Call-specific: Unpack message
            guard let unpacked = JS8CallCodec.unpack(result.bits) else { continue }

            // SNR estimate
            let snr = 10.0 * log10(max(candidate.syncStrength - 1.0, 0.001)) - 27.0
            let quality = 1.0 - hd / 60.0

            // Signal subtraction (remove decoded signal from audio for next pass)
            if subtract {
                subtractSignal(dd: &dd, message: unpacked.message, frameType: unpacked.frameType,
                               sub: sub, freq: candidate.frequency, timeOffset: candidate.timeOffset)
            }

            return JS8CallFrame(
                message: unpacked.message,
                frameType: unpacked.frameType,
                frequency: candidate.frequency,
                timeOffset: candidate.timeOffset,
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
        let mod = JS8CallModulator(configuration: currentConfiguration.withSubmode(sub).withCarrierFrequency(freq))
        let tones = mod.encodeTones(message: message, frameType: frameType)

        let nsps = sub.nsps
        let twopi = 2.0 * Double.pi
        let twopiOverSR = twopi / internalRate
        let symStartBase = Int(timeOffset * internalRate)

        // For each symbol, estimate amplitude and subtract
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
