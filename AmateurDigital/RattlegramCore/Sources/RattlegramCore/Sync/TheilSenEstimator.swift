/*
 Theil-Sen estimator - ported from theil_sen.hh
 Original Copyright 2021 Ahmet Inan <inan@aicodix.de>
 */

public struct TheilSenEstimator {
    private let maxLen: Int
    private var temp: [Float]
    private var xint: Float = 0
    private var yint: Float = 0
    private var slope_: Float = 0

    public init(maxLen: Int) {
        self.maxLen = maxLen
        let size = ((maxLen - 1) * maxLen) / 2
        self.temp = [Float](repeating: 0, count: size)
    }

    public mutating func compute(_ x: [Float], _ y: [Float], _ len: Int) {
        let maxSize = temp.count
        var count = 0
        for i in 0..<len {
            for j in (i + 1)..<len {
                guard count < maxSize else { break }
                if x[j] != x[i] {
                    temp[count] = (y[j] - y[i]) / (x[j] - x[i])
                    count += 1
                }
            }
            guard count < maxSize else { break }
        }
        slope_ = quickSelect(&temp, count / 2, count)
        count = 0
        for i in 0..<len {
            guard count < maxSize else { break }
            temp[count] = y[i] - slope_ * x[i]
            count += 1
        }
        yint = quickSelect(&temp, count / 2, count)
        if slope_ != 0 {
            xint = -yint / slope_
        }
    }

    public func evaluate(_ x: Float) -> Float {
        yint + slope_ * x
    }

    public var slope: Float { slope_ }
    public var xIntercept: Float { xint }
    public var yIntercept: Float { yint }

    // MARK: - Quick select (median finding)

    private func quickSelect(_ a: inout [Float], _ k: Int, _ n: Int) -> Float {
        guard n > 0 else { return 0 }
        var lo = 0, hi = n - 1
        while lo < hi {
            if hi - lo < 32 {
                insertionSort(&a, lo, hi)
                break
            }
            var lt = lo, gt = hi
            partition(&a, &lt, &gt)
            if k < lt {
                hi = lt - 1
            } else if k > gt {
                lo = gt + 1
            } else {
                break
            }
        }
        return a[k]
    }

    private func insertionSort(_ a: inout [Float], _ l: Int, _ h: Int) {
        for i in (l + 1)...h {
            let t = a[i]
            var j = i
            while j > l && t < a[j - 1] {
                a[j] = a[j - 1]
                j -= 1
            }
            a[j] = t
        }
    }

    private func partition(_ a: inout [Float], _ l: inout Int, _ h: inout Int) {
        let mid = l + (h - l) / 2
        let pivot = a[mid]
        var i = l
        while i <= h {
            if a[i] < pivot {
                a.swapAt(i, l)
                i += 1; l += 1
            } else if a[i] > pivot {
                a.swapAt(i, h)
                h -= 1
            } else {
                i += 1
            }
        }
    }
}
