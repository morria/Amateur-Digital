//
//  ModeDetector.swift
//  AmateurDigitalCore
//
//  Public API for automatic digital mode detection. Accepts audio samples
//  and returns a ranked list of modes with confidence scores and explanations.
//

import Foundation

/// Noise/no-signal score with explanation.
public struct NoiseScore {
    /// Confidence that the signal is just noise (0.0 = definitely a signal, 1.0 = definitely noise)
    public let confidence: Float

    /// Human-readable explanation
    public let explanation: String

    /// Evidence items
    public let evidence: [Evidence]
}

/// Result of mode detection: a ranked list of modes with confidence and explanations.
public struct ModeDetectionResult {
    /// Ranked mode scores, most likely mode first
    public let rankings: [ModeScore]

    /// Noise/no-signal score — how likely the input is just noise
    public let noiseScore: NoiseScore

    /// The spectral features extracted from the audio (for debugging/display)
    public let features: SpectralFeatures

    /// Duration of the analyzed audio in seconds
    public let audioDuration: Double

    /// Time taken for analysis in seconds
    public let analysisTime: Double

    public init(rankings: [ModeScore], noiseScore: NoiseScore, features: SpectralFeatures,
                audioDuration: Double, analysisTime: Double) {
        self.rankings = rankings
        self.noiseScore = noiseScore
        self.features = features
        self.audioDuration = audioDuration
        self.analysisTime = analysisTime
    }

    /// The most likely mode (first in rankings), or nil if no signal detected
    public var bestMatch: ModeScore? { rankings.first }

    /// Whether a signal was detected at all
    public var signalDetected: Bool {
        guard let best = bestMatch else { return false }
        return best.confidence > 0.15 && best.confidence > noiseScore.confidence
    }

    /// Human-readable summary of detection results
    public var summary: String {
        guard signalDetected, let _ = bestMatch else {
            return "No signal detected in \(String(format: "%.1f", audioDuration))s of audio."
        }

        var lines = ["Mode detection (\(String(format: "%.1f", audioDuration))s audio, \(String(format: "%.0f", analysisTime * 1000))ms analysis):"]

        for (i, score) in rankings.prefix(3).enumerated() {
            let rank = i + 1
            let pct = Int(score.confidence * 100)
            let bar = String(repeating: "\u{2588}", count: pct / 5)
            lines.append("  \(rank). \(score.mode.rawValue.padding(toLength: 7, withPad: " ", startingAt: 0)) \(String(format: "%3d", pct))% \(bar)")
            if i == 0 {
                lines.append("     \(score.explanation)")
            }
        }

        if rankings.count > 3 {
            let rest = rankings.dropFirst(3).map { "\($0.mode.rawValue) \(Int($0.confidence * 100))%" }
            lines.append("  Also: \(rest.joined(separator: ", "))")
        }

        return lines.joined(separator: "\n")
    }
}

/// Automatic digital mode detector.
///
/// Analyzes audio samples and ranks supported digital modes by likelihood.
/// Uses spectral analysis (FFT peak detection, bandwidth measurement, FSK pair
/// detection, envelope analysis) to classify signals.
///
/// Usage:
/// ```swift
/// let detector = ModeDetector(sampleRate: 48000)
/// let result = detector.detect(samples: audioBuffer)
/// print(result.summary)
///
/// if let best = result.bestMatch {
///     print("Most likely: \(best.mode.rawValue) (\(Int(best.confidence * 100))%)")
///     print(best.explanation)
/// }
/// ```
public final class ModeDetector {

    /// Sample rate of audio input
    public let sampleRate: Double

    /// FFT size (larger = better frequency resolution, more latency)
    public let fftSize: Int

    /// Minimum frequency to analyze (Hz)
    public let minFreq: Double

    /// Maximum frequency to analyze (Hz)
    public let maxFreq: Double

    private let analyzer: SpectralAnalyzer
    private let classifier: ModeClassifier

    /// Create a mode detector.
    /// - Parameters:
    ///   - sampleRate: Audio sample rate in Hz (default 48000)
    ///   - fftSize: FFT window size (default 8192, ~170ms at 48kHz)
    ///   - minFreq: Minimum frequency to analyze (default 200 Hz)
    ///   - maxFreq: Maximum frequency to analyze (default 4000 Hz)
    public init(
        sampleRate: Double = 48000,
        fftSize: Int = 8192,
        minFreq: Double = 200,
        maxFreq: Double = 4000
    ) {
        self.sampleRate = sampleRate
        self.fftSize = fftSize
        self.minFreq = minFreq
        self.maxFreq = maxFreq
        self.analyzer = SpectralAnalyzer(
            fftSize: fftSize,
            sampleRate: sampleRate,
            minFreq: minFreq,
            maxFreq: maxFreq
        )
        self.classifier = ModeClassifier()
    }

    /// Detect the most likely digital mode from audio samples.
    ///
    /// - Parameter samples: Mono audio samples at `sampleRate`. At least 0.5 seconds
    ///   (~24000 samples at 48 kHz) recommended for reliable detection.
    /// - Returns: Detection result with ranked modes, confidence scores, and explanations.
    public func detect(samples: [Float]) -> ModeDetectionResult {
        let startTime = CFAbsoluteTimeGetCurrent()

        let features = analyzer.analyze(samples)
        let rankings = classifier.classify(features: features)
        let noiseScore = classifier.scoreNoise(features: features)

        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let duration = Double(samples.count) / sampleRate

        return ModeDetectionResult(
            rankings: rankings,
            noiseScore: noiseScore,
            features: features,
            audioDuration: duration,
            analysisTime: elapsed
        )
    }

    /// Convenience: detect mode from a buffer that arrives in chunks.
    /// Accumulates samples internally and runs detection when enough have been collected.
    ///
    /// - Parameters:
    ///   - samples: New audio samples to add
    ///   - minDuration: Minimum audio duration (seconds) before running detection (default 0.5)
    /// - Returns: Detection result if enough audio has accumulated, nil otherwise
    public func detectIncremental(samples: [Float], minDuration: Double = 0.5) -> ModeDetectionResult? {
        accumulatedSamples.append(contentsOf: samples)
        let duration = Double(accumulatedSamples.count) / sampleRate

        guard duration >= minDuration else { return nil }

        let result = detect(samples: accumulatedSamples)
        accumulatedSamples.removeAll(keepingCapacity: true)
        return result
    }

    /// Clear accumulated samples from incremental detection.
    public func reset() {
        accumulatedSamples.removeAll(keepingCapacity: true)
    }

    private var accumulatedSamples: [Float] = []
}
