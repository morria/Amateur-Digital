//
//  FT8Modem.swift
//  AmateurDigitalCore
//
//  High-level FT8 TX/RX modem. Wraps the shared 8-GFSK physical layer
//  (GFSKDecoder, GFSKModulator) with FT8-specific CRC-14 verification
//  and 77-bit message packing/unpacking via FT8Codec.
//
//  RX: audio -> ring buffer -> UTC-aligned 15s decode -> GFSKDecoder ->
//      CRC-14 verify -> FT8Codec.unpack77 -> FT8Message callback
//  TX: message string -> FT8Codec.pack77 -> CRC-14 append -> LDPC encode ->
//      GFSKModulator -> audio samples
//
//  NOTE: FT8 uses an LDPC(174,91) code (77 msg + 14 CRC = 91 info bits).
//  The current LDPC174_87 code has K=87 (designed for JS8Call). For full FT8
//  support, the LDPC parity-check/generator tables need to be updated to
//  the (174,91) variant from WSJT-X. The RX/TX wiring is structurally correct
//  and will work once the proper FT8 LDPC tables are in place.
//

import Foundation

// MARK: - Delegate

public protocol FT8ModemDelegate: AnyObject {
    func modem(_ modem: FT8Modem, didDecode message: FT8Message, frequency: Double, snr: Double, timeOffset: Double)
    func modem(_ modem: FT8Modem, signalDetected detected: Bool, count: Int)
}

// MARK: - FT8 Modem

public final class FT8Modem {

    public weak var delegate: FT8ModemDelegate?

    /// Callback-based API (alternative to delegate)
    public var onMessageDecoded: ((FT8Message, Double, Double) -> Void)?

    public private(set) var signalDetected: Bool = false

    // MARK: - Configuration

    /// FT8 period is always 15 seconds
    public static let periodSeconds = 15

    /// Sample rate (external)
    private let sampleRate: Double = 48000.0

    /// Internal processing rate (12 kHz, matching GFSK pipeline)
    private let internalRate: Double = 12000.0

    /// Decimation factor: 48000 / 12000 = 4
    private var decimFactor: Int { Int(sampleRate / internalRate) }

    /// Frequency search range for sync candidates
    public var frequencyRange: (low: Double, high: Double) = (100, 4900)

    // MARK: - Ring Buffer (UTC-aligned, like JS8CallDemodulator)

    /// Ring buffer holds 60 seconds of audio at 48 kHz
    private static let ringBufferSeconds = 60
    private var ringBuffer: [Float] = []
    private var ringWritePos: Int = 0
    private var ringInitialized = false

    /// Track UTC decode cycle boundaries
    private var lastDecodeCycle: Int = -1

    /// Background queue for CPU-intensive LDPC decode
    private let decodeQueue = DispatchQueue(label: "com.amateurdigital.ft8", qos: .utility)
    private var isDecodeRunning = false

    // MARK: - Init

    public init() {}

    // MARK: - UTC Time Alignment

    /// FT8 uses 15-second periods aligned to UTC.
    private func currentUTCCycle() -> Int {
        let periodMs = Self.periodSeconds * 1000
        let msOfDay = Int(Date().timeIntervalSince1970 * 1000) % (86400 * 1000)
        return msOfDay / periodMs
    }

    /// Samples into the current 15-second period based on UTC.
    private func samplesIntoPeriod() -> Int {
        let periodMs = Self.periodSeconds * 1000
        let msOfDay = Int(Date().timeIntervalSince1970 * 1000) % (86400 * 1000)
        let msIntoPeriod = msOfDay % periodMs
        return Int(Double(msIntoPeriod) / 1000.0 * sampleRate)
    }

    // MARK: - RX: Process Audio

