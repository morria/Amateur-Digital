//
//  ModeClassifier.swift
//  AmateurDigitalCore
//
//  Scores each digital mode against extracted spectral features and produces
//  a ranked list with confidence scores and human-readable explanations.
//

import Foundation

/// Result of classifying a single mode's likelihood.
public struct ModeScore: Comparable, Equatable {
    public static func == (lhs: ModeScore, rhs: ModeScore) -> Bool {
        lhs.mode == rhs.mode && lhs.confidence == rhs.confidence
    }

    /// The digital mode
    public let mode: DigitalMode

    /// Confidence score (0.0 = impossible, 1.0 = certain)
    public let confidence: Float

    /// Human-readable explanation of why this mode was scored this way
    public let explanation: String

    /// Individual evidence items (positive and negative)
    public let evidence: [Evidence]

    public static func < (lhs: ModeScore, rhs: ModeScore) -> Bool {
        lhs.confidence < rhs.confidence
    }

    public init(mode: DigitalMode, confidence: Float, explanation: String, evidence: [Evidence]) {
        self.mode = mode
        self.confidence = confidence
        self.explanation = explanation
        self.evidence = evidence
    }
}

/// A piece of evidence for or against a mode.
public struct Evidence {
    /// Short label (e.g., "FSK pair detected", "Bandwidth too wide")
    public let label: String

    /// Impact on confidence: positive = supports this mode, negative = argues against
    public let impact: Float

    /// Detailed explanation
    public let detail: String

    public init(label: String, impact: Float, detail: String) {
        self.label = label
        self.impact = impact
        self.detail = detail
    }
}

/// Classifies digital modes by scoring spectral features against known mode characteristics.
public struct ModeClassifier {

    public init() {}

    /// Score all supported modes against the given spectral features.
    /// Returns scores sorted by confidence descending (most likely first).
    public func classify(features: SpectralFeatures) -> [ModeScore] {
        let modes: [DigitalMode] = [.rtty, .psk31, .bpsk63, .qpsk31, .qpsk63, .cw, .js8call]

        // Check if there's any real signal:
        // - Must have peaks > 10 dB above noise (ambient mic noise is 10-11 dB)
        // - Must not be broadband noise (spectral flatness < 0.8)
        // - Peak bandwidth must be < 100 Hz (ambient noise peaks are 100-300 Hz wide)
        let topPeak = features.peaks.first
        let hasStrongPeak = topPeak.map { $0.powerAboveNoise > 12 } ?? false
        let hasNarrowPeak = topPeak.map { $0.bandwidth3dB < 100 } ?? false
        let isNotBroadband = features.spectralFlatness < 0.8
        let hasSignal = hasStrongPeak && (hasNarrowPeak || isNotBroadband)

        var scores = modes.map { mode in
            var score = scoreMode(mode, features: features)
            // If no signal detected, cap all confidences low
            if !hasSignal {
                score = buildScore(mode: mode, rawScore: min(score.confidence, 0.1), evidence: score.evidence)
            }
            return score
        }

        scores.sort { $0.confidence > $1.confidence }
        return scores
    }

    /// Score noise/no-signal likelihood.
    public func scoreNoise(features f: SpectralFeatures) -> NoiseScore {
        var evidence: [Evidence] = []
        var score: Float = 0.3 // moderate prior — noise is common

        // No peaks above noise floor
        let strongPeaks = f.peaks.filter { $0.powerAboveNoise > 10 }
        if strongPeaks.isEmpty {
            score += 0.50
            evidence.append(Evidence(
                label: "No strong spectral peaks",
                impact: 0.50,
                detail: "No peaks more than 10 dB above the noise floor — consistent with noise or silence"
            ))
        } else {
            let strongest = strongPeaks[0]
            // The stronger the peak, the less likely it's noise
            let peakPenalty = min(0.40, strongest.powerAboveNoise / 100.0)
            score -= peakPenalty
            evidence.append(Evidence(
                label: "Strong peak detected",
                impact: -peakPenalty,
                detail: "Peak at \(Int(strongest.frequency)) Hz is \(String(format: "+%.0f", strongest.powerAboveNoise)) dB above noise — likely a real signal"
            ))
        }

        // High spectral flatness → noise-like
        // Training data: ambient noise flatness > 0.95, signals < 0.3
        if f.spectralFlatness > 0.8 {
            score += 0.40
            evidence.append(Evidence(
                label: "Broadband noise spectrum",
                impact: 0.40,
                detail: "Spectral flatness \(String(format: "%.2f", f.spectralFlatness)) — broadband noise, no signal structure"
            ))
        } else if f.spectralFlatness > 0.5 {
            score += 0.15
            evidence.append(Evidence(
                label: "Flat spectrum",
                impact: 0.15,
                detail: "Spectral flatness \(String(format: "%.2f", f.spectralFlatness)) indicates broadband noise"
            ))
        } else if f.spectralFlatness < 0.1 && !strongPeaks.isEmpty {
            score -= 0.10
            evidence.append(Evidence(
                label: "Tonal spectrum",
                impact: -0.10,
                detail: "Low spectral flatness indicates a tonal signal, not noise"
            ))
        }

        // Wide peak bandwidth → noise (real signals have narrow peaks < 60 Hz)
        // Training data: ambient noise topPeakBW = 117-275 Hz, signals < 53 Hz
        if let topPeak = f.peaks.first, topPeak.bandwidth3dB > 80 {
            score += 0.20
            evidence.append(Evidence(
                label: "Very wide peaks (noise-like)",
                impact: 0.20,
                detail: "Widest peak is \(Int(topPeak.bandwidth3dB)) Hz — real signals have peaks < 60 Hz"
            ))
        }

        // Weak peaks → more noise-like (real signals are 30+ dB above noise)
        if let topPeak = f.peaks.first, topPeak.powerAboveNoise < 15 && topPeak.powerAboveNoise > 0 {
            score += 0.15
            evidence.append(Evidence(
                label: "Weak peaks",
                impact: 0.15,
                detail: "Strongest peak is only \(String(format: "+%.0f", topPeak.powerAboveNoise)) dB — real signals are typically 30+ dB above noise"
            ))
        }

        // No FSK pairs, no OOK → more noise-like
        if f.fskPairs.isEmpty && !f.envelopeStats.hasOnOffKeying {
            score += 0.05
            evidence.append(Evidence(
                label: "No signal structure",
                impact: 0.05,
                detail: "No FSK pairs or on-off keying patterns detected"
            ))
        }

        // Unmodulated carrier: strong narrow peak + near-zero envelope variation = just a tone
        // Only count narrow peaks (< 25 Hz) — wider peaks (47+ Hz) could be GFSK (JS8Call)
        let hasNarrowStrongPeak = strongPeaks.first.map { $0.bandwidth3dB < 25 } ?? false
        if hasNarrowStrongPeak && f.envelopeStats.coefficientOfVariation < 0.05 {
            score += 0.50
            evidence.append(Evidence(
                label: "Unmodulated carrier",
                impact: 0.50,
                detail: "Narrow tone with no modulation (CV \(String(format: "%.3f", f.envelopeStats.coefficientOfVariation))) — not a digital mode signal"
            ))
        } else if !strongPeaks.isEmpty && f.envelopeStats.coefficientOfVariation < 0.02 {
            // Very near-zero CV even with wide peaks — likely noise or carrier
            score += 0.30
            evidence.append(Evidence(
                label: "Near-zero envelope variation",
                impact: 0.30,
                detail: "CV \(String(format: "%.3f", f.envelopeStats.coefficientOfVariation)) — very little amplitude variation"
            ))
        }

        let confidence = max(0.0, min(1.0, score))
        let label: String
        switch confidence {
        case 0.6...: label = "Likely noise or no signal."
        case 0.3..<0.6: label = "Possibly noise."
        default: label = "Signal likely present."
        }

        let explanation = "\(label) \(evidence.filter { abs($0.impact) > 0.05 }.map(\.detail).prefix(2).joined(separator: ". "))."

        return NoiseScore(confidence: confidence, explanation: explanation, evidence: evidence)
    }

