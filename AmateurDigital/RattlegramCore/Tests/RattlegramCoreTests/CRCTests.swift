import XCTest
@testable import RattlegramCore

final class CRCTests: XCTestCase {
    func testCRC16Reset() {
        var crc = CRC<UInt16>(poly: 0xA8F4)
        crc.update(byte: 0x41)
        let v1 = crc.value
        crc.reset()
        crc.update(byte: 0x41)
        let v2 = crc.value
        XCTAssertEqual(v1, v2)
    }

    func testCRC16Deterministic() {
        var crc = CRC<UInt16>(poly: 0xA8F4)
        crc.update(byte: 0x00)
        let v1 = crc.value

        var crc2 = CRC<UInt16>(poly: 0xA8F4)
        crc2.update(byte: 0x00)
        let v2 = crc2.value

        XCTAssertEqual(v1, v2)
    }

    func testCRC16DifferentInputs() {
        var crc1 = CRC<UInt16>(poly: 0xA8F4)
        crc1.update(byte: 0x01)

        var crc2 = CRC<UInt16>(poly: 0xA8F4)
        crc2.update(byte: 0x02)

        XCTAssertNotEqual(crc1.value, crc2.value)
    }

    func testCRC32Deterministic() {
        var crc = CRC<UInt32>(poly: 0x8F6E37A0)
        crc.update(byte: 0x48) // 'H'
        crc.update(byte: 0x45) // 'E'
        crc.update(byte: 0x4C) // 'L'
        crc.update(byte: 0x4C) // 'L'
        crc.update(byte: 0x4F) // 'O'
        let v1 = crc.value

        var crc2 = CRC<UInt32>(poly: 0x8F6E37A0)
        for byte in [UInt8(0x48), 0x45, 0x4C, 0x4C, 0x4F] {
            crc2.update(byte: byte)
        }
        XCTAssertEqual(v1, crc2.value)
    }

    func testCRC16Uint64Update() {
        var crc = CRC<UInt16>(poly: 0xA8F4)
        crc.update(uint64: 0x1234567890ABCDEF)
        let v = crc.value
        XCTAssertNotEqual(v, 0) // Just ensure it produces a non-zero value
    }
}
