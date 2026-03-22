//
//  GFSKSyncSearch.swift
//  AmateurDigitalCore
//
//  Costas array sync detection for 8-GFSK modes (FT8, JS8Call, etc.).
//  Scans decimated audio for the 7-tone Costas pattern at multiple carrier
//  frequencies and time offsets, returning ranked candidate signals.
//

import Foundation

// MARK: - Sync Candidate

/// A candidate signal detected during Costas sync search.
public struct GFSKSyncCandidate: Sendable {
    /// Carrier frequency in Hz (at the internal sample rate).
    public let frequency: Double
    /// Time offset in seconds from the start of the audio buffer.
    public let timeOffset: Double
    /// Sync correlation strength (higher = more confident detection).
    public let syncStrength: Double

    public init(frequency: Double, timeOffset: Double, syncStrength: Double) {
        self.frequency = frequency
        self.timeOffset = timeOffset
        self.syncStrength = syncStrength
    }
}

// MARK: - Sync Search

/// Searches decimated audio for 8-GFSK signals using Costas array correlation.
///
/// The search uses Goertzel filters at exact tone frequencies to measure power
/// at each of 8 tones across the passband. For each candidate carrier frequency,
/// it correlates the measured tone powers against the known Costas sync pattern
/// at multiple time offsets.
///
/// The algorithm computes a sync metric as the ratio of Costas-tone power to
/// background power, which provides robust detection even at negative SNR.
public struct GFSKSyncSearch {

    public let config: GFSKConfig

    /// Frequency search range (Hz).
    public let frequencyRange: (low: Double, high: Double)

    /// Frequency step for the carrier search (Hz). Defaults to half-tone spacing.
    public let frequencyStep: Double

    /// Time search range in quarter-symbol steps (+/- this value).
    public let timeSearchRange: Int

    /// Time offset of the expected signal start, in quarter-symbol steps.
    /// For JS8Call this accounts for the submode's startDelay.
    public let timeStartOffset: Int

    /// Minimum sync metric for candidate acceptance.
    public let minSyncMetric: Double

    /// Maximum number of candidates to return.
    public let maxCandidates: Int

    /// Deduplication distance in Hz (candidates closer than this are merged).
    public let dedupeHz: Double

    public init(
        config: GFSKConfig,
        frequencyRange: (low: Double, high: Double) = (100, 4900),
        frequencyStep: Double? = nil,
        timeSearchRange: Int = 62,
        timeStartOffset: Int = 0,
        minSyncMetric: Double = 1.5,
        maxCandidates: Int = 300,
        dedupeHz: Double = 4.0
    ) {
        self.config = config
        self.frequencyRange = frequencyRange
        self.frequencyStep = frequencyStep ?? (config.toneSpacing / 2.0)
        self.timeSearchRange = timeSearchRange
        self.timeStartOffset = timeStartOffset
        self.minSyncMetric = minSyncMetric
        self.maxCandidates = maxCandidates
        self.dedupeHz = dedupeHz
    }

    // MARK: - Search

    /// Search decimated audio (at internal sample rate) for sync patterns.
    ///
    /// - Parameter dd: Audio samples at the internal sample rate (e.g., 12 kHz).
    /// - Returns: Candidates sorted by sync strength (descending), deduplicated.
    public func findCandidates(dd: [Double]) -> [GFSKSyncCandidate] {
        let nsps = config.samplesPerSymbol
        let nstep = config.quarterSymbolSamples
        let nmax = dd.count
        let costas = config.costasArrays
        let nssy = nsps / nstep  // Quarter-symbol steps per full symbol (4)
        let toneSpacing = config.toneSpacing
        let twopi = 2.0 * Double.pi
        let internalRate = config.internalRate

        guard nmax > nsps * config.symbolCount else { return [] }

        let nhsym = nmax / nstep - 3
        guard nhsym > 0 else { return [] }

        let tstep = Double(nstep) / internalRate
        let jstrt = timeStartOffset

        // Search carriers in frequency steps across the passband
        let minFreq = max(frequencyRange.low, 100.0)
        let maxFreq = min(frequencyRange.high, internalRate / 2.0 - 8.0 * toneSpacing)

        // Pre-convert to Float for Goertzel computation
        let ddFloat = dd.map { Float($0) }

        var candidates: [GFSKSyncCandidate] = []

        var carrierFreq = minFreq
        while carrierFreq <= maxFreq {
            // Compute Goertzel power at 8 tones for each time step.
            // Use full symbol period (nsps) for reliable sync detection.
            var tonePower = [[Double]](repeating: [Double](repeating: 0, count: 8), count: nhsym)

            let goertzelLen = nsps
            for tone in 0..<8 {
                let freq = carrierFreq + Double(tone) * toneSpacing
                let k = freq * Double(goertzelLen) / internalRate
                let coeff = Float(2.0 * cos(twopi * k / Double(goertzelLen)))
                for j in 0..<nhsym {
                    let start = j * nstep
                    guard start + goertzelLen <= nmax else { break }
                    var s0: Float = 0, s1: Float = 0, s2g: Float = 0
                    for i in 0..<goertzelLen {
                        s0 = ddFloat[start + i] + coeff * s1 - s2g
                        s2g = s1; s1 = s0
                    }
                    tonePower[j][tone] = Double(s1 * s1 + s2g * s2g - coeff * s1 * s2g)
                }
            }

            // Search time offsets for Costas sync
            var bestSync = 0.0
            var bestJOff = 0

            for jOff in -timeSearchRange...timeSearchRange {
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

                // Compute sync metric: ratio of Costas-tone power to background.
                // Try all three Costas pairs and take the best, allowing partial
                // decodes when one Costas array is corrupted.
                let bg_abc = (t0a + t0b + t0c - ta - tb - tc) / 6.0
                let sync_abc = bg_abc > 0 ? (ta + tb + tc) / bg_abc : 0
                let bg_ab = (t0a + t0b - ta - tb) / 6.0
                let sync_ab = bg_ab > 0 ? (ta + tb) / bg_ab : 0
                let bg_bc = (t0b + t0c - tb - tc) / 6.0
                let sync_bc = bg_bc > 0 ? (tb + tc) / bg_bc : 0

                let sync = max(sync_abc, sync_ab, sync_bc)
                if sync > bestSync { bestSync = sync; bestJOff = jOff }
            }

            if bestSync >= minSyncMetric {
                candidates.append(GFSKSyncCandidate(
                    frequency: carrierFreq,
                    timeOffset: Double(bestJOff + jstrt) * tstep,
                    syncStrength: bestSync
                ))
            }

            carrierFreq += frequencyStep
        }

        // Sort by sync strength (descending)
        candidates.sort { $0.syncStrength > $1.syncStrength }

        // Deduplicate: keep the stronger candidate when two are within dedupeHz
        var filtered: [GFSKSyncCandidate] = []
        for c in candidates {
            if !filtered.contains(where: { abs($0.frequency - c.frequency) < dedupeHz }) {
                filtered.append(c)
            }
        }

        return Array(filtered.prefix(maxCandidates))
    }
}