    // MARK: - Per-Mode Scoring

    private func scoreMode(_ mode: DigitalMode, features: SpectralFeatures) -> ModeScore {
        switch mode {
        case .rtty:
            return scoreRTTY(features)
        case .psk31:
            return scorePSK(features, baudRate: 31.25, modeName: "PSK31", mode: .psk31)
        case .bpsk63:
            return scorePSK(features, baudRate: 62.5, modeName: "BPSK63", mode: .bpsk63)
        case .qpsk31:
            return scoreQPSK(features, baudRate: 31.25, modeName: "QPSK31", mode: .qpsk31)
        case .qpsk63:
            return scoreQPSK(features, baudRate: 62.5, modeName: "QPSK63", mode: .qpsk63)
        case .cw:
            return scoreCW(features)
        case .js8call:
            return scoreJS8Call(features)
        case .olivia:
            return scoreOlivia(features)
        }
    }

    // MARK: - RTTY Scoring

    /// Check if an FSK pair is a sideband artifact from a single-tone signal.
    /// In real RTTY, the mark and space frequencies ARE the two strongest peaks.
    /// OOK signals (CW) and PSK signals create sidelobe energy that can look like FSK pairs.
    private func isFSKPairArtifact(_ pair: FSKPair, features f: SpectralFeatures) -> Bool {
        guard let strongest = f.peaks.first else { return false }
        let nearMark = abs(strongest.frequency - pair.markFreq) < 30
        let nearSpace = abs(strongest.frequency - pair.spaceFreq) < 30
        // If the strongest peak is NOT at mark or space, the pair is sideband energy
        if !nearMark && !nearSpace {
            return true
        }
        // If there are many strong peaks (sidelobe comb from clean PSK/BPSK),
        // and this is NOT a standard 170 Hz shift pair, it's likely coincidental
        let strongPeakCount = f.peaks.filter { $0.powerAboveNoise > 10 }.count
        let isStandard170 = abs(pair.shift - 170) < 1
        if strongPeakCount >= 15 && !isStandard170 && f.fskPairs.filter({ $0.hasValley }).count > 5 {
            return true
        }
        // For 170 Hz pairs in a sidelobe comb: check if the top peak is between
        // mark and space (PSK center) rather than AT mark or space (real RTTY)
        if strongPeakCount >= 15 && isStandard170 {
            let loFreq = min(pair.markFreq, pair.spaceFreq) + 30
            let hiFreq = max(pair.markFreq, pair.spaceFreq) - 30
            if strongest.frequency > loFreq && strongest.frequency < hiFreq {
                return true
            }
        }
        // If OOK is detected, any FSK pair is an artifact (CW harmonics)
        if f.envelopeStats.hasOnOffKeying {
            return true
        }
        return false
    }

