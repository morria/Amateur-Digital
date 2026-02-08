/*
 SIMD-like vector for polar list decoder - replaces C++ SIMD<int8_t, WIDTH>
 Uses WIDTH=16 list paths (matches C++ 128-bit SIMD)
 */

public struct SIMDVector {
    public static let SIZE = 16
    public var v: [Int8]

    public init() {
        v = [Int8](repeating: 0, count: SIMDVector.SIZE)
    }

    public init(repeating value: Int8) {
        v = [Int8](repeating: value, count: SIMDVector.SIZE)
    }

    public subscript(index: Int) -> Int8 {
        get { v[index] }
        set { v[index] = newValue }
    }
}

/// Duplicate scalar to all lanes
@inlinable
public func vdup(_ value: Int8) -> SIMDVector {
    SIMDVector(repeating: value)
}

/// Zero vector
@inlinable
public func vzero() -> SIMDVector {
    SIMDVector()
}

/// Shuffle/permute: result[k] = a[map[k]]
@inlinable
public func vshuf(_ a: SIMDVector, _ map: SIMDMap) -> SIMDVector {
    var result = SIMDVector()
    for k in 0..<SIMDVector.SIZE {
        result.v[k] = a.v[Int(map.v[k])]
    }
    return result
}

/// Permutation map (UInt8 indices)
public struct SIMDMap {
    public var v: [UInt8]

    public init() {
        v = [UInt8](repeating: 0, count: SIMDVector.SIZE)
    }

    public subscript(index: Int) -> UInt8 {
        get { v[index] }
        set { v[index] = newValue }
    }
}

/// Shuffle map by map: result[k] = a[map[k]]
@inlinable
public func vshuf(_ a: SIMDMap, _ map: SIMDMap) -> SIMDMap {
    var result = SIMDMap()
    for k in 0..<SIMDVector.SIZE {
        result.v[k] = a.v[Int(map.v[k])]
    }
    return result
}

// MARK: - PolarHelper for SIMDVector

public enum PolarHelperSIMD {
    @inlinable
    public static func one() -> SIMDVector { vdup(1) }

    @inlinable
    public static func zero() -> SIMDVector { vzero() }

    @inlinable
    public static func signum(_ a: SIMDVector) -> SIMDVector {
        var r = SIMDVector()
        for k in 0..<SIMDVector.SIZE {
            r.v[k] = (a.v[k] > 0 ? 1 : 0) - (a.v[k] < 0 ? 1 : 0)
        }
        return r
    }

    @inlinable
    public static func qabs(_ a: SIMDVector) -> SIMDVector {
        var r = SIMDVector()
        for k in 0..<SIMDVector.SIZE {
            let clamped = max(a.v[k], -127)
            r.v[k] = clamped < 0 ? -clamped : clamped
        }
        return r
    }

    @inlinable
    public static func qadd(_ a: SIMDVector, _ b: SIMDVector) -> SIMDVector {
        var r = SIMDVector()
        for k in 0..<SIMDVector.SIZE {
            let sum = Int16(a.v[k]) + Int16(b.v[k])
            r.v[k] = Int8(clamping: min(max(sum, -127), 127))
        }
        return r
    }

    @inlinable
    public static func qmul(_ a: SIMDVector, _ b: SIMDVector) -> SIMDVector {
        var r = SIMDVector()
        for k in 0..<SIMDVector.SIZE {
            r.v[k] = a.v[k] * b.v[k] // only used for ±1 hard decisions
        }
        return r
    }

    @inlinable
    public static func prod(_ a: SIMDVector, _ b: SIMDVector) -> SIMDVector {
        let sa = signum(a), sb = signum(b)
        let aa = qabs(a), ab = qabs(b)
        var r = SIMDVector()
        for k in 0..<SIMDVector.SIZE {
            r.v[k] = sa.v[k] * sb.v[k] * min(aa.v[k], ab.v[k])
        }
        return r
    }

    @inlinable
    public static func madd(_ a: SIMDVector, _ b: SIMDVector, _ c: SIMDVector) -> SIMDVector {
        var r = SIMDVector()
        for k in 0..<SIMDVector.SIZE {
            let bClamped = max(b.v[k], -127)
            let result = Int16(a.v[k]) * Int16(bClamped) + Int16(c.v[k])
            r.v[k] = Int8(clamping: max(min(result, 127), -127))
        }
        return r
    }

    @inlinable
    public static func vmin(_ a: SIMDVector, _ b: SIMDVector) -> SIMDVector {
        var r = SIMDVector()
        for k in 0..<SIMDVector.SIZE {
            r.v[k] = min(a.v[k], b.v[k])
        }
        return r
    }

    @inlinable
    public static func vmax(_ a: SIMDVector, _ b: SIMDVector) -> SIMDVector {
        var r = SIMDVector()
        for k in 0..<SIMDVector.SIZE {
            r.v[k] = max(a.v[k], b.v[k])
        }
        return r
    }
}
