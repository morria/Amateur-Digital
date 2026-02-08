import XCTest
@testable import RattlegramCore

final class MLSTests: XCTestCase {
    func testMLSPeriod() {
        // MLS with poly degree n has period 2^n - 1
        // poly 0b10001001 is degree 7, period = 127
        // Collect one full period of outputs
        var seq = MLS(poly: 0b10001001)
        var fullSeq = [Bool]()
        for _ in 0..<127 {
            fullSeq.append(seq.next())
        }
        // Verify the sequence repeats exactly after 127 steps
        for i in 0..<127 {
            XCTAssertEqual(seq.next(), fullSeq[i],
                "MLS output should repeat after period 127, mismatch at step \(i)")
        }
        // Also verify via the bad() method (returns false for valid MLS)
        var check = MLS(poly: 0b10001001)
        XCTAssertFalse(check.bad(), "MLS with degree-7 poly should be a valid MLS")
    }

    func testMLSBalance() {
        // In a full period of MLS, there should be (2^n)/2 ones and (2^n)/2 - 1 zeros
        // For degree 7: 64 ones and 63 zeros
        var seq = MLS(poly: 0b10001001)
        var ones = 0
        var zeros = 0
        for _ in 0..<127 {
            if seq.next() {
                ones += 1
            } else {
                zeros += 1
            }
        }
        XCTAssertEqual(ones, 64)
        XCTAssertEqual(zeros, 63)
    }

    func testMLSDeterministic() {
        var seq1 = MLS(poly: 0b10001001)
        var seq2 = MLS(poly: 0b10001001)
        for _ in 0..<100 {
            XCTAssertEqual(seq1.next(), seq2.next())
        }
    }

    func testMLSDifferentPolys() {
        var seq1 = MLS(poly: 0b10001001)
        var seq2 = MLS(poly: 0b100101011) // degree 8, period 255
        var differ = false
        for _ in 0..<50 {
            if seq1.next() != seq2.next() {
                differ = true
                break
            }
        }
        XCTAssertTrue(differ, "Different polynomials should produce different sequences")
    }
}
