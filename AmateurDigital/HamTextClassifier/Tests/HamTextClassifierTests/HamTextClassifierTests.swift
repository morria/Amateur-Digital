import Foundation
import Testing

@testable import HamTextClassifier

// MARK: - Feature Extractor Tests

@Suite("FeatureExtractor")
struct FeatureExtractorTests {
    @Test("Empty string returns zero features")
    func emptyString() {
        let features = FeatureExtractor.extractFeatures(from: "")
        #expect(features["len"] == 0.0)
        #expect(features["alpha_ratio"] == 0.0)
        #expect(features["entropy"] == 0.0)
    }

    @Test("Statistical features are computed correctly")
    func statisticalFeatures() {
        let features = FeatureExtractor.extractFeatures(from: "CQ DE W1AW")
        #expect(features["len"]! > 0)
        #expect(features["alpha_ratio"]! > 0)
        #expect(features["digit_ratio"]! > 0)
        #expect(features["space_ratio"]! > 0)
        #expect(features["upper_ratio"]! > 0)
        #expect(features["entropy"]! > 0)
    }

    @Test("Bigrams are extracted from uppercased text")
    func bigrams() {
        let features = FeatureExtractor.extractFeatures(from: "CQ")
        #expect(features["bi_CQ"] == 1.0)
    }

    @Test("Trigrams are extracted from uppercased text")
    func trigrams() {
        let features = FeatureExtractor.extractFeatures(from: "CQ ")
        #expect(features["tri_CQ "] == 1.0)
    }

    @Test("Callsign pattern is detected")
    func callsignDetection() {
        let features = FeatureExtractor.extractFeatures(from: "W1AW")
        #expect(features["has_callsign"] == 1.0)

        let noCallsign = FeatureExtractor.extractFeatures(from: "hello world")
        #expect(noCallsign["has_callsign"] == 0.0)
    }

    @Test("Grid square pattern is detected")
    func gridDetection() {
        let features = FeatureExtractor.extractFeatures(from: "FN31pr")
        #expect(features["has_grid"] == 1.0)

        let fourChar = FeatureExtractor.extractFeatures(from: "FN31")
        #expect(fourChar["has_grid"] == 1.0)
    }

    @Test("CQ pattern is detected case-insensitively")
    func cqDetection() {
        let upper = FeatureExtractor.extractFeatures(from: "CQ CQ")
        #expect(upper["has_cq"] == 1.0)

        let lower = FeatureExtractor.extractFeatures(from: "cq cq")
        #expect(lower["has_cq"] == 1.0)
    }

    @Test("73 pattern is detected")
    func seventyThreeDetection() {
        let features = FeatureExtractor.extractFeatures(from: "best 73 de W1AW")
        #expect(features["has_73"] == 1.0)
    }

    @Test("dB report pattern is detected")
    func dbReportDetection() {
        let features = FeatureExtractor.extractFeatures(from: "W1AW K3LR -15")
        #expect(features["has_db_report"] == 1.0)
    }

    @Test("RRR/RR73 pattern is detected")
    func rrrDetection() {
        let rrr = FeatureExtractor.extractFeatures(from: "W1AW K3LR RRR")
        #expect(rrr["has_rrr"] == 1.0)

        let rr73 = FeatureExtractor.extractFeatures(from: "W1AW K3LR RR73")
        #expect(rr73["has_rrr"] == 1.0)
    }

    @Test("Special character ratio for punctuation-heavy text")
    func specialRatio() {
        let features = FeatureExtractor.extractFeatures(from: "!@#$%^&*()")
        #expect(features["special_ratio"]! > 0.9)
    }

    @Test("Normalized length is capped at 1.0")
    func normalizedLength() {
        let longText = String(repeating: "A", count: 300)
        let features = FeatureExtractor.extractFeatures(from: longText)
        #expect(features["len"] == 1.0)
    }
}

// MARK: - Classifier Integration Tests

@Suite("HamTextClassifier")
struct HamTextClassifierIntegrationTests {
    let classifier: HamTextClassifier

    init() throws {
        classifier = try HamTextClassifier()
    }

    // RTTY
    @Test("RTTY CQ is legitimate")
    func rttyCQ() {
        let result = classifier.classify("CQ CQ CQ DE W1AW W1AW K")
        #expect(result.isLegitimate)
        #expect(result.confidence > 0.7)
    }

    @Test("RTTY QSO exchange is legitimate")
    func rttyQSO() {
        let result = classifier.classify("K3LR DE W1AW UR RST 599 599 NAME IS JOHN QTH IS NEW YORK K")
        #expect(result.isLegitimate)
    }

