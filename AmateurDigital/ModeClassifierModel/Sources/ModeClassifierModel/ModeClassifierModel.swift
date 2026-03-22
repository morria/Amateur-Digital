import CoreML
import Foundation

/// Result of ML-based mode classification.
public struct ModeClassification {
    /// Predicted mode label (e.g., "rtty", "psk31", "cw", "noise")
    public let mode: String

    /// Confidence for the predicted mode (0.0–1.0)
    public let confidence: Double

    /// All class probabilities, sorted by confidence descending
    public let probabilities: [(mode: String, probability: Double)]
}

/// CoreML-based digital mode classifier.
///
/// Uses a Gradient Boosted Machine (200 trees) trained on 11 spectral features
/// extracted by SpectralAnalyzer. Achieves 99.8% accuracy on synthetic test data.
/// The model is 372KB and runs in <1ms on CPU.
///
/// ```swift
/// let classifier = try ModeClassifierML()
/// let result = classifier.classify(features: featureDict)
/// print(result.mode, result.confidence)
/// ```
public final class ModeClassifierML: @unchecked Sendable {
    private let model: MLModel

    /// The 11 feature names expected by the model, in order.
    public static let featureNames = [
        "bandwidth", "flatness", "num_peaks", "top_peak_power", "top_peak_bw",
        "fsk_pairs", "fsk_valley_pairs", "envelope_cv", "duty_cycle",
        "transition_rate", "has_ook"
    ]

    /// Mode labels corresponding to the model's class indices.
    public static let modeLabels = [
        "rtty", "psk31", "bpsk63", "qpsk31", "qpsk63", "cw", "js8call", "noise"
    ]

    /// Initialize the classifier, loading the bundled CoreML model.
    public init() throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly

        guard let modelURL = Bundle.module.url(
            forResource: "ModeClassifier",
            withExtension: "mlmodelc"
        ) else {
            throw ModeClassifierError.modelNotFound
        }

        self.model = try MLModel(contentsOf: modelURL, configuration: config)
    }

    /// Classify a signal from its spectral features.
    ///
    /// - Parameter features: Dictionary mapping feature names to Double values.
    ///   Required keys: bandwidth, flatness, num_peaks, top_peak_power, top_peak_bw,
    ///   fsk_pairs, fsk_valley_pairs, envelope_cv, duty_cycle, transition_rate, has_ook
    /// - Returns: Classification result with mode, confidence, and all probabilities.
    public func classify(features: [String: Double]) -> ModeClassification {
        let provider = DictionaryFeatureProvider(features: features)

        guard let prediction = try? model.prediction(from: provider) else {
            return ModeClassification(mode: "noise", confidence: 0, probabilities: [])
        }

        // Extract predicted class index
        let modeIndex = prediction.featureValue(for: "mode_index")?.int64Value ?? 7

        let mode: String
        if modeIndex >= 0 && modeIndex < Self.modeLabels.count {
            mode = Self.modeLabels[Int(modeIndex)]
        } else {
            mode = "noise"
        }

        // Extract class probabilities if available
        var probabilities: [(String, Double)] = []
        if let probs = prediction.featureValue(for: "classProbability")?.dictionaryValue {
            for (key, value) in probs {
                if let idx = key as? Int64, let prob = value as? Double,
                   idx >= 0 && idx < Self.modeLabels.count {
                    probabilities.append((Self.modeLabels[Int(idx)], prob))
                }
            }
            probabilities.sort { $0.1 > $1.1 }
        }

        let confidence = probabilities.first { $0.0 == mode }?.1 ?? 1.0

        return ModeClassification(
            mode: mode,
            confidence: confidence,
            probabilities: probabilities.map { (mode: $0.0, probability: $0.1) }
        )
    }
}

// MARK: - Feature Provider

private class DictionaryFeatureProvider: MLFeatureProvider {
    let features: [String: Double]

    init(features: [String: Double]) {
        self.features = features
    }

    var featureNames: Set<String> {
        Set(features.keys)
    }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        guard let value = features[featureName] else { return nil }
        return MLFeatureValue(double: value)
    }
}

// MARK: - Errors

public enum ModeClassifierError: Error, LocalizedError {
    case modelNotFound

    public var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "ModeClassifier.mlmodelc not found in bundle"
        }
    }
}
