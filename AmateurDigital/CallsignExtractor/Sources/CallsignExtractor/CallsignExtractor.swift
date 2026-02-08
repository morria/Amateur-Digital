import Foundation
import CoreML

/// Extracts the target amateur radio callsign from decoded digital mode text
/// (RTTY, PSK31, etc.) using an ML model to score candidates by context.
public final class CallsignExtractor: @unchecked Sendable {

    private let model: MLModel

    // MARK: - Callsign regex

    /// Matches standard amateur radio callsigns: 1-2 letters, 1-2 digits, 1-4 letters.
    private static let callsignPattern = try! NSRegularExpression(
        pattern: #"\b([A-Z]{1,2}\d{1,2}[A-Z]{1,4})\b"#
    )

    // MARK: - Context keywords

    private static let cqWords: Set<String> = ["CQ"]
    private static let deWords: Set<String> = ["DE"]
    private static let endWords: Set<String> = ["K", "KN", "SK", "AR", "BK", "BTU"]
    private static let activityWords: Set<String> = ["POTA", "SOTA", "WWFF", "IOTA", "TEST", "CONTEST", "DX"]
    private static let exchangeWords: Set<String> = ["RST", "599", "579", "559", "589", "569", "549", "NAME", "QTH", "UR"]

    // MARK: - Feature names (must match training order)

    private static let featureNames = [
        "preceded_by_DE", "preceded_by_CQ", "followed_by_DE", "followed_by_K",
        "CQ_in_text", "is_first_call", "is_last_call", "position_norm",
        "n_unique_calls", "appears_multiple", "activity_word", "exchange_word",
        "preceded_by_call_DE", "followed_by_call", "text_starts_CQ", "has_73_SK",
    ]

    // MARK: - Initialization

    /// Creates a new extractor, loading the bundled CoreML model.
    public init() throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly // fastest for this tiny model