    @Test("RTTY contest exchange is legitimate")
    func rttyContest() {
        let result = classifier.classify("K3LR DE W1AW 5NN 0042 0042")
        #expect(result.isLegitimate)
    }

    // PSK31
    @Test("PSK31 conversational text is legitimate")
    func pskConversation() {
        let result = classifier.classify(
            "Hello Bob, thanks for the call. Your RST is 599. My name is John and QTH is Boston. btu"
        )
        #expect(result.isLegitimate)
    }

    @Test("PSK31 rig description is legitimate")
    func pskRigInfo() {
        let result = classifier.classify("My rig is a IC-7300 running 100w into a dipole on 20M.")
        #expect(result.isLegitimate)
    }

    // FT8
    @Test("FT8 CQ is legitimate")
    func ft8CQ() {
        let result = classifier.classify("CQ W1AW FN31")
        #expect(result.isLegitimate)
    }

    @Test("FT8 signal report is legitimate")
    func ft8Signal() {
        let result = classifier.classify("W1AW K3LR -15")
        #expect(result.isLegitimate)
    }

    @Test("FT8 RR73 is legitimate")
    func ft8RR73() {
        let result = classifier.classify("W1AW K3LR RR73")
        #expect(result.isLegitimate)
    }

    @Test("FT8 73 is legitimate")
    func ft873() {
        let result = classifier.classify("W1AW K3LR 73")
        #expect(result.isLegitimate)
    }

    // Rattlegram
    @Test("Rattlegram position report is legitimate")
    func rattlegramPosition() {
        let result = classifier.classify("W1AW position 40.7128 -74.0060")
        #expect(result.isLegitimate)
    }

    @Test("Rattlegram net check-in is legitimate")
    func rattlegramCheckIn() {
        let result = classifier.classify("Net check-in de W1AW all ok")
        #expect(result.isLegitimate)
    }

    // Garbage
    @Test("Random ASCII is garbage")
    func randomASCII() {
        let result = classifier.classify("xkjr89#$@mz!pq")
        #expect(!result.isLegitimate)
    }

    @Test("Repeated characters are garbage")
    func repeatedChars() {
        let result = classifier.classify("aaaaaaaaaaaaaaaaaaa")
        #expect(!result.isLegitimate)
    }

    @Test("Random punctuation is garbage")
    func randomPunctuation() {
        let result = classifier.classify("!@#$%^&*()_+-=[]{}|")
        #expect(!result.isLegitimate)
    }

    @Test("Random spaced letters are garbage")
    func randomSpaced() {
        let result = classifier.classify("asjkdf lqwer poiuyt zxcvb")
        #expect(!result.isLegitimate)
    }
}

// MARK: - Golden Test Pairs

@Suite("Golden Test Pairs")
struct GoldenTestPairTests {
    struct GoldenPair: Decodable {
        let text: String
        let expected_label: Int
        let predicted_label: Int
        let confidence: Double
    }

    let classifier: HamTextClassifier

    init() throws {
        classifier = try HamTextClassifier()
    }

    @Test("Golden test pairs achieve >95% accuracy")
    func goldenPairsAccuracy() throws {
        guard let url = Bundle.module.url(forResource: "golden_test_pairs", withExtension: "json") else {
            Issue.record("golden_test_pairs.json not found in test bundle")
            return
        }

        let data = try Data(contentsOf: url)
        let pairs = try JSONDecoder().decode([GoldenPair].self, from: data)

        var correct = 0
        for pair in pairs {
            let result = classifier.classify(pair.text)
            if result.label == pair.expected_label {
                correct += 1
            }
        }

        let accuracy = Double(correct) / Double(pairs.count)
        #expect(accuracy > 0.95, "Golden pairs accuracy \(accuracy) is below 95%")
    }
}

// MARK: - Performance Tests

@Suite("Performance")
struct PerformanceTests {
    let classifier: HamTextClassifier

    init() throws {
        classifier = try HamTextClassifier()
    }

    @Test("Classification completes in under 1ms")
    func classificationLatency() {
        let texts = [
            "CQ CQ CQ DE W1AW K",
            "W1AW K3LR -15",
            "xkjr89#$@mz!pq",
            "Hello Bob, thanks for the call. Your RST is 599.",
            "aaaaaaaaaaaaaaaaaaa",
        ]

        // Warm up
        for text in texts {
            _ = classifier.classify(text)
        }

        let iterations = 100
        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<iterations {
            for text in texts {
                _ = classifier.classify(text)
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let perClassification = (elapsed / Double(iterations * texts.count)) * 1000.0 // ms

        #expect(perClassification < 1.0, "Classification took \(perClassification)ms, expected <1ms")
    }
}