    /// Feed incoming audio samples at 48 kHz.
    /// Buffers internally and triggers decode at UTC 15-second boundaries.
    public func process(samples: [Float]) {
        // Lazy ring buffer allocation
        if ringBuffer.isEmpty {
            let ringSize = Self.ringBufferSeconds * Int(sampleRate)
            ringBuffer = [Float](repeating: 0, count: ringSize)
        }
        let ringSize = ringBuffer.count

        // Initialize write position from UTC on first call
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

        // Extract the most recent period's worth of samples
        let samplesPerPeriod = Int(sampleRate) * Self.periodSeconds
        let framesNeeded = min(samplesPerPeriod, ringSize)

        var chunk = [Float](repeating: 0, count: framesNeeded)
        let startPos = (ringWritePos - framesNeeded + ringSize) % ringSize
        for i in 0..<framesNeeded {
            chunk[i] = ringBuffer[(startPos + i) % ringSize]
        }

        isDecodeRunning = true
        decodeQueue.async { [weak self] in
            guard let self = self else { return }
            let results = self.decodeChunk(chunk)
            DispatchQueue.main.async {
                self.isDecodeRunning = false
                for (msg, freq, snr, timeOffset) in results {
                    self.delegate?.modem(self, didDecode: msg, frequency: freq, snr: snr, timeOffset: timeOffset)
                    self.onMessageDecoded?(msg, freq, snr)
                }
                let detected = !results.isEmpty
                if detected != self.signalDetected {
                    self.signalDetected = detected
                    self.delegate?.modem(self, signalDetected: detected, count: results.count)
                }
            }
        }
    }

    /// Directly decode a buffer of audio (for benchmarks / testing).
    public func decodeBuffer(_ samples: [Float]) -> [(FT8Message, Double, Double, Double)] {
        let dd = decimate(samples)
        return runFT8Decoder(dd: dd)
    }

    // MARK: - TX: Encode Message

    /// Encode an FT8 message string into audio samples at 48 kHz.
    ///
    /// Pipeline: message -> pack77 -> CRC-14 append -> LDPC encode -> GFSK modulate
    ///
    /// - Parameters:
    ///   - message: FT8 message text (e.g. "CQ W1AW FN42")
    ///   - frequency: Audio carrier frequency in Hz (default 1500)
    /// - Returns: Audio samples at 48 kHz, or empty array if packing fails
    public func encode(message: String, frequency: Double = 1500.0) -> [Float] {
        // Step 1: Pack message into 77 bits
        guard let bits77 = FT8Codec.pack77(message: message) else {
            return []
        }

        // Step 2: Compute and append CRC-14 to form 91-bit payload
        let crc = FT8Codec.crc14(messageBits: bits77)
        var bits91 = [UInt8](repeating: 0, count: 91)
        for i in 0..<77 { bits91[i] = bits77[i] }
        for i in 0..<14 {
            bits91[77 + i] = UInt8((crc >> (13 - i)) & 1)
        }

        // Step 3: LDPC encode (91 info bits -> 174-bit codeword)
        // NOTE: When LDPC174_87 is upgraded to (174,91) for FT8, pass all 91 bits.
        // Currently using the first 87 bits; TX will produce a valid codeword
        // for the (174,87) code but not the FT8-standard (174,91) code.
        let infoBits: [UInt8]
        if bits91.count <= 87 {
            infoBits = bits91 + [UInt8](repeating: 0, count: 87 - bits91.count)
        } else {
            // Truncate to K=87 for current LDPC code; full FT8 needs K=91
            infoBits = Array(bits91.prefix(87))
        }
        let codeword = LDPC174_87.encode(infoBits)

        // Step 4: Map codeword to 79 channel symbols via GFSKModulator
        let config = GFSKConfig.ft8.withCarrierFrequency(frequency)
        var modulator = GFSKModulator(config: config)
        let symbols = modulator.mapCodewordToSymbols(codeword)

        // Step 5: Generate audio at 48 kHz
        return modulator.generateAudio(symbols: symbols)
    }

    /// Encode with leading/trailing silence for VOX keying.
    public func encodeWithEnvelope(
        message: String,
        frequency: Double = 1500.0,
        preambleMs: Double = 0,
        postambleMs: Double = 200
    ) -> [Float] {
        let audio = encode(message: message, frequency: frequency)
        guard !audio.isEmpty else { return [] }

        let preSamples = Int(preambleMs / 1000.0 * sampleRate)
        let postSamples = Int(postambleMs / 1000.0 * sampleRate)

        var result = [Float](repeating: 0, count: preSamples + audio.count + postSamples)
        for i in 0..<audio.count {
            result[preSamples + i] = audio[i]
        }
        return result
    }

    // MARK: - Control

