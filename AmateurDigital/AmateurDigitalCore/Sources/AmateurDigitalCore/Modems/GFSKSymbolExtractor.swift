//
//  GFSKSymbolExtractor.swift
//  AmateurDigitalCore
//
//  Extracts soft-bit LLRs from 8-GFSK audio at a given sync candidate position.
//  Handles symbol power measurement via Goertzel filters, hard sync quality check,
//  and Gray-coded soft-bit computation for the LDPC decoder.
//

import Foundation

/// Extracts symbol spectra and computes soft-bit log-likelihood ratios (LLRs)
/// from 8-GFSK audio at a known sync position.
///
/// Given a sync candidate (carrier frequency + time offset), this component:
/// 1. Measures power at 8 tone frequencies for all 79 symbols using Goertzel filters
/// 2. Validates sync quality by checking Costas tone matches (hard decision)
/// 3. Extracts the 58 data symbol power spectra (skipping sync symbols)
/// 4. Computes 174 soft-bit LLRs using the standard Gray-code demapping formula
///
/// The LLR computation uses the max-log approximation:
/// ```
/// r4 (MSB) = max(ps[4..7]) - max(ps[0..3])
/// r2 (mid) = max(ps[2,3,6,7]) - max(ps[0,1,4,5])
/// r1 (LSB) = max(ps[1,3,5,7]) - max(ps[0,2,4,6])
/// ```
public struct GFSKSymbolExtractor {

    public let config: GFSKConfig

    /// Minimum number of matching Costas sync tones (out of 21) required
    /// to attempt decode. Default: 7 (one-third of sync tones).
    public let minSyncTones: Int

    public init(config: GFSKConfig, minSyncTones: Int = 7) {
        self.config = config
        self.minSyncTones = minSyncTones
    }

    // MARK: - Symbol Extraction Result

    /// Result of symbol extraction: 174 LLRs and quality metrics.
    public struct ExtractionResult {
        /// 174 soft-bit log-likelihood ratios for the LDPC decoder.
        public let llr: [Double]
        /// 58 data symbol power spectra (8 tones each), for multi-pass decode strategies.
        public let dataSpectra: [[Double]]
        /// Number of Costas sync tones that matched (out of 21).
        public let syncToneMatches: Int
    }

    // MARK: - Extraction

    /// Extract symbol spectra and compute LLRs at a given sync candidate position.
    ///
    /// - Parameters:
    ///   - dd: Decimated audio at the internal sample rate.
    ///   - candidate: Sync candidate with frequency and time offset.
    /// - Returns: Extraction result with LLRs, or nil if sync quality is too low.
    public func extract(dd: [Double], candidate: GFSKSyncCandidate) -> ExtractionResult? {
        let nsps = config.samplesPerSymbol
        let costas = config.costasArrays
        let twopi = 2.0 * Double.pi
        let internalRate = config.internalRate

        let f1 = candidate.frequency
        let t0 = candidate.timeOffset
        let symStartBase = Int(t0 * internalRate)

        // Extract 79 symbol spectra using Goertzel at 8 tone frequencies
        var s2 = [[Double]](repeating: [Double](repeating: 0, count: 8), count: config.symbolCount)

        for k in 0..<config.symbolCount {
            let symStart = symStartBase + k * nsps
            guard symStart >= 0 && symStart + nsps <= dd.count else { continue }

            for tone in 0..<8 {
                let freq = f1 + Double(tone) * config.toneSpacing
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
        guard nsync >= minSyncTones else { return nil }

        // Extract 58 data symbols (skip Costas positions)
        var dataSpectra = [[Double]](repeating: [Double](repeating: 0, count: 8), count: config.dataSymbolCount)
        var j = 0
        for k in 0..<config.symbolCount {
            if k < 7 { continue }                   // Costas A
            if k >= 36 && k <= 42 { continue }       // Costas B
            if k >= 72 { continue }                   // Costas C
            if j < config.dataSymbolCount {
                dataSpectra[j] = s2[k]
                j += 1
            }
        }

        // Compute soft-bit LLRs using Gray-code demapping
        let llr = computeLLRs(dataSpectra: dataSpectra)

        return ExtractionResult(llr: llr, dataSpectra: dataSpectra, syncToneMatches: nsync)
    }

    // MARK: - LLR Computation

    /// Compute 174 soft-bit LLRs from 58 data symbol power spectra.
    ///
    /// Uses the max-log approximation for Gray-coded 8-FSK:
    /// - r4 (MSB): max(tones 4-7) - max(tones 0-3)
    /// - r2 (mid): max(tones 2,3,6,7) - max(tones 0,1,4,5)
    /// - r1 (LSB): max(tones 1,3,5,7) - max(tones 0,2,4,6)
    ///
    /// The result is normalized to zero mean, unit variance, then scaled by 2.83
    /// (empirically optimal for the LDPC decoder).
    public func computeLLRs(dataSpectra: [[Double]]) -> [Double] {
        let nd = config.dataSymbolCount
        let n = config.codewordLength
        var llr = [Double](repeating: 0, count: n)

        for j in 0..<nd {
            let ps = dataSpectra[j]
            let r4 = max(ps[4], ps[5], ps[6], ps[7]) - max(ps[0], ps[1], ps[2], ps[3])
            let r2 = max(ps[2], ps[3], ps[6], ps[7]) - max(ps[0], ps[1], ps[4], ps[5])
            let r1 = max(ps[1], ps[3], ps[5], ps[7]) - max(ps[0], ps[2], ps[4], ps[6])
            llr[3 * j]     = r4
            llr[3 * j + 1] = r2
            llr[3 * j + 2] = r1
        }

        // Normalize: zero mean, unit variance, scale by 2.83
        let avg = llr.reduce(0, +) / Double(n)
        let variance = llr.map { ($0 - avg) * ($0 - avg) }.reduce(0, +) / Double(n)
        let sigma = sqrt(max(variance, 1e-10))
        let scalefac = 2.83
        for i in 0..<n {
            llr[i] = scalefac * (llr[i] - avg) / sigma
        }

        return llr
    }

    /// Compute 174 LLRs using log-domain metrics (alternative for noise robustness).
    ///
    /// Same Gray-code demapping but applied to log(power) instead of raw power.
    /// This can improve decoding at very low SNR.
    public func computeLogLLRs(dataSpectra: [[Double]]) -> [Double] {
        let nd = config.dataSymbolCount
        let n = config.codewordLength
        var llr = [Double](repeating: 0, count: n)

        for j in 0..<nd {
            let ps = dataSpectra[j].map { log(max($0, 1e-32)) }
            let r4 = max(ps[4], ps[5], ps[6], ps[7]) - max(ps[0], ps[1], ps[2], ps[3])
            let r2 = max(ps[2], ps[3], ps[6], ps[7]) - max(ps[0], ps[1], ps[4], ps[5])
            let r1 = max(ps[1], ps[3], ps[5], ps[7]) - max(ps[0], ps[2], ps[4], ps[6])
            llr[3 * j]     = r4
            llr[3 * j + 1] = r2
            llr[3 * j + 2] = r1
        }

        let avg = llr.reduce(0, +) / Double(n)
        let variance = llr.map { ($0 - avg) * ($0 - avg) }.reduce(0, +) / Double(n)
        let sigma = sqrt(max(variance, 1e-10))
        let scalefac = 2.83
        for i in 0..<n {
            llr[i] = scalefac * (llr[i] - avg) / sigma
        }

        return llr
    }
}
