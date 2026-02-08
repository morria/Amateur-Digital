/*
 Schmidl & Cox correlator - ported from schmidl_cox.hh
 Original Copyright 2021 Ahmet Inan <inan@aicodix.de>
 */

import Foundation

public final class SchmidlCox {
    private let symbolLen: Int
    private let guardLen: Int
    private let searchPos: Int
    private let matchLen: Int
    private let matchDel: Int

    private let fwd: FFT
    private let bwd: FFT
    private var cor: SMA4Complex
    private var pwr: SMA4<Float>
    private var match: SMA4<Float>
    private var align: Delay<Float>
    private var threshold: SchmittTrigger
    private var falling: FallingEdgeTrigger

    private var kern: [cmplx]
    private var tmp0: [cmplx]
    private var tmp1: [cmplx]

    private var timingMax: Float = 0
    private var phaseMax: Float = 0
    private var indexMax: Int = 0

    public var symbolPos: Int = 0
    public var cfoRad: Float = 0
    public var fracCfo: Float = 0

    public init(searchPosition: Int, symbolLength: Int, guardLength: Int,
                sequence: [cmplx]) {
        self.searchPos = searchPosition
        self.symbolLen = symbolLength
        self.guardLen = guardLength
        self.matchLen = guardLength | 1
        self.matchDel = (matchLen - 1) / 2

        fwd = FFT(size: symbolLength, sign: -1)
        bwd = FFT(size: symbolLength, sign: 1)
        cor = SMA4Complex(size: symbolLength, normalize: false)
        pwr = SMA4<Float>(size: 2 * symbolLength, normalize: false)
        match = SMA4<Float>(size: matchLen, normalize: false)
        align = Delay<Float>(size: matchDel, initial: 0)
        threshold = SchmittTrigger(low: 0.17 * Float(matchLen),
                                    high: 0.19 * Float(matchLen))
        falling = FallingEdgeTrigger()

        // Precompute kernel from correlation sequence
        kern = [cmplx](repeating: cmplx(), count: symbolLength)
        tmp0 = [cmplx](repeating: cmplx(), count: symbolLength)
        tmp1 = [cmplx](repeating: cmplx(), count: symbolLength)

        fwd.transform(&kern, sequence)
        for i in 0..<symbolLength {
            kern[i] = conj(kern[i]) / Float(symbolLength)
        }
    }

    private func bin(_ carrier: Int) -> Int {
        (carrier + symbolLen) % symbolLen
    }

    private func demodOrErase(_ curr: cmplx, _ prev: cmplx, _ pwr: Float) -> cmplx {
        if norm(curr) > pwr && norm(prev) > pwr {
            let cons = curr / prev
            if norm(cons) < 4 {
                return cons
            }
        }
        return cmplx()
    }

    /// Process one sample. Takes the raw BipBuffer array and read offset.
    /// Called once per sample to update running averages.
    /// Returns true when sync is detected.
    public func process(_ buf: [cmplx], offset: Int) -> Bool {
        let P = cor.process(
            buf[offset + searchPos + symbolLen] *
            conj(buf[offset + searchPos + 2 * symbolLen]))
        let R = 0.5 * pwr.process(
            norm(buf[offset + searchPos + 2 * symbolLen]))
        let minR = Float(0.00001) * Float(symbolLen)
        let safeR = max(R, minR)
        let timing = match.process(norm(P) / (safeR * safeR))
        let phase = align.process(arg(P))

        let collect = threshold.process(timing)
        let shouldProcess = falling.process(collect)

        if !collect && !shouldProcess {
            return false
        }

        if timingMax < timing {
            timingMax = timing
            phaseMax = phase
            indexMax = matchDel
        } else if indexMax < symbolLen + guardLen + matchDel {
            indexMax += 1
        }

        if !shouldProcess {
            return false
        }

        fracCfo = phaseMax / Float(symbolLen)

        var osc = Phasor()
        osc.omega(fracCfo)
        symbolPos = searchPos - indexMax
        indexMax = 0
        timingMax = 0

        for i in 0..<symbolLen {
            tmp1[i] = buf[offset + i + symbolPos + symbolLen] * osc.next()
        }
        fwd.transform(&tmp0, tmp1)

        var minPwr: Float = 0
        for i in 0..<symbolLen {
            minPwr += norm(tmp0[i])
        }
        minPwr /= Float(symbolLen)

        for i in 0..<symbolLen {
            tmp1[i] = demodOrErase(tmp0[i], tmp0[bin(i - 1)], minPwr)
        }
        fwd.transform(&tmp0, tmp1)

        for i in 0..<symbolLen {
            tmp0[i] *= kern[i]
        }
        bwd.transform(&tmp1, tmp0)

        var shift = 0
        var peak: Float = 0
        var next: Float = 0
        for i in 0..<symbolLen {
            let power = norm(tmp1[i])
            if power > peak {
                next = peak
                peak = power
                shift = i
            } else if power > next {
                next = power
            }
        }

        if peak <= next * 4 {
            return false
        }

        let posErr = Int(Foundation.nearbyint(arg(tmp1[shift]) * Float(symbolLen) / Const.twoPi))
        if Swift.abs(posErr) > guardLen / 2 {
            return false
        }
        symbolPos -= posErr

        cfoRad = Float(shift) * (Const.twoPi / Float(symbolLen)) - fracCfo
        if cfoRad >= Const.pi {
            cfoRad -= Const.twoPi
        }
        return true
    }
}