    public func reset() {
        if !ringBuffer.isEmpty {
            ringBuffer = [Float](repeating: 0, count: ringBuffer.count)
        }
        ringWritePos = 0
        ringInitialized = false
        lastDecodeCycle = -1
        signalDetected = false
        isDecodeRunning = false
    }

    // MARK: - Internal Decode Pipeline

    /// Decimate and decode a 15-second chunk.
    private func decodeChunk(_ samples48k: [Float]) -> [(FT8Message, Double, Double, Double)] {
        let dd = decimate(samples48k)
        return runFT8Decoder(dd: dd)
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

    /// Run the FT8 decode pipeline on decimated audio.
    /// Uses the shared GFSK sync search + symbol extraction + LDPC decode,
    /// then applies FT8-specific CRC-14 verification and 77-bit message unpacking.
    private func runFT8Decoder(dd: [Double]) -> [(FT8Message, Double, Double, Double)] {
        let config = GFSKConfig.ft8

        // FT8 sync search parameters
        let toneSpacing = config.toneSpacing  // 6.25 Hz
        let nstep = config.samplesPerSymbol / 4  // Quarter-symbol step
        let tstep = Double(nstep) / internalRate

        // Time search range: FT8 signals can arrive anywhere within the 15s window.
        // Search +/- 2.5 seconds around the expected start.
        let timeSearchRange = Int(2.5 / tstep)

        let syncSearch = GFSKSyncSearch(
            config: config,
            frequencyRange: frequencyRange,
            frequencyStep: toneSpacing / 2.0,
            timeSearchRange: timeSearchRange,
            timeStartOffset: 0,
            minSyncMetric: 1.5,
            maxCandidates: 50,
            dedupeHz: toneSpacing
        )

        let symbolExtractor = GFSKSymbolExtractor(config: config, minSyncTones: 7)

        // Step 1: Find sync candidates
        let candidates = syncSearch.findCandidates(dd: dd)
        guard !candidates.isEmpty else { return [] }

        // Step 2: Multi-pass decode with FT8-specific CRC and unpacking
        var decoded: [(FT8Message, Double, Double, Double)] = []
        var decodedHashes: Set<String> = []  // Deduplicate by display text

        let npass = 4  // Full decode depth

        for ipass in 0..<npass {
            if ipass > 0 && decoded.isEmpty { break }

            for candidate in candidates {
                guard let extraction = symbolExtractor.extract(dd: dd, candidate: candidate) else {
                    continue
                }

                let osdDepth = 3

                for decodePass in 0..<4 {
                    var passLLR: [Double]
                    switch decodePass {
                    case 0:
                        passLLR = extraction.llr
                    case 1:
                        passLLR = symbolExtractor.computeLogLLRs(dataSpectra: extraction.dataSpectra)
                    case 2:
                        passLLR = extraction.llr
                        for i in 0..<24 { passLLR[i] = 0 }
                    case 3:
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

                    // FT8-specific: Verify CRC-14 on the decoded bits.
                    // The LDPC decoder returns K bits. For FT8, we need at least 91 bits
                    // (77 message + 14 CRC). If K < 91, pad with zeros for CRC check.
                    let decodedBits: [UInt8]
                    if result.bits.count >= 91 {
                        decodedBits = Array(result.bits.prefix(91))
                    } else {
                        decodedBits = result.bits + [UInt8](repeating: 0, count: 91 - result.bits.count)
                    }
                    guard FT8Codec.verifyCRC14(decodedBits) else { continue }

                    // FT8-specific: Unpack 77-bit message
                    let bits77 = Array(decodedBits.prefix(77))
                    guard let ft8Message = FT8Codec.unpack77(bits: bits77) else { continue }

                    // SNR estimate from sync correlation strength
                    let snr = 10.0 * log10(max(candidate.syncStrength - 1.0, 0.001)) - 27.0
                    let clampedSNR = max(snr, -28.0)

                    // Deduplicate
                    let hash = ft8Message.displayText
                    guard !decodedHashes.contains(hash) else { continue }
                    decodedHashes.insert(hash)

                    decoded.append((ft8Message, candidate.frequency, clampedSNR, candidate.timeOffset))
                    break  // Got a decode for this candidate, move to next
                }
            }
        }

        return decoded
    }
}