    private func scoreRTTY(_ f: SpectralFeatures) -> ModeScore {
        var evidence: [Evidence] = []
        var score: Float = 0.05 // low base prior

        // --- OOK penalty: RTTY is constant-envelope FSK, never has on-off keying ---
        if f.envelopeStats.hasOnOffKeying {
            score -= 0.15
            evidence.append(Evidence(
                label: "On-off keying detected (not RTTY)",
                impact: -0.15,
                detail: "RTTY is constant-envelope FSK — on-off keying rules it out (CV \(String(format: "%.2f", f.envelopeStats.coefficientOfVariation)), \(String(format: "%.0f", f.envelopeStats.transitionRate)) transitions/sec)"
            ))
        }

        // --- FSK pair detection (170 Hz standard shift) ---
        let standardPairs = f.fskPairs.filter { abs($0.shift - 170) < 1 && $0.hasValley }
        let validStandardPairs = standardPairs.filter { !isFSKPairArtifact($0, features: f) }

        if !validStandardPairs.isEmpty {
            let best = validStandardPairs[0]
            // Extra validation: one of the top-2 peaks should be near mark or space
            let topPeakNearFSK = f.peaks.prefix(3).contains { peak in
                abs(peak.frequency - best.markFreq) < 30 || abs(peak.frequency - best.spaceFreq) < 30
            }
            if topPeakNearFSK {
                score += 0.55
                evidence.append(Evidence(
                    label: "FSK pair detected",
                    impact: 0.55,
                    detail: "Mark/space pair at \(Int(best.markFreq))/\(Int(best.spaceFreq)) Hz with 170 Hz shift and spectral valley"
                ))
            } else {
                score += 0.10
                evidence.append(Evidence(
                    label: "FSK pair (weak — not in top peaks)",
                    impact: 0.10,
                    detail: "Mark/space pair at \(Int(best.markFreq))/\(Int(best.spaceFreq)) Hz but frequencies are not among the strongest peaks"
                ))
            }
        } else if !standardPairs.isEmpty {
            // Had 170 Hz pairs but they were all artifacts
            evidence.append(Evidence(
                label: "FSK pair (sideband artifact)",
                impact: 0.0,
                detail: "170 Hz pair detected but likely caused by sidelobe/harmonic energy from a single-tone signal"
            ))
        } else {
            // No 170 Hz pairs with valleys — check for pairs WITHOUT valleys.
            // Real-world RTTY on HF often has band noise filling the spectral valley,
            // so mark/space pairs exist but without the clean dip between them.
            // Real-world RTTY shift can vary from standard 170 Hz due to radio
            // filter shaping and frequency calibration. Allow 150-200 Hz.
            let standard170NoPairs = f.fskPairs.filter { $0.shift >= 150 && $0.shift <= 200 }
            if !standard170NoPairs.isEmpty && f.envelopeStats.coefficientOfVariation < 0.5
                && f.envelopeStats.transitionRate > 5 && f.envelopeStats.transitionRate < 60 {
                // FSK pairs at 150-200 Hz + low CV + RTTY-like transitions = probable real-world RTTY
                let bonus: Float = standard170NoPairs.count >= 3 ? 0.40 : 0.15
                score += bonus
                evidence.append(Evidence(
                    label: "FSK pairs at 170 Hz (no valley — HF noise)",
                    impact: bonus,
                    detail: "\(standard170NoPairs.count) mark/space pairs at 170 Hz shift without spectral valley — typical of real HF RTTY with band noise"
                ))
            } else {
                // Check for non-standard shifts
                let anyValidPairs = f.fskPairs.filter { $0.hasValley && !isFSKPairArtifact($0, features: f) }
                if !anyValidPairs.isEmpty {
                    let best = anyValidPairs[0]
                    score += 0.10
                    evidence.append(Evidence(
                        label: "Non-standard FSK pair",
                        impact: 0.10,
                        detail: "Mark/space pair at \(Int(best.markFreq))/\(Int(best.spaceFreq)) Hz with \(Int(best.shift)) Hz shift (non-standard)"
                    ))
                } else if f.fskPairs.isEmpty {
                    score -= 0.05
                    evidence.append(Evidence(
                        label: "No FSK pairs",
                        impact: -0.05,
                        detail: "No mark/space frequency pairs detected in spectrum"
                    ))
                }
            }
        }

        // --- Bandwidth check ---
        // Clean synthetic RTTY is ~250 Hz. Real-world RTTY on HF has occupied BW of
        // 1000-1500 Hz because band noise fills the entire audio passband.
        // Don't penalize wide bandwidth — only bonus for narrow.
        if f.occupiedBandwidth > 100 && f.occupiedBandwidth < 500 {
            score += 0.15
            evidence.append(Evidence(
                label: "Bandwidth consistent",
                impact: 0.15,
                detail: "Occupied bandwidth \(Int(f.occupiedBandwidth)) Hz is consistent with RTTY (~250 Hz)"
            ))
        } else if f.occupiedBandwidth > 500 {
            // Wide bandwidth — penalize less only for real-world RTTY signature:
            // many FSK pairs + low CV (constant-envelope) + no valleys (band noise)
            let realWorldRTTY = f.fskPairs.count >= 8
                && f.envelopeStats.coefficientOfVariation < 0.3
                && f.fskPairs.filter({ $0.hasValley }).count <= 2
            let penalty: Float = realWorldRTTY ? 0.05 : 0.15
            score -= penalty
            evidence.append(Evidence(
                label: "Bandwidth too wide",
                impact: -0.15,
                detail: "Occupied bandwidth \(Int(f.occupiedBandwidth)) Hz is too wide for RTTY"
            ))
        }

        // --- Peak balance: RTTY should have 2 roughly equal peaks at ~170 Hz spacing ---
        let strongPeaks = f.peaks.filter { $0.powerAboveNoise > 10 }
        if strongPeaks.count >= 2 {
            let spacing = abs(strongPeaks[0].frequency - strongPeaks[1].frequency)
            let powerRatio = strongPeaks[1].powerAboveNoise / max(strongPeaks[0].powerAboveNoise, 0.1)
            if abs(spacing - 170) < 30 && powerRatio > 0.3 {
                score += 0.10
                evidence.append(Evidence(
                    label: "Two balanced peaks at RTTY spacing",
                    impact: 0.10,
                    detail: "Top two peaks separated by \(Int(spacing)) Hz with \(String(format: "%.0f%%", powerRatio * 100)) power balance"
                ))
            }
        }

        // --- Peak bandwidth check: RTTY tones are narrow (~18 Hz) ---
        // Training data: RTTY topPeakBW = 17.2 ± 2.8 Hz. Anything > 25 Hz is too wide.
        if let topPeak = f.peaks.first, topPeak.bandwidth3dB > 25 {
            let penalty: Float = topPeak.bandwidth3dB > 50 ? 0.20 : 0.10
            score -= penalty
            evidence.append(Evidence(
                label: "Peak too wide for RTTY tones",
                impact: -penalty,
                detail: "Top peak is \(String(format: "%.0f", topPeak.bandwidth3dB)) Hz wide — RTTY tones are ~18 Hz"
            ))
        }

        // --- Single dominant peak penalty ---
        if strongPeaks.count >= 1 {
            let dominant = strongPeaks[0]
            let secondStrongest = strongPeaks.count >= 2 ? strongPeaks[1].powerAboveNoise : Float(0)
            if dominant.powerAboveNoise > 15 && secondStrongest < dominant.powerAboveNoise * 0.4 {
                score -= 0.15
                evidence.append(Evidence(
                    label: "Single dominant peak (not RTTY-like)",
                    impact: -0.15,
                    detail: "One peak dominates at \(Int(dominant.frequency)) Hz — RTTY should have two balanced peaks"
                ))
            }
        }

        // --- Constant envelope bonus (only if NOT OOK, which is already penalized above) ---
        if !f.envelopeStats.hasOnOffKeying && f.envelopeStats.coefficientOfVariation < 0.3 {
            score += 0.05
            evidence.append(Evidence(
                label: "Constant envelope",
                impact: 0.05,
                detail: "Low amplitude variation (CV \(String(format: "%.2f", f.envelopeStats.coefficientOfVariation))), consistent with FSK"
            ))
        }

        return buildScore(mode: .rtty, rawScore: score, evidence: evidence)
    }

