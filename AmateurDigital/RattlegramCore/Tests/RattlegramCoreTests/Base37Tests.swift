import XCTest
@testable import RattlegramCore

final class Base37Tests: XCTestCase {
    func testEncodeDecodeRoundTrip() {
        let callSign = "W1AW"
        let encoded = Base37.encode(callSign)
        let decoded = Base37.decode(encoded, length: 9)
        // Decoded is padded to 9 chars with spaces
        XCTAssertEqual(decoded.trimmingCharacters(in: .whitespaces), callSign)
    }

    func testEncodeDeterministic() {
        let v1 = Base37.encode("TEST")
        let v2 = Base37.encode("TEST")
        XCTAssertEqual(v1, v2)
    }

    func testEncodeDifferentValues() {
        let v1 = Base37.encode("AA")
        let v2 = Base37.encode("AB")
        XCTAssertNotEqual(v1, v2)
    }

    func testEmptyString() {
        let v = Base37.encode("")
        XCTAssertEqual(v, 0)
    }

    func testMapCharacters() {
        // Mapping: space=0, 0-9=1-10, A-Z=11-36
        XCTAssertEqual(Base37.map(Character(" ")), 0)
        XCTAssertEqual(Base37.map(Character("0")), 1)
        XCTAssertEqual(Base37.map(Character("9")), 10)
        XCTAssertEqual(Base37.map(Character("A")), 11)
        XCTAssertEqual(Base37.map(Character("Z")), 36)
        XCTAssertEqual(Base37.map(Character("a")), 11) // lowercase maps same as uppercase
    }

    func testMaxCallSign() {
        let call = "WA1BCDEFG"
        let encoded = Base37.encode(call)
        XCTAssertGreaterThan(encoded, 0)
        XCTAssertLessThan(encoded, 129961739795077)
        let decoded = Base37.decode(encoded, length: 9)
        XCTAssertEqual(decoded, call)
    }
}