        guard let modelURL = Bundle.module.url(forResource: "CallsignModel", withExtension: "mlmodelc") else {
            throw CallsignExtractorError.modelNotFound
        }
        self.model = try MLModel(contentsOf: modelURL, configuration: config)
    }

    // MARK: - Public API

    /// Extracts the target callsign from decoded digital mode text.
    ///
    /// The target is the station the user would want to work — typically the
    /// station calling CQ or the station being addressed.
    ///
    /// - Parameter text: Decoded text from RTTY, PSK31, or similar digital mode.
    /// - Returns: The extracted callsign, or `nil` if none found.
    public func extractCallsign(_ text: String) -> String? {
        let upper = text.uppercased()
        let candidates = Self.extractCandidates(from: upper)

        guard !candidates.isEmpty else { return nil }

        // If there's only one candidate, return it directly
        if candidates.count == 1 {
            return candidates[0].callsign
        }

        var bestCallsign: String?
        var bestScore: Double = -1.0

        for candidate in candidates {
            let features = Self.computeFeatures(
                text: upper,
                candidate: candidate.callsign,
                charPos: candidate.position,
                allCandidates: candidates
            )

            guard let prediction = predict(features: features) else { continue }

            if prediction > bestScore {
                bestScore = prediction
                bestCallsign = candidate.callsign
            }
        }

        return bestCallsign
    }

    /// Extracts the target callsign with a confidence score.
    ///
    /// - Parameter text: Decoded text from RTTY, PSK31, or similar digital mode.
    /// - Returns: A tuple of (callsign, confidence) or `nil` if none found.
    public func extractCallsignWithConfidence(_ text: String) -> (callsign: String, confidence: Double)? {
        let upper = text.uppercased()
        let candidates = Self.extractCandidates(from: upper)

        guard !candidates.isEmpty else { return nil }

        if candidates.count == 1 {
            return (candidates[0].callsign, 1.0)
        }

        var bestCallsign: String?
        var bestScore: Double = -1.0

        for candidate in candidates {
            let features = Self.computeFeatures(
                text: upper,
                candidate: candidate.callsign,
                charPos: candidate.position,
                allCandidates: candidates
            )

            guard let prediction = predict(features: features) else { continue }

            if prediction > bestScore {
                bestScore = prediction
                bestCallsign = candidate.callsign
            }
        }

        guard let call = bestCallsign else { return nil }
        return (call, bestScore)
    }

    // MARK: - Candidate extraction

    private struct Candidate {
        let callsign: String
        let position: Int
    }

    private static func extractCandidates(from text: String) -> [Candidate] {
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = callsignPattern.matches(in: text, range: range)

        var seen = Set<String>()
        var candidates: [Candidate] = []

        for match in matches {
            let callRange = match.range(at: 1)
            let call = nsText.substring(with: callRange)

            // Must have letter(s) before digit and letter(s) after
            guard call.count >= 3 else { continue }

            let key = "\(call)-\(callRange.location)"
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            candidates.append(Candidate(callsign: call, position: callRange.location))
        }

        return candidates
    }

    // MARK: - Feature computation

    private static func computeFeatures(
        text: String,
        candidate: String,
        charPos: Int,
        allCandidates: [Candidate]
    ) -> [Double] {
        let tokens = text.split(separator: " ").map(String.init)
        let textLen = max(Double(text.count), 1.0)

        // Find token index for this candidate
        var candidateTokenIdx = -1
        var runningPos = 0
        for (i, tok) in tokens.enumerated() {
            if let tokRange = text.range(of: tok, range: text.index(text.startIndex, offsetBy: runningPos)..<text.endIndex) {
                let tokStart = text.distance(from: text.startIndex, to: tokRange.lowerBound)
                if tokStart <= charPos && charPos <= tokStart + tok.count {
                    candidateTokenIdx = i
                    break
                }
                runningPos = tokStart + tok.count
            }
        }

        func getToken(_ idx: Int) -> String {
            guard idx >= 0, idx < tokens.count else { return "" }
            return tokens[idx]
        }

        let prev1 = getToken(candidateTokenIdx - 1)
        let prev2 = getToken(candidateTokenIdx - 2)
        let next1 = getToken(candidateTokenIdx + 1)

        let uniqueCallsigns = Set(allCandidates.map(\.callsign))
        let candidateCount = allCandidates.filter { $0.callsign == candidate }.count
        let isFirst: Double = (allCandidates.first?.callsign == candidate) ? 1.0 : 0.0
        let isLast: Double = (allCandidates.last?.callsign == candidate) ? 1.0 : 0.0

        let tokensSet = Set(tokens)

        let matchesCallsign: (String) -> Bool = { str in
            let r = NSRange(location: 0, length: (str as NSString).length)
            return callsignPattern.firstMatch(in: str, range: r) != nil
        }

        return [
            // F0: preceded by DE
            deWords.contains(prev1) ? 1.0 : 0.0,
            // F1: preceded by CQ
            (cqWords.contains(prev1) || cqWords.contains(prev2)) ? 1.0 : 0.0,
            // F2: followed by DE
            deWords.contains(next1) ? 1.0 : 0.0,
            // F3: followed by K/KN/end marker
            endWords.contains(next1) ? 1.0 : 0.0,
            // F4: CQ anywhere in text
            tokensSet.contains("CQ") ? 1.0 : 0.0,
            // F5: is first callsign
            isFirst,
            // F6: is last callsign
            isLast,
            // F7: normalized position
            Double(charPos) / textLen,
            // F8: number of unique callsigns (capped at 6)
            Double(min(uniqueCallsigns.count, 6)),
            // F9: appears multiple times
            candidateCount > 1 ? 1.0 : 0.0,
            // F10: activity word nearby
            tokensSet.intersection(activityWords).isEmpty ? 0.0 : 1.0,
            // F11: exchange words nearby
            tokensSet.intersection(exchangeWords).isEmpty ? 0.0 : 1.0,
            // F12: preceded by call+DE pattern
            (deWords.contains(prev1) && candidateTokenIdx >= 2 && matchesCallsign(getToken(candidateTokenIdx - 2))) ? 1.0 : 0.0,
            // F13: followed by another callsign
            (!next1.isEmpty && matchesCallsign(next1) && next1 != candidate) ? 1.0 : 0.0,
            // F14: text starts with CQ
            (tokens.first == "CQ") ? 1.0 : 0.0,
            // F15: 73 or SK in text
            (tokensSet.contains("73") || tokensSet.contains("SK")) ? 1.0 : 0.0,
        ]
    }

    // MARK: - Model inference

    private func predict(features: [Double]) -> Double? {
        let featureDict: [String: Double] = Dictionary(
            uniqueKeysWithValues: zip(Self.featureNames, features)
        )

        let provider = try? MLDictionaryFeatureProvider(
            dictionary: featureDict as [String: NSNumber]
        )
        guard let provider else { return nil }

        guard let output = try? model.prediction(from: provider) else { return nil }

        // The model outputs class probabilities — get the probability of class 1 (target)
        if let probs = output.featureValue(for: "classProbability")?.dictionaryValue {
            if let val = probs[1 as NSNumber] as? Double { return val }
            if let val = probs[NSNumber(value: 1)] as? Double { return val }
            return 0.0
        }

        return nil
    }
}

// MARK: - Errors

public enum CallsignExtractorError: Error, CustomStringConvertible {
    case modelNotFound

    public var description: String {
        switch self {
        case .modelNotFound:
            return "CallsignModel.mlmodelc not found in bundle resources"
        }
    }
}