    // MARK: - PSK Scoring (BPSK)

    private func scorePSK(_ f: SpectralFeatures, baudRate: Double, modeName: String, mode: DigitalMode) -> ModeScore {
        var evidence: [Evidence] = []
        var score: Float = 0.1

        let expectedBW = baudRate // PSK bandwidth ≈ baud rate
        let bwTolerance = baudRate * 0.8

        // Early check: if the dominant peak is CW-narrow (< 22 Hz), this is very
        // unlikely to be PSK regardless of what other noise peaks look like.
        // Training data: CW peak is always 17.6 Hz; PSK31 is 29 Hz, BPSK63 is 53 Hz.
        if let dominant = f.peaks.first, dominant.bandwidth3dB < 22 && dominant.powerAboveNoise > 15 {
            score -= 0.15
            evidence.append(Evidence(
                label: "CW-narrow dominant peak",
                impact: -0.15,
                detail: "Strongest peak is \(String(format: "%.0f", dominant.bandwidth3dB)) Hz wide — too narrow for \(modeName)"
            ))
        }

        // Single narrow peak — must be wider than 22 Hz (peaks < 22 Hz are CW territory)
        let minPSKBW = 22.0 // CW peaks are ~18 Hz; PSK31 is ~29 Hz
        let narrowPeaks = f.peaks.filter { $0.bandwidth3dB < expectedBW * 3 && $0.bandwidth3dB > minPSKBW && $0.powerAboveNoise > 7 }
        if !narrowPeaks.isEmpty {
            let best = narrowPeaks[0]
            score += 0.35
            evidence.append(Evidence(
                label: "Narrow peak detected",
                impact: 0.35,
                detail: "Peak at \(Int(best.frequency)) Hz, \(String(format: "%.0f", best.bandwidth3dB)) Hz wide, \(String(format: "+%.0f", best.powerAboveNoise)) dB above noise"
            ))

            // Peak bandwidth consistent with this baud rate
            if abs(best.bandwidth3dB - expectedBW) < bwTolerance {
                score += 0.15
                evidence.append(Evidence(
                    label: "Bandwidth matches \(modeName)",
                    impact: 0.15,
                    detail: "Peak bandwidth \(String(format: "%.0f", best.bandwidth3dB)) Hz matches \(modeName) at \(String(format: "%.1f", baudRate)) baud"
                ))
            } else if best.bandwidth3dB > expectedBW * 3 {
                score -= 0.10
                evidence.append(Evidence(
                    label: "Peak too wide for \(modeName)",
                    impact: -0.10,
                    detail: "Peak bandwidth \(String(format: "%.0f", best.bandwidth3dB)) Hz is wider than expected for \(modeName)"
                ))
            }
        } else if let topPeak = f.peaks.first, topPeak.bandwidth3dB <= minPSKBW && topPeak.powerAboveNoise > 7 {
            // Dominant peak is CW-narrow — even if wider noise peaks exist, the
            // signal is most likely CW, not PSK. Penalty scales with dominance.
            let secondPower = f.peaks.count >= 2 ? f.peaks[1].powerAboveNoise : Float(0)
            let dominanceRatio = secondPower > 0 ? topPeak.powerAboveNoise / secondPower : 5.0
            let penalty = min(0.40, 0.15 + dominanceRatio * 0.05)
            score -= penalty
            evidence.append(Evidence(
                label: "Dominant peak is CW-narrow",
                impact: -penalty,
                detail: "Strongest peak (\(String(format: "%.0f", topPeak.bandwidth3dB)) Hz) is narrower than PSK — likely CW (\(String(format: "%.1f", dominanceRatio))x stronger than next peak)"
            ))
        } else {
            evidence.append(Evidence(
                label: "No narrow peak",
                impact: 0.0,
                detail: "No narrow spectral peak detected matching \(modeName) characteristics"
            ))
        }

        // No FSK pairs (PSK is single-frequency)
        // But: if a single peak dominates, FSK pairs are likely sideband artifacts (not real FSK)
        let strongFSK = f.fskPairs.filter { $0.hasValley }
        let singlePeakDominates: Bool = {
            guard f.peaks.count >= 2 else { return f.peaks.count == 1 }
            return f.peaks[0].powerAboveNoise > 20 &&
                   f.peaks[1].powerAboveNoise < f.peaks[0].powerAboveNoise * 0.5
        }()

        if strongFSK.isEmpty {
            score += 0.10
            evidence.append(Evidence(
                label: "No FSK pairs (expected)",
                impact: 0.10,
                detail: "Absence of mark/space pairs is consistent with PSK modulation"
            ))
        } else if singlePeakDominates {
            // FSK pairs exist but single peak dominates — likely PSK sideband artifacts
            score += 0.05
            evidence.append(Evidence(
                label: "FSK pairs (sideband artifacts)",
                impact: 0.05,
                detail: "FSK pairs detected but single peak dominates — likely PSK sideband energy, not true FSK"
            ))
        } else {
            score -= 0.20
            evidence.append(Evidence(
                label: "FSK pairs present",
                impact: -0.20,
                detail: "FSK mark/space pairs detected, inconsistent with PSK"
            ))
        }

        // Envelope analysis — PSK is constant-envelope
        if f.envelopeStats.hasOnOffKeying {
            score -= 0.15
            evidence.append(Evidence(
                label: "On-off keying detected",
                impact: -0.15,
                detail: "Amplitude on-off keying suggests CW rather than PSK"
            ))
        } else if f.envelopeStats.coefficientOfVariation > 0.5 {
            // High envelope variation without confirmed OOK — could be CW in noise.
            // Scale penalty by CV when transition rate is CW-like (< 20/s).
            // High CV + CW-like transitions → very unlikely PSK. High CV + fast transitions → faded PSK.
            let cvPenalty: Float = (f.envelopeStats.coefficientOfVariation > 0.7
                && f.envelopeStats.transitionRate < 20) ? 0.25 : 0.10
            score -= cvPenalty
            evidence.append(Evidence(
                label: "High envelope variation",
                impact: -cvPenalty,
                detail: "Envelope CV \(String(format: "%.2f", f.envelopeStats.coefficientOfVariation)) is high for PSK (expected < 0.3)"
            ))
        }

        // Occupied bandwidth check
        if f.occupiedBandwidth < expectedBW * 4 && f.occupiedBandwidth > 0 {
            score += 0.05
            evidence.append(Evidence(
                label: "Narrow bandwidth",
                impact: 0.05,
                detail: "Occupied bandwidth \(Int(f.occupiedBandwidth)) Hz is consistent with \(modeName)"
            ))
        } else if f.occupiedBandwidth > 500 {
            score -= 0.10
            evidence.append(Evidence(
                label: "Bandwidth too wide",
                impact: -0.10,
                detail: "Occupied bandwidth \(Int(f.occupiedBandwidth)) Hz is too wide for \(modeName)"
            ))
        }

        // Spectral flatness — PSK signals are tonal (< 0.3), noise is flat (> 0.5)
        if f.spectralFlatness < 0.15 {
            score += 0.05
            evidence.append(Evidence(
                label: "Very tonal",
                impact: 0.05,
                detail: "Spectral flatness \(String(format: "%.2f", f.spectralFlatness)) indicates a single dominant tone"
            ))
        } else if f.spectralFlatness > 0.5 {
            score -= 0.15
            evidence.append(Evidence(
                label: "Broadband spectrum (not PSK-like)",
                impact: -0.15,
                detail: "Spectral flatness \(String(format: "%.2f", f.spectralFlatness)) — PSK signals are tonal (< 0.3)"
            ))
        }

        // Constant tone penalty: PSK is modulated. An unmodulated carrier (CV ≈ 0, no
        // transitions) is just a tone, not PSK.
        // Only apply when peak is narrow (< 25 Hz = pure tone). Wider peaks (47-53 Hz)
        // could be GFSK (JS8Call) which is constant-envelope by design.
        if f.envelopeStats.coefficientOfVariation < 0.05 && !f.peaks.isEmpty
            && f.peaks[0].powerAboveNoise > 10 && f.peaks[0].bandwidth3dB < 25 {
            score -= 0.50
            evidence.append(Evidence(
                label: "Unmodulated carrier (not PSK)",
                impact: -0.50,
                detail: "Envelope CV \(String(format: "%.3f", f.envelopeStats.coefficientOfVariation)) + narrow peak (\(String(format: "%.0f", f.peaks[0].bandwidth3dB)) Hz) — just a continuous tone"
            ))
        }

        // Multi-tone penalty: PSK has exactly ONE tone. If there are multiple closely-spaced
        // strong peaks (like FT8/JS8Call 8-FSK), this is not PSK.
        let tightPeaks = findTightlySpacedPeaks(f.peaks, maxSpacing: 15, minCount: 3)
        if tightPeaks.count >= 3 {
            score -= 0.25
            evidence.append(Evidence(
                label: "Multiple closely-spaced tones",
                impact: -0.25,
                detail: "\(tightPeaks.count) tones detected within a narrow band — PSK has a single tone, this looks like multi-tone FSK (FT8/JS8Call)"
            ))
        }

        // Baud rate estimation — strong discriminator between PSK31 (31.25) and BPSK63 (62.5)
        if f.baudRateConfidence > 0.3 && f.estimatedBaudRate > 0 {
            if abs(f.estimatedBaudRate - baudRate) < baudRate * 0.1 {
                // Estimated rate matches this mode's rate
                score += 0.20
                evidence.append(Evidence(
                    label: "Baud rate matches \(modeName)",
                    impact: 0.20,
                    detail: "Estimated \(String(format: "%.1f", f.estimatedBaudRate)) baud matches \(modeName) (\(String(format: "%.1f", baudRate)) baud)"
                ))
            } else if abs(f.estimatedBaudRate - baudRate) > baudRate * 0.3 {
                // Estimated rate clearly different from this mode
                score -= 0.15
                evidence.append(Evidence(
                    label: "Baud rate mismatch",
                    impact: -0.15,
                    detail: "Estimated \(String(format: "%.1f", f.estimatedBaudRate)) baud doesn't match \(modeName) (\(String(format: "%.1f", baudRate)) baud)"
                ))
            }
        }

        return buildScore(mode: mode, rawScore: score, evidence: evidence)
    }

