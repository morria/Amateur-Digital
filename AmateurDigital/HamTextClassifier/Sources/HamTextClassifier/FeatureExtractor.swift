import Foundation

/// Extracts character-level features from text for ham radio classification.
///
/// This must produce identical feature dictionaries to the Python `extract_features()` function
/// in `Training/train_model.py`.
enum FeatureExtractor {
    // Pre-compiled regex patterns
    private static let callsignPattern = try! NSRegularExpression(pattern: "[A-Z]{1,2}[0-9][A-Z]{1,3}")
    private static let rstPattern = try! NSRegularExpression(pattern: "\\b[1-5][1-9][1-9]?\\b")
    private static let gridPattern = try! NSRegularExpression(
        pattern: "\\b[A-Ra-r]{2}[0-9]{2}(?:[a-xA-X]{2})?\\b"
    )
    private static let cqPattern = try! NSRegularExpression(
        pattern: "\\bCQ\\b", options: .caseInsensitive
    )
    private static let dePattern = try! NSRegularExpression(
        pattern: "\\bDE\\b", options: .caseInsensitive
    )
    private static let seventyThreePattern = try! NSRegularExpression(pattern: "\\b73\\b")
    private static let dbReportPattern = try! NSRegularExpression(pattern: "[+-]\\d{2}\\b")
    private static let rrrPattern = try! NSRegularExpression(pattern: "\\bR(?:RR|R73)\\b")

    /// Extract features from text, returning a dictionary matching the Python feature extractor.
    static func extractFeatures(from text: String) -> [String: Double] {
        var features: [String: Double] = [:]

        let length = text.count
        guard length > 0 else {
            features["len"] = 0.0
            features["alpha_ratio"] = 0.0
            features["digit_ratio"] = 0.0
            features["space_ratio"] = 0.0
            features["upper_ratio"] = 0.0
            features["special_ratio"] = 0.0
            features["entropy"] = 0.0
            return features
        }

        let scalars = Array(text.unicodeScalars)
        var alphaCount = 0
        var digitCount = 0
        var spaceCount = 0
        var upperCount = 0

        for scalar in scalars {
            if CharacterSet.letters.contains(scalar) {
                alphaCount += 1
                if CharacterSet.uppercaseLetters.contains(scalar) {
                    upperCount += 1
                }
            } else if CharacterSet.decimalDigits.contains(scalar) {
                digitCount += 1
            } else if scalar == " " {
                spaceCount += 1
            }
        }

        let specialCount = length - alphaCount - digitCount - spaceCount
        let dLength = Double(length)

        // Statistical features
        features["len"] = min(dLength / 200.0, 1.0)
        features["alpha_ratio"] = Double(alphaCount) / dLength
        features["digit_ratio"] = Double(digitCount) / dLength
        features["space_ratio"] = Double(spaceCount) / dLength
        features["upper_ratio"] = alphaCount > 0 ? Double(upperCount) / dLength : 0.0
        features["special_ratio"] = Double(specialCount) / dLength
        features["entropy"] = shannonEntropy(text) / 8.0

        // Character bigrams on uppercased text
        let upperText = Array(text.uppercased().unicodeScalars)
        for i in 0..<(upperText.count - 1) {
            let c0 = upperText[i]
            let c1 = upperText[i + 1]
            if isAlnumOrSpace(c0) && isAlnumOrSpace(c1) {
                let key = "bi_\(Character(c0))\(Character(c1))"
                features[key, default: 0.0] += 1.0
            }
        }

        // Character trigrams on uppercased text
        for i in 0..<(upperText.count - 2) {
            let c0 = upperText[i]
            let c1 = upperText[i + 1]
            let c2 = upperText[i + 2]
            if isAlnumOrSpace(c0) && isAlnumOrSpace(c1) && isAlnumOrSpace(c2) {
                let key = "tri_\(Character(c0))\(Character(c1))\(Character(c2))"
                features[key, default: 0.0] += 1.0
            }
        }

        // Pattern matches
        let nsText = text as NSString
        let upperNSText = text.uppercased() as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let upperFullRange = NSRange(location: 0, length: upperNSText.length)

        features["has_callsign"] = Self.callsignPattern.firstMatch(
            in: text.uppercased(), range: upperFullRange
        ) != nil ? 1.0 : 0.0

        features["has_rst"] = Self.rstPattern.firstMatch(in: text, range: fullRange) != nil ? 1.0 : 0.0
        features["has_grid"] = Self.gridPattern.firstMatch(in: text, range: fullRange) != nil ? 1.0 : 0.0
        features["has_cq"] = Self.cqPattern.firstMatch(in: text, range: fullRange) != nil ? 1.0 : 0.0
        features["has_de"] = Self.dePattern.firstMatch(in: text, range: fullRange) != nil ? 1.0 : 0.0
        features["has_73"] = Self.seventyThreePattern.firstMatch(
            in: text, range: fullRange
        ) != nil ? 1.0 : 0.0
        features["has_db_report"] = Self.dbReportPattern.firstMatch(
            in: text, range: fullRange
        ) != nil ? 1.0 : 0.0
        features["has_rrr"] = Self.rrrPattern.firstMatch(in: text, range: fullRange) != nil ? 1.0 : 0.0

        return features
    }

    private static func isAlnumOrSpace(_ scalar: Unicode.Scalar) -> Bool {
        return CharacterSet.alphanumerics.contains(scalar) || scalar == " "
    }

    private static func shannonEntropy(_ text: String) -> Double {
        guard !text.isEmpty else { return 0.0 }

        var freq: [Character: Int] = [:]
        for ch in text {
            freq[ch, default: 0] += 1
        }

        let length = Double(text.count)
        var entropy = 0.0
        for count in freq.values {
            let p = Double(count) / length
            if p > 0 {
                entropy -= p * Foundation.log2(p)
            }
        }
        return entropy
    }
}
