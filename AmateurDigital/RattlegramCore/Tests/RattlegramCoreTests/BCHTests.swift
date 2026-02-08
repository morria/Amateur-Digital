import XCTest
@testable import RattlegramCore

final class BCHTests: XCTestCase {
    private let bchPolynomials = [
        0b100011101, 0b101110111, 0b111110011, 0b101101001,
        0b110111101, 0b111100111, 0b100101011, 0b111010111,
        0b000010011, 0b101100101, 0b110001011, 0b101100011,
        0b100011011, 0b100111111, 0b110001101, 0b100101101,
        0b101011111, 0b111111001, 0b111000011, 0b100111001,
        0b110101001, 0b000011111, 0b110000111, 0b110110001,
    ]

    func testBCHEncoderInit() {
        let encoder = BCHEncoder(minimalPolynomials: bchPolynomials)
        _ = encoder // Should not crash
    }

    func testBCHEncodeDeterministic() {
        let encoder = BCHEncoder(minimalPolynomials: bchPolynomials)

        var data = [UInt8](repeating: 0, count: 9)
        data[0] = 0xAB
        data[1] = 0xCD
        var parity1 = [UInt8](repeating: 0, count: 23)
        var parity2 = [UInt8](repeating: 0, count: 23)

        encoder.encode(data, &parity1)
        encoder.encode(data, &parity2)

        XCTAssertEqual(parity1, parity2)
    }

    func testBCHEncodeDifferentData() {
        let encoder = BCHEncoder(minimalPolynomials: bchPolynomials)

        var data1 = [UInt8](repeating: 0, count: 9)
        var data2 = [UInt8](repeating: 0, count: 9)
        data1[0] = 0x01
        data2[0] = 0x02

        var parity1 = [UInt8](repeating: 0, count: 23)
        var parity2 = [UInt8](repeating: 0, count: 23)

        encoder.encode(data1, &parity1)
        encoder.encode(data2, &parity2)

        XCTAssertNotEqual(parity1, parity2)
    }

    func testBCHGeneratorMatrix() {
        var generator = [Int8](repeating: 0, count: 255 * 71)
        BCHGenerator.matrix(&generator, systematic: true,
                           minimalPolynomials: bchPolynomials)

        // Check that the generator matrix has non-zero entries
        var nonZero = 0
        for v in generator {
            if v != 0 { nonZero += 1 }
        }
        XCTAssertGreaterThan(nonZero, 0)
    }
}