    // MARK: - QPSK Scoring

    private func scoreQPSK(_ f: SpectralFeatures, baudRate: Double, modeName: String, mode: DigitalMode) -> ModeScore {
        // QPSK is spectrally identical to BPSK at the same baud rate.
        // We score it slightly lower than BPSK since BPSK is more common,
        // and note that distinguishing them requires demodulation.
        let bpskMode: DigitalMode = baudRate < 50 ? .psk31 : .bpsk63
        let bpskName = baudRate < 50 ? "PSK31" : "BPSK63"
        let bpskScore = scorePSK(f, baudRate: baudRate, modeName: bpskName, mode: bpskMode)

        // Copy evidence and add QPSK note
        var evidence = bpskScore.evidence
        evidence.append(Evidence(
            label: "QPSK vs BPSK indistinguishable",
            impact: -0.05,
            detail: "\(modeName) has identical spectrum to \(bpskName); distinguishing requires demodulation (phase constellation analysis). \(bpskName) is more commonly used."
        ))

        let adjustedConfidence = max(0, bpskScore.confidence - 0.05)

        return buildScore(mode: mode, rawScore: Float(adjustedConfidence), evidence: evidence)
    }

    // MARK: - CW Scoring
    //
    // Training data key insights:
    //   CW topPeakBW = 17.6 Hz ALWAYS (narrowest of any mode; PSK31=29Hz, BPSK63=53Hz)
    //   CW envelope CV: clean=0.93, snr20=0.81, snr10=0.60, snr5=0.44, snr0=0.25
    //   CW transitions: 4-14/sec (scales with WPM)
    //   CW OOK detected: only at clean and high SNR (>= 20 dB)

