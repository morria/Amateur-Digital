import CoreML
import Foundation

/// Classifies decoded amateur radio digital mode text as legitimate or garbage/noise.
///
/// Thread-safe: `MLModel.prediction(from:)` is thread-safe per Apple documentation.
///
/// ```swift
/// let classifier = try HamTextClassifier()
/// let result = classifier.classify("CQ CQ CQ DE W1AW K")
/// // result.isLegitimate == true, result.confidence == 0.97
/// ```
public final class HamTextClassifier: @unchecked Sendable {
    private let model: MLModel

    /// Initialize the classifier, loading the bundled CoreML model.
    public init() throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly

        guard let modelURL = Bundle.module.url(
            forResource: "HamTextClassifier",
            withExtension: "mlmodelc"
        ) else {
            throw HamTextClassifierError.modelNotFound
        }

        self.model = try MLModel(contentsOf: modelURL, configuration: config)
    }

    /// Classify text as legitimate ham radio communication or garbage.
    public func classify(_ text: String) -> ClassificationResult {
        let features = FeatureExtractor.extractFeatures(from: text)
        let provider = DictionaryFeatureProvider(features: features)

        guard let prediction = try? model.prediction(from: provider) else {
            return ClassificationResult(isLegitimate: false, confidence: 0.0, label: 0)
        }

        let label = prediction.featureValue(for: "label")?.int64Value ?? 0
        let probs = prediction.featureValue(for: "classProbability")?.dictionaryValue

        let confidence: Double
        if let probs = probs {
            confidence = (probs[label as NSNumber] as? Double) ?? 0.5
        } else {
            confidence = 0.5
        }

        return ClassificationResult(
            isLegitimate: label == 1,
            confidence: confidence,
            label: Int(label)
        )
    }
}

// MARK: - Error Types

public enum HamTextClassifierError: Error, LocalizedError {
    case modelNotFound

    public var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "HamTextClassifier.mlmodelc not found in bundle resources"
        }
    }
}

// MARK: - DictionaryFeatureProvider

/// Bridges a `[String: Double]` feature dictionary to CoreML's `MLFeatureProvider`.
private final class DictionaryFeatureProvider: MLFeatureProvider {
    let features: [String: Double]

    var featureNames: Set<String> {
        return Set(["input"])
    }

    init(features: [String: Double]) {
        self.features = features
    }

    func featureValue(for featureName: String) -> MLFeatureValue? {
        guard featureName == "input" else { return nil }
        let mlDict = features.reduce(into: [AnyHashable: NSNumber]()) { result, pair in
            result[pair.key as NSString] = NSNumber(value: pair.value)
        }
        return try? MLFeatureValue(dictionary: mlDict)
    }
}
