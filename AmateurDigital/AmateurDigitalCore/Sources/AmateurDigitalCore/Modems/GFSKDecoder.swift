//
//  GFSKDecoder.swift
//  AmateurDigitalCore
//
//  Orchestrates the full 8-GFSK decode pipeline: sync search -> symbol extraction
//  -> multi-pass LDPC decode -> CRC verification. Returns raw decoded bits that
//  the caller interprets according to the protocol (FT8, JS8Call, etc.).
//

import Foundation

/// Decodes 8-GFSK transmissions from audio using the shared physical layer.
///
/// The decode pipeline:
/// 1. **Sync search**: Find candidate signals using Costas array correlation
/// 2. **Symbol extraction**: Measure tone powers and compute soft-bit LLRs
/// 3. **LDPC decode**: Multi-pass belief propagation + OSD fallback
/// 4. **Return raw bits**: The caller applies protocol-specific CRC and unpacking
///
/// This decoder is protocol-agnostic: it returns raw LDPC-decoded bits without
/// interpreting the message content. FT8 and JS8Call use different CRC schemes
/// and message packing, so CRC verification is left to the caller.
///
/// Usage:
/// ```swift
/// let decoder = GFSKDecoder(config: .ft8, ldpcMaxIterations: 30, osdDepth: 3)
/// let results = decoder.decode(dd: decimatedAudio)
/// for result in results {
///     // Apply FT8/JS8 CRC check and message unpacking
/// }
/// ```
public struct GFSKDecoder {

    public let config: GFSKConfig
    public let syncSearch: GFSKSyncSearch
    public let symbolExtractor: GFSKSymbolExtractor

    /// Maximum BP iterations for the LDPC decoder.
    public let ldpcMaxIterations: Int

    /// OSD search depth (0 = BP only, 1-5 = increasingly exhaustive OSD fallback).
    public let osdDepth: Int

    /// Decode depth controlling multi-pass behavior:
    /// - 1: Single pass, BP only
    /// - 2: Multi-pass with signal subtraction
    /// - 3: Multi-pass with OSD and signal subtraction
    public let decodeDepth: Int

    /// Quality gate: maximum hard-error distance for accepting a decode.
    public let maxHardDistance: Double

    public init(
        config: GFSKConfig,
        syncSearch: GFSKSyncSearch? = nil,
        symbolExtractor: GFSKSymbolExtractor? = nil,
        ldpcMaxIterations: Int = 30,
        osdDepth: Int = 3,
        decodeDepth: Int = 3,
        maxHardDistance: Double = 60.0
    ) {
        self.config = config
        self.syncSearch = syncSearch ?? GFSKSyncSearch(config: config)
        self.symbolExtractor = symbolExtractor ?? GFSKSymbolExtractor(config: config)
        self.ldpcMaxIterations = ldpcMaxIterations
        self.osdDepth = osdDepth
        self.decodeDepth = decodeDepth
        self.maxHardDistance = maxHardDistance
    }

    // MARK: - Decode Pipeline

    /// Decode all 8-GFSK signals in a buffer of decimated audio.
    ///
    /// - Parameter dd: Audio at the internal sample rate (e.g., 12 kHz).
    /// - Returns: Array of decoded results (may be empty if no signals found).
    public func decode(dd: [Double]) -> [GFSKDecodeResult] {
        // Step 1: Find sync candidates
        let candidates = syncSearch.findCandidates(dd: dd)
        guard !candidates.isEmpty else { return [] }

        // Step 2: Multi-pass decode
        let npass = decodeDepth >= 3 ? 4 : (decodeDepth >= 2 ? 3 : 1)
        var decoded: [GFSKDecodeResult] = []

        for ipass in 0..<npass {
            if ipass > 0 && decoded.isEmpty { break }

            for candidate in candidates {
                if let result = decodeSingleCandidate(
                    dd: dd, candidate: candidate, ipass: ipass
                ) {
                    // Deduplicate: skip if we already decoded the same bits
                    if !decoded.contains(where: { $0.messageBits == result.messageBits }) {
                        decoded.append(result)
                    }
                }
            }
        }

        return decoded
    }

    // MARK: - Single Candidate Decode

    /// Attempt to decode a single sync candidate through the full LDPC pipeline.
    ///
    /// Tries up to 4 LLR variants:
    /// 0. Standard power-domain LLRs
    /// 1. Log-domain LLRs (better at low SNR)
    /// 2. Standard LLRs with first 24 bits erased
    /// 3. Standard LLRs with first 48 bits erased
    private func decodeSingleCandidate(
        dd: [Double], candidate: GFSKSyncCandidate, ipass: Int
    ) -> GFSKDecodeResult? {
        // Extract symbol spectra and compute LLRs
        guard let extraction = symbolExtractor.extract(dd: dd, candidate: candidate) else {
            return nil
        }

        let effectiveOSD = osdDepth >= 3 ? 3 : 0

        // Multi-pass: try different LLR computation strategies
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
            guard let ldpcResult = LDPC174_87.decode(
                llr: passLLR, maxBPIterations: ldpcMaxIterations, osdDepth: effectiveOSD
            ) else { continue }

            // Quality gates
            let hd = Double(ldpcResult.nharderrors) + ldpcResult.dmin
            if hd >= maxHardDistance { continue }
            if candidate.syncStrength < 2.0 && ldpcResult.nharderrors > 35 { continue }
            if ipass > 1 && ldpcResult.nharderrors > 39 { continue }
            if decodePass == 3 && ldpcResult.nharderrors > 30 { continue }

            // SNR estimate from sync metric
            let snr = 10.0 * log10(max(candidate.syncStrength - 1.0, 0.001)) - 27.0

            return GFSKDecodeResult(
                messageBits: ldpcResult.bits,
                snr: max(snr, -28),
                timeOffset: candidate.timeOffset,
                frequency: candidate.frequency,
                ldpcHardErrors: ldpcResult.nharderrors,
                ldpcDistance: ldpcResult.dmin,
                decodePass: decodePass,
                syncStrength: candidate.syncStrength
            )
        }

        return nil
    }
}