    private func scoreCW(_ f: SpectralFeatures) -> ModeScore {
        var evidence: [Evidence] = []
        var score: Float = 0.05

        // --- Extremely narrow peak (< 22 Hz) is the strongest CW discriminator ---
        // Training data: CW ALWAYS has 17.6 Hz peak BW. PSK31=29Hz, BPSK63=53Hz.
        // This holds even at low SNR where OOK is not detectable.
        let cwNarrowPeaks = f.peaks.filter { $0.bandwidth3dB < 22 && $0.powerAboveNoise > 7 }
        if !cwNarrowPeaks.isEmpty {
            let best = cwNarrowPeaks[0]
            score += 0.45
            evidence.append(Evidence(
                label: "CW-width tone (\(String(format: "%.0f", best.bandwidth3dB)) Hz)",
                impact: 0.45,
                detail: "Tone at \(Int(best.frequency)) Hz is \(String(format: "%.0f", best.bandwidth3dB)) Hz wide — narrower than any digital mode (PSK31=29Hz, BPSK63=53Hz)"
            ))
        } else {
            // Narrow but not CW-narrow (22-50 Hz)
            let narrowPeaks = f.peaks.filter { $0.bandwidth3dB < 50 && $0.powerAboveNoise > 7 }
            if !narrowPeaks.isEmpty {
                score += 0.15
                evidence.append(Evidence(
                    label: "Narrow tone",
                    impact: 0.15,
                    detail: "Peak at \(Int(narrowPeaks[0].frequency)) Hz is \(String(format: "%.0f", narrowPeaks[0].bandwidth3dB)) Hz wide"
                ))
            }
        }

        // --- On-off keying (clean / high SNR) ---
        if f.envelopeStats.hasOnOffKeying {
            score += 0.35
            evidence.append(Evidence(
                label: "On-off keying detected",
                impact: 0.35,
                detail: "CV \(String(format: "%.2f", f.envelopeStats.coefficientOfVariation)), duty \(String(format: "%.0f%%", f.envelopeStats.dutyCycle * 100)), \(String(format: "%.0f", f.envelopeStats.transitionRate)) transitions/sec"
            ))
        } else if f.envelopeStats.coefficientOfVariation > 0.10 && !cwNarrowPeaks.isEmpty
                    && (f.peaks.count < 15 || f.envelopeStats.transitionRate < 15) {
            // Elevated CV + CW-narrow peak → probable CW in noise.
            // Allow many peaks if transition rate is CW-like (< 15/s), which excludes
            // BPSK sidelobe combs (which have high transition rates).
            let cvCredit = min(0.30, (f.envelopeStats.coefficientOfVariation - 0.10) * 0.4)
            score += cvCredit
            evidence.append(Evidence(
                label: "Probable CW in noise",
                impact: cvCredit,
                detail: "CW-narrow tone + CV \(String(format: "%.2f", f.envelopeStats.coefficientOfVariation)) — noise likely masking silence periods"
            ))
        } else if f.envelopeStats.coefficientOfVariation > 0.6
                    && f.envelopeStats.transitionRate > 5 && f.envelopeStats.transitionRate < 20
                    && cwNarrowPeaks.isEmpty {
            // Very high CV + CW-like transition rate but peak broadened (e.g. by multipath/fading).
            // Disturbed ITU channels can broaden the CW peak from 17.6 to 29+ Hz.
            let cvCredit = min(0.35, (f.envelopeStats.coefficientOfVariation - 0.5) * 0.7)
            score += cvCredit
            evidence.append(Evidence(
                label: "High CV with CW-like transitions",
                impact: cvCredit,
                detail: "CV \(String(format: "%.2f", f.envelopeStats.coefficientOfVariation)) + \(String(format: "%.0f", f.envelopeStats.transitionRate)) transitions/sec suggests CW with channel-broadened peak"
            ))
        } else if f.envelopeStats.coefficientOfVariation < 0.05 {
            // Near-zero CV = unmodulated carrier, not CW. CW MUST have amplitude keying.
            score -= 0.35
            evidence.append(Evidence(
                label: "No modulation (not CW)",
                impact: -0.35,
                detail: "CV \(String(format: "%.3f", f.envelopeStats.coefficientOfVariation)) — signal has no amplitude variation, just a steady tone"
            ))
        }

        // --- Bandwidth ---
        if f.occupiedBandwidth > 0 && f.occupiedBandwidth < 200 {
            score += 0.10
            evidence.append(Evidence(
                label: "Narrow bandwidth",
                impact: 0.10,
                detail: "Occupied bandwidth \(Int(f.occupiedBandwidth)) Hz is consistent with CW"
            ))
        }

        // --- Multi-peak penalty ---
        let strongPeaksAbove10dB = f.peaks.filter { $0.powerAboveNoise > 10 }.count
        if strongPeaksAbove10dB > 12 {
            let penalty: Float = min(0.20, Float(strongPeaksAbove10dB - 12) * 0.05)
            score -= penalty
            evidence.append(Evidence(
                label: "Too many peaks for CW",
                impact: -penalty,
                detail: "\(strongPeaksAbove10dB) peaks above 10 dB"
            ))
        }

        // --- Duty cycle (OOK or high-CV CW-like) ---
        let hasCWEnvelope = f.envelopeStats.hasOnOffKeying
            || (f.envelopeStats.coefficientOfVariation > 0.5 && f.envelopeStats.transitionRate < 20)
        if hasCWEnvelope && f.envelopeStats.dutyCycle > 0.2 && f.envelopeStats.dutyCycle < 0.75 {
            score += 0.10
            evidence.append(Evidence(
                label: "CW duty cycle",
                impact: 0.10,
                detail: "Duty cycle \(String(format: "%.0f%%", f.envelopeStats.dutyCycle * 100)) is typical for Morse"
            ))
        }

        // --- Baud rate check: CW has no fixed baud rate ---
        // If a digital mode baud rate (31.25, 45.45, 62.5) is strongly detected, it's not CW.
        let digitalBaudRates = [31.25, 45.45, 62.5, 75.0, 100.0]
        let hasCWLikeEnvelope = f.envelopeStats.coefficientOfVariation > 0.5
            && f.envelopeStats.transitionRate > 3 && f.envelopeStats.transitionRate < 18
        if f.baudRateConfidence > 0.5 && !hasCWLikeEnvelope
            && digitalBaudRates.contains(where: { abs(f.estimatedBaudRate - $0) < $0 * 0.1 }) {
            score -= 0.25
            evidence.append(Evidence(
                label: "Digital baud rate detected (not CW)",
                impact: -0.25,
                detail: "Estimated \(String(format: "%.1f", f.estimatedBaudRate)) baud — CW has no fixed baud rate"
            ))
        }

        return buildScore(mode: .cw, rawScore: score, evidence: evidence)
    }

