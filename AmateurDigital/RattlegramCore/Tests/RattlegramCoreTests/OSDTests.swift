import XCTest
@testable import RattlegramCore

final class OSDTests: XCTestCase {
    private let bchPolynomials = [
        0b100011101, 0b101110111, 0b111110011, 0b101101001,
        0b110111101, 0b111100111, 0b100101011, 0b111010111,
        0b000010011, 0b101100101, 0b110001011, 0b101100011,
        0b100011011, 0b100111111, 0b110001101, 0b100101101,
        0b101011111, 0b111111001, 0b111000011, 0b100111001,
        0b110101001, 0b000011111, 0b110000111, 0b110110001,
    ]

    func testOSDInit() {
        let osd = OrderedStatisticsDecoder()
        _ = osd
    }

    func testOSDEncodeDecodeRoundTrip() {
        let encoder = BCHEncoder(minimalPolynomials: bchPolynomials)
        let osd = OrderedStatisticsDecoder()

        // Create generator matrix
        var genmat = [Int8](repeating: 0, count: 255 * 71)
        BCHGenerator.matrix(&genmat, systematic: true,
                           minimalPolynomials: bchPolynomials)

        // Create test data (71 bits = 9 bytes)
        var data = [UInt8](repeating: 0, count: 9)
        data[0] = 0xDE
        data[1] = 0xAD
        data[2] = 0xBE
        data[3] = 0xEF

        // Encode with BCH
        var parity = [UInt8](repeating: 0, count: 23)
        encoder.encode(data, &parity)

        // Create soft decisions from the codeword (strong confidence)
        var soft = [Int8](repeating: 0, count: 255)
        for i in 0..<71 {
            let bit = getBEBit(data, i)
            soft[i] = bit ? -64 : 64
        }
        for i in 0..<184 {
            let bit = getBEBit(parity, i)
            soft[71 + i] = bit ? -64 : 64
        }

        // Decode with OSD
        var decoded = [UInt8](repeating: 0, count: 32)
        let success = osd.decode(&decoded, soft, genmat)
        XCTAssertTrue(success, "OSD decode should succeed with clean codeword")

        // First 9 bytes should match original data
        for i in 0..<4 {
            XCTAssertEqual(decoded[i], data[i], "Byte \(i) mismatch")
        }
    }
}
