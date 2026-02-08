/*
 Base37 encoding/decoding and bitmap - ported from encoder.hh/decoder.hh/base37_bitmap.hh
 Original Copyright 2018 Ahmet Inan <inan@aicodix.de>
 */

public enum Base37 {
    private static let decodeTable: [Character] = Array(" 0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ")

    public static func map(_ c: Character) -> UInt8 {
        let ascii = c.asciiValue ?? 0
        let a0: UInt8 = 0x30 // '0'
        let a9: UInt8 = 0x39 // '9'
        let la: UInt8 = 0x61 // 'a'
        let lz: UInt8 = 0x7A // 'z'
        let uA: UInt8 = 0x41 // 'A'
        let uZ: UInt8 = 0x5A // 'Z'
        if ascii >= a0 && ascii <= a9 {
            return ascii - a0 + 1
        }
        if ascii >= la && ascii <= lz {
            return ascii - la + 11
        }
        if ascii >= uA && ascii <= uZ {
            return ascii - uA + 11
        }
        return 0
    }

    public static func encode(_ str: String) -> UInt64 {
        var acc: UInt64 = 0
        for c in str {
            acc = 37 &* acc &+ UInt64(map(c))
        }
        return acc
    }

    public static func decode(_ val: UInt64, length: Int) -> String {
        var result = [Character](repeating: " ", count: length)
        var v = val
        for i in stride(from: length - 1, through: 0, by: -1) {
            result[i] = decodeTable[Int(v % 37)]
            v /= 37
        }
        return String(result)
    }

    public static let bitmap: [UInt8] = [
        0, 60, 8, 60, 60, 2, 126, 28, 126, 60, 60, 60, 124, 60, 120, 126,
        126, 60, 66, 56, 14, 66, 64, 130, 66, 60, 124, 60, 124, 60, 254, 66,
        66, 130, 66, 130, 126, 0, 66, 24, 66, 66, 6, 64, 32, 2, 66, 66, 66,
        66, 66, 68, 64, 64, 66, 66, 16, 4, 68, 64, 198, 66, 66, 66, 66, 66,
        66, 16, 66, 66, 130, 66, 130, 2, 0, 66, 40, 66, 66, 10, 64, 64, 2,
        66, 66, 66, 66, 66, 66, 64, 64, 66, 66, 16, 4, 72, 64, 170, 66, 66,
        66, 66, 66, 64, 16, 66, 66, 130, 36, 68, 2, 0, 70, 8, 2, 2, 18, 64,
        64, 4, 66, 66, 66, 66, 64, 66, 64, 64, 64, 66, 16, 4, 80, 64, 146,
        98, 66, 66, 66, 66, 64, 16, 66, 66, 130, 36, 68, 4, 0, 74, 8, 4, 28,
        34, 124, 124, 4, 60, 66, 66, 124, 64, 66, 120, 120, 64, 126, 16, 4,
        96, 64, 146, 82, 66, 66, 66, 66, 60, 16, 66, 66, 130, 24, 40, 8, 0,
        82, 8, 8, 2, 66, 2, 66, 8, 66, 62, 126, 66, 64, 66, 64, 64, 78, 66,
        16, 4, 96, 64, 130, 74, 66, 124, 66, 124, 2, 16, 66, 36, 146, 24, 16,
        16, 0, 98, 8, 16, 2, 126, 2, 66, 8, 66, 2, 66, 66, 64, 66, 64, 64,
        66, 66, 16, 4, 80, 64, 130, 70, 66, 64, 66, 80, 2, 16, 66, 36, 146,
        36, 16, 32, 0, 66, 8, 32, 66, 2, 2, 66, 16, 66, 2, 66, 66, 66, 66,
        64, 64, 66, 66, 16, 68, 72, 64, 130, 66, 66, 64, 66, 72, 66, 16, 66,
        36, 170, 36, 16, 64, 0, 66, 8, 64, 66, 2, 66, 66, 16, 66, 4, 66, 66,
        66, 68, 64, 64, 66, 66, 16, 68, 68, 64, 130, 66, 66, 64, 74, 68, 66,
        16, 66, 24, 198, 66, 16, 64, 0, 60, 62, 126, 60, 2, 60, 60, 16, 60,
        56, 66, 124, 60, 120, 126, 64, 60, 66, 56, 56, 66, 126, 130, 66, 60,
        64, 60, 66, 60, 16, 60, 24, 130, 66, 16, 126, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0,
        0, 0, 0, 0, 0, 0, 0, 0,
    ]
}

