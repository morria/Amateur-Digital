/*
 Mixed-radix decimation-in-time fast Fourier transform - ported from fft.hh
 Original Copyright 2018 Ahmet Inan <inan@aicodix.de>
 */

import Foundation

public final class FFT {
    public let size: Int
    public let sign: Int // +1 forward, -1 backward
    private let factors: [cmplx]
    private let plan: [Int] // sequence of radices for factorization

    public init(size: Int, sign: Int) {
        self.size = size
        self.sign = sign

        var twiddle = [cmplx](repeating: cmplx(), count: size)
        for n in 0..<size {
            let angle = Const.twoPi * Float(n) / Float(size)
            twiddle[n] = cmplx(Foundation.cos(angle), Float(sign) * Foundation.sin(angle))
        }
        self.factors = twiddle

        var plan = [Int]()
        var n = size
        while n > 1 {
            let r = FFT.split(n)
            plan.append(r)
            n /= r
        }
        self.plan = plan
    }

    static func split(_ n: Int) -> Int {
        if n % 31 == 0 { return 31 }
        if n % 29 == 0 { return 29 }
        if n % 23 == 0 { return 23 }
        if n % 19 == 0 { return 19 }
        if n % 17 == 0 { return 17 }
        if n % 13 == 0 { return 13 }
        if n % 11 == 0 { return 11 }
        if n % 7 == 0 { return 7 }
        if n % 5 == 0 { return 5 }
        if n % 3 == 0 { return 3 }
        if n % 8 == 0 && isPow8(n) { return 8 }
        if n % 8 == 0 && isPow8(n / 2) { return 2 }
        if n % 4 == 0 && isPow4(n) { return 4 }
        if n % 2 == 0 { return 2 }
        return 1
    }

    private static func isPow2(_ n: Int) -> Bool {
        n > 0 && (n & (n - 1)) == 0
    }

    private static func isPow4(_ n: Int) -> Bool {
        isPow2(n) && (n & 0x55555555) != 0
    }

    private static func isPow8(_ n: Int) -> Bool {
        isPow2(n) && (n & 0x49249249) != 0
    }

    public func transform(_ output: inout [cmplx], _ input: [cmplx]) {
        dit(&output, input, 0, size, 1, 0)
    }

    // Recursive decimation-in-time
    private func dit(_ output: inout [cmplx], _ input: [cmplx],
                     _ outOff: Int, _ bins: Int, _ stride: Int, _ planIdx: Int) {
        if bins == 1 {
            output[outOff] = input[0]
            return
        }

        let radix = plan[planIdx]
        let quotient = bins / radix

        // Recurse for each branch
        for r in 0..<radix {
            ditRecurse(&output, input, outOff + r * quotient, quotient,
                       stride * radix, planIdx + 1,
                       inputOffset: r * stride)
        }

        // Butterfly
        butterfly(&output, outOff, bins, radix, quotient, stride)
    }

    private func ditRecurse(_ output: inout [cmplx], _ input: [cmplx],
                            _ outOff: Int, _ bins: Int, _ stride: Int,
                            _ planIdx: Int, inputOffset: Int) {
        if bins == 1 {
            output[outOff] = input[inputOffset]
            return
        }

        let radix = plan[planIdx]
        let quotient = bins / radix

        for r in 0..<radix {
            ditRecurse(&output, input, outOff + r * quotient, quotient,
                       stride * radix, planIdx + 1,
                       inputOffset: inputOffset + r * stride)
        }

        butterfly(&output, outOff, bins, radix, quotient, stride)
    }

    private func butterfly(_ output: inout [cmplx], _ outOff: Int,
                           _ bins: Int, _ radix: Int, _ quotient: Int,
                           _ stride: Int) {
        // General DFT butterfly for arbitrary radix
        // Use Cooley-Tukey twiddle factor application
        var scratch = [cmplx](repeating: cmplx(), count: radix)

        for k in 0..<quotient {
            // Apply twiddle factors and gather
            for r in 0..<radix {
                let twiddleIdx = (r * k * stride) % size
                if r == 0 {
                    scratch[r] = output[outOff + r * quotient + k]
                } else {
                    scratch[r] = factors[twiddleIdx] * output[outOff + r * quotient + k]
                }
            }

            // DFT across radix points
            for r in 0..<radix {
                var sum = cmplx()
                for s in 0..<radix {
                    let angle = Const.twoPi * Float(r * s) / Float(radix)
                    let w = cmplx(Foundation.cos(angle), Float(sign) * Foundation.sin(angle))
                    sum += w * scratch[s]
                }
                output[outOff + r * quotient + k] = sum
            }
        }
    }
}