    // MARK: - JS8Call Scoring

    // MARK: - JS8Call Scoring
    //
    // Training data key insights:
    //   JS8Call transitionRate = 0.5/s (uniquely low — CW=8/s, PSK=32/s, RTTY=52/s)
    //   JS8Call topPeakBW = 47-53 Hz
    //   JS8Call peaks = 2 (even in noisy conditions)
    //   JS8Call CV = 0.19-0.66 (varies with SNR)
    //   JS8Call duty = 70% consistently
    //   FT8 has similar characteristics (also 8-GFSK at 6.25 baud)

    private func scoreJS8Call(_ f: SpectralFeatures) -> ModeScore {
        var evidence: [Evidence] = []
        var score: Float = 0.1

        // --- Very low transition rate is the strongest JS8Call/FT8 discriminator ---
        // JS8Call GFSK transitions happen within the symbol (smooth FSK), so the
        // 10ms-block envelope sees almost no transitions (0.5/s).
        // CW: 4-14/s, PSK: 26-41/s, RTTY: 47-52/s
        if f.envelopeStats.transitionRate < 2.0 && f.envelopeStats.coefficientOfVariation > 0.1 {
            score += 0.40
            evidence.append(Evidence(
                label: "Very low transition rate (GFSK)",
                impact: 0.40,
                detail: "\(String(format: "%.1f", f.envelopeStats.transitionRate)) transitions/sec — consistent with JS8Call/FT8 (smooth GFSK modulation)"
            ))
        } else if f.envelopeStats.transitionRate < 5.0 && f.envelopeStats.coefficientOfVariation > 0.1 {
            score += 0.15
            evidence.append(Evidence(
                label: "Low transition rate",
                impact: 0.15,
                detail: "\(String(format: "%.1f", f.envelopeStats.transitionRate)) transitions/sec — possibly GFSK"
            ))
        } else if f.envelopeStats.transitionRate > 10 {
            // High transition rate rules out JS8Call — UNLESS the signal has constant-envelope
            // + GFSK-width peak, which means the transitions are GFSK micro-variations after
            // silence trimming, not real amplitude modulation.
            let isGFSKConstantEnvelope = f.envelopeStats.coefficientOfVariation < 0.1
                && f.peaks.first.map({ $0.bandwidth3dB > 20 && $0.bandwidth3dB < 70 }) == true
            if !isGFSKConstantEnvelope {
                score -= 0.15
                evidence.append(Evidence(
                    label: "High transition rate (not JS8Call)",
                    impact: -0.15,
                    detail: "\(String(format: "%.0f", f.envelopeStats.transitionRate)) transitions/sec — JS8Call has < 2/sec"
                ))
            }
        }

        // --- Peak bandwidth ~47-53 Hz ---
        if let topPeak = f.peaks.first {
            if topPeak.bandwidth3dB > 20 && topPeak.bandwidth3dB < 70 {
                score += 0.15
                evidence.append(Evidence(
                    label: "Peak bandwidth matches JS8Call",
                    impact: 0.15,
                    detail: "Peak bandwidth \(String(format: "%.0f", topPeak.bandwidth3dB)) Hz matches JS8Call GFSK (~50 Hz)"
                ))

                // GFSK constant-envelope bonus: JS8Call is FSK (constant envelope by design).
                // After silence trimming, the active GFSK burst has very low CV.
                // This distinguishes it from PSK (which has raised-cosine envelope shaping).
                if f.envelopeStats.coefficientOfVariation < 0.1 && topPeak.powerAboveNoise > 15 {
                    score += 0.25
                    evidence.append(Evidence(
                        label: "Constant-envelope GFSK",
                        impact: 0.25,
                        detail: "CV \(String(format: "%.3f", f.envelopeStats.coefficientOfVariation)) + GFSK-width peak — consistent with JS8Call constant-envelope FSK"
                    ))
                }
            }
        }

        // --- Few spectral peaks (typically 2) ---
        let peaksAbove10dB = f.peaks.filter { $0.powerAboveNoise > 10 }.count
        if peaksAbove10dB <= 5 && peaksAbove10dB > 0 {
            score += 0.10
            evidence.append(Evidence(
                label: "Few spectral peaks",
                impact: 0.10,
                detail: "\(peaksAbove10dB) peaks — consistent with JS8Call's compact spectrum"
            ))
        } else if peaksAbove10dB > 10 {
            score -= 0.15
            evidence.append(Evidence(
                label: "Too many peaks for JS8Call",
                impact: -0.15,
                detail: "\(peaksAbove10dB) peaks — JS8Call has a compact spectrum with 2-5 peaks"
            ))
        }

        // --- Duty cycle ~70% (constant transmission during frame) ---
        if f.envelopeStats.dutyCycle > 0.6 && f.envelopeStats.dutyCycle < 0.85 {
            score += 0.05
            evidence.append(Evidence(
                label: "High duty cycle",
                impact: 0.05,
                detail: "Duty cycle \(String(format: "%.0f%%", f.envelopeStats.dutyCycle * 100)) — JS8Call transmits continuously during frames"
            ))
        }

        // --- No on-off keying ---
        if !f.envelopeStats.hasOnOffKeying {
            score += 0.05
            evidence.append(Evidence(
                label: "Continuous signal",
                impact: 0.05,
                detail: "No on-off keying, consistent with GFSK"
            ))
        }

        // Multi-tone pattern (if detectable at high SNR)
        let tightPeaks = findTightlySpacedPeaks(f.peaks, maxSpacing: 15, minCount: 3)
        if tightPeaks.count >= 3 {
            score += 0.10
            evidence.append(Evidence(
                label: "Multi-tone pattern",
                impact: 0.10,
                detail: "\(tightPeaks.count) closely-spaced tones — consistent with 8-GFSK"
            ))
        }

        // Moderate spectral flatness (between tonal and broadband)
        if f.spectralFlatness > 0.1 && f.spectralFlatness < 0.6 {
            score += 0.05
            evidence.append(Evidence(
                label: "Moderate spectral flatness",
                impact: 0.05,
                detail: "Spectral flatness \(String(format: "%.2f", f.spectralFlatness)) is between tonal and broadband, consistent with multi-tone FSK"
            ))
        }

        // --- Baud rate match: JS8Call = 6.25 baud ---
        // Only give credit when the signal also has JS8Call-like spectral characteristics
        // (few peaks, GFSK-width peak) to avoid false positives from subharmonics in RTTY/noise.
        // 6.25 baud is a subharmonic of 31.25 and 62.5 — verify the signal doesn't
        // also have characteristics of PSK (which would indicate the 6.25 is a subharmonic).
        let hasJS8SpectralShape = peaksAbove10dB <= 5
            && (f.peaks.first.map { $0.bandwidth3dB > 30 && $0.bandwidth3dB < 65 } ?? false)
        if f.baudRateConfidence > 0.5 && abs(f.estimatedBaudRate - 6.25) < 1.0 && hasJS8SpectralShape {
            score += 0.25
            evidence.append(Evidence(
                label: "Baud rate matches JS8Call",
                impact: 0.25,
                detail: "Estimated \(String(format: "%.1f", f.estimatedBaudRate)) baud + GFSK-like spectrum"
            ))
        } else if f.baudRateConfidence > 0.3 && f.estimatedBaudRate > 10 {
            // Detected a different mode's baud rate
            score -= 0.10
            evidence.append(Evidence(
                label: "Baud rate mismatch",
                impact: -0.10,
                detail: "Estimated \(String(format: "%.1f", f.estimatedBaudRate)) baud doesn't match JS8Call (6.25 baud)"
            ))
        }

        return buildScore(mode: .js8call, rawScore: score, evidence: evidence)
    }

