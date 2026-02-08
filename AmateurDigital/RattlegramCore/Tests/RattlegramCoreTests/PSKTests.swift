import XCTest
@testable import RattlegramCore

final class PSKTests: XCTestCase {
    func testBPSKMapAndHard() {
        // BPSK hard returns -1 or +1 (NRZ)
        // map(1) -> positive real, map(-1) -> negative real
        let p = BPSK.map(1)
        XCTAssertGreaterThan(p.real, 0)
        let n = BPSK.map(-1)
        XCTAssertLessThan(n.real, 0)

        XCTAssertEqual(BPSK.hard(p), 1)
        XCTAssertEqual(BPSK.hard(n), -1)
    }

    func testBPSKSoft() {
        let p = BPSK.map(1)
        let softVal = BPSK.soft(p, precision: 32)
        XCTAssertGreaterThan(softVal, 0)

        let n = BPSK.map(-1)
        let softNeg = BPSK.soft(n, precision: 32)
        XCTAssertLessThan(softNeg, 0)
    }

    func testQPSKMapAndHard() {
        // QPSK uses NRZ: -1 and +1
        for b0: Int8 in [-1, 1] {
            for b1: Int8 in [-1, 1] {
                let mapped = QPSK.map(b0, b1)
                let (h0, h1) = QPSK.hard(mapped)
                XCTAssertEqual(h0, b0, "QPSK hard decision mismatch for (\(b0), \(b1))")
                XCTAssertEqual(h1, b1, "QPSK hard decision mismatch for (\(b0), \(b1))")
            }
        }
    }

    func testQPSKSoft() {
        let mapped = QPSK.map(1, -1)
        var code = [Int8](repeating: 0, count: 2)
        QPSK.soft(&code, offset: 0, mapped, precision: 32)
        // First bit mapped to +1 -> positive soft value
        XCTAssertGreaterThan(code[0], 0)
        // Second bit mapped to -1 -> negative soft value
        XCTAssertLessThan(code[1], 0)
    }

    func testQPSKConstellationSymmetry() {
        let p00 = QPSK.map(1, 1)
        let p01 = QPSK.map(1, -1)
        let p10 = QPSK.map(-1, 1)
        let p11 = QPSK.map(-1, -1)

        let m00 = norm(p00)
        let m01 = norm(p01)
        let m10 = norm(p10)
        let m11 = norm(p11)
        XCTAssertEqual(m00, m01, accuracy: 1e-6)
        XCTAssertEqual(m01, m10, accuracy: 1e-6)
        XCTAssertEqual(m10, m11, accuracy: 1e-6)
    }
}