    // MARK: - Olivia Scoring

    private func scoreOlivia(_ f: SpectralFeatures) -> ModeScore {
        var evidence: [Evidence] = []
        var score: Float = 0.05 // low prior (not yet implemented in app)

        // Olivia uses many tones in a grid pattern, wider than JS8Call
        // Olivia 8/250: 8 tones over 250 Hz; Olivia 32/1000: 32 tones over 1000 Hz
        if f.occupiedBandwidth > 200 && f.occupiedBandwidth < 1200 {
            let tightPeaks = findTightlySpacedPeaks(f.peaks, maxSpacing: 50, minCount: 4)
            if tightPeaks.count >= 4 {
                score += 0.25
                evidence.append(Evidence(
                    label: "Multi-tone grid pattern",
                    impact: 0.25,
                    detail: "\(tightPeaks.count) evenly-spaced tones detected — could be Olivia MFSK grid"
                ))
            }

            if f.spectralFlatness > 0.2 {
                score += 0.10
                evidence.append(Evidence(
                    label: "Relatively flat spectrum",
                    impact: 0.10,
                    detail: "Spectral flatness \(String(format: "%.2f", f.spectralFlatness)) suggests multiple tones spread across bandwidth"
                ))
            }
        } else {
            evidence.append(Evidence(
                label: "Bandwidth outside Olivia range",
                impact: 0.0,
                detail: "Occupied bandwidth \(Int(f.occupiedBandwidth)) Hz is outside typical Olivia range (250–1000 Hz)"
            ))
        }

        evidence.append(Evidence(
            label: "Olivia not yet implemented",
            impact: -0.05,
            detail: "Olivia mode is planned but not yet supported for demodulation"
        ))

        return buildScore(mode: .olivia, rawScore: score, evidence: evidence)
    }

    // MARK: - Helpers

    /// Find groups of peaks that are closely spaced (suggesting multi-tone FSK).
    private func findTightlySpacedPeaks(_ peaks: [SpectralPeak], maxSpacing: Double, minCount: Int) -> [SpectralPeak] {
        let sorted = peaks.sorted { $0.frequency < $1.frequency }
        guard sorted.count >= minCount else { return [] }

        var bestGroup: [SpectralPeak] = []

        for startIdx in 0..<sorted.count {
            var group = [sorted[startIdx]]
            for nextIdx in (startIdx + 1)..<sorted.count {
                if sorted[nextIdx].frequency - group.last!.frequency <= maxSpacing {
                    group.append(sorted[nextIdx])
                } else {
                    break
                }
            }
            if group.count > bestGroup.count {
                bestGroup = group
            }
        }

        return bestGroup.count >= minCount ? bestGroup : []
    }

    /// Convert raw score to clamped confidence and build the final ModeScore.
    private func buildScore(mode: DigitalMode, rawScore: Float, evidence: [Evidence]) -> ModeScore {
        let confidence = max(0.0, min(1.0, rawScore))

        let explanation = buildExplanation(mode: mode, confidence: confidence, evidence: evidence)

        return ModeScore(
            mode: mode,
            confidence: confidence,
            explanation: explanation,
            evidence: evidence
        )
    }

    /// Build a human-readable summary from evidence items.
    private func buildExplanation(mode: DigitalMode, confidence: Float, evidence: [Evidence]) -> String {
        let pct = Int(confidence * 100)
        let label: String
        switch confidence {
        case 0.7...: label = "Strong match"
        case 0.4..<0.7: label = "Possible match"
        case 0.2..<0.4: label = "Weak match"
        default: label = "Unlikely"
        }

        var parts = ["\(label) (\(pct)%)."]

        let positive = evidence.filter { $0.impact > 0.1 }.prefix(2)
        let negative = evidence.filter { $0.impact < -0.05 }.prefix(1)

        for e in positive {
            parts.append(e.detail + ".")
        }
        for e in negative {
            parts.append(e.detail + ".")
        }

        return parts.joined(separator: " ")
    }
}
