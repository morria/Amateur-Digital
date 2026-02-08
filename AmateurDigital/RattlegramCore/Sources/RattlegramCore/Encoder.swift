/*
 OFDM Encoder - ported from encoder.hh
 Original Copyright 2022 Ahmet Inan <inan@aicodix.de>
 */

import Foundation

public final class Encoder {
    // Constants
    public let sampleRate: Int
    public let symbolLength: Int
    public let guardLength: Int
    public let extendedLength: Int

    private static let codeOrder = 11
    private static let modBits = 2
    private static let codeLen = 1 << codeOrder
    private static let symbolCount = 4
    private static let maxBits = 1360
    private static let corSeqLen = 127
    private static let corSeqOff = 1 - corSeqLen
    private static let corSeqPoly = 0b10001001
    private static let preSeqLen = 255
    private static let preSeqOff = -preSeqLen / 2
    private static let preSeqPoly = 0b100101011
    private static let payCarCnt = 256
    private static let payCarOff = -payCarCnt / 2
    private static let fancyOff = -(8 * 9 * 3) / 2
    private static let noisePoly = 0b100101010001

    private static let bchPolynomials = [
        0b100011101, 0b101110111, 0b111110011, 0b101101001,
        0b110111101, 0b111100111, 0b100101011, 0b111010111,
        0b000010011, 0b101100101, 0b110001011, 0b101100011,
        0b100011011, 0b100111111, 0b110001101, 0b100101101,
        0b101011111, 0b111111001, 0b111000011, 0b100111001,
        0b110101001, 0b000011111, 0b110000111, 0b110110001,
    ]

    private let bwd: FFT
    private var crc = CRC<UInt16>(poly: 0xA8F4)
    private let bch: BCHEncoder
    private var noiseSeq: MLS
    private var improvePapr: ImprovePAPR
    private let polar = PolarEncoderWrapper()

    private var temp: [cmplx]
    private var freq: [cmplx]
    private var prev: [cmplx]
    private var guardBuf: [cmplx]
    private var mesg: [UInt8]
    private var call: [UInt8]
    private var code: [Int8]

    private var metaData: UInt64 = 0
    private var operationMode: Int = 0
    private var carrierOffset: Int = 0
    private var symbolNumber: Int = 4 // symbolCount
    private var countDown: Int = 0
    private var fancyLine: Int = 0
    private var noiseCount: Int = 0

    public init(sampleRate: Int = 48000) {
        self.sampleRate = sampleRate
        self.symbolLength = (1280 * sampleRate) / 8000
        self.guardLength = symbolLength / 8
        self.extendedLength = symbolLength + guardLength

        bwd = FFT(size: symbolLength, sign: 1)
        bch = BCHEncoder(minimalPolynomials: Self.bchPolynomials)
        noiseSeq = MLS(poly: Self.noisePoly)
        let paprFactor = (32000 + sampleRate / 2) / sampleRate
        improvePapr = ImprovePAPR(size: symbolLength, oversamplingFactor: paprFactor)

        temp = [cmplx](repeating: cmplx(), count: extendedLength)
        freq = [cmplx](repeating: cmplx(), count: symbolLength)
        prev = [cmplx](repeating: cmplx(), count: Self.payCarCnt)
        guardBuf = [cmplx](repeating: cmplx(), count: guardLength)
        mesg = [UInt8](repeating: 0, count: Self.maxBits / 8)
        call = [UInt8](repeating: 0, count: 9)
        code = [Int8](repeating: 0, count: Self.codeLen)
    }

    private func bin(_ carrier: Int) -> Int {
        (carrier + carrierOffset + symbolLength) % symbolLength
    }

    // MARK: - Symbol generation

    private func schmidlCox() {
        var seq = MLS(poly: Self.corSeqPoly)
        let factor = Foundation.sqrt(Float(2 * symbolLength) / Float(Self.corSeqLen))
        for i in 0..<symbolLength { freq[i] = cmplx() }
        freq[bin(Self.corSeqOff - 2)] = cmplx(factor)
        for i in 0..<Self.corSeqLen {
            freq[bin(2 * i + Self.corSeqOff)] = cmplx(Float(nrz(seq.next() ? 1 : 0)))
        }
        for i in 0..<Self.corSeqLen {
            freq[bin(2 * i + Self.corSeqOff)] *= freq[bin(2 * (i - 1) + Self.corSeqOff)]
        }
        doTransform()
    }

    private func preamble() {
        var data = [UInt8](repeating: 0, count: 9)
        var parity = [UInt8](repeating: 0, count: 23)
        for i in 0..<55 {
            setBEBit(&data, i, (metaData >> i) & 1 != 0)
        }
        crc.reset()
        crc.update(uint64: metaData << 9)
        let cs = crc.value
        for i in 0..<16 {
            setBEBit(&data, i + 55, (cs >> i) & 1 != 0)
        }
        bch.encode(data, &parity)
        var seq = MLS(poly: Self.preSeqPoly)
        let factor = Foundation.sqrt(Float(symbolLength) / Float(Self.preSeqLen))
        for i in 0..<symbolLength { freq[i] = cmplx() }
        freq[bin(Self.preSeqOff - 1)] = cmplx(factor)
        for i in 0..<71 {
            freq[bin(i + Self.preSeqOff)] = cmplx(Float(nrz(getBEBit(data, i) ? 1 : 0)))
        }
        for i in 71..<Self.preSeqLen {
            freq[bin(i + Self.preSeqOff)] = cmplx(Float(nrz(getBEBit(parity, i - 71) ? 1 : 0)))
        }
        // Differential encoding
        for i in 0..<Self.preSeqLen {
            freq[bin(i + Self.preSeqOff)] *= freq[bin(i - 1 + Self.preSeqOff)]
        }
        // MLS scrambling
        for i in 0..<Self.preSeqLen {
            freq[bin(i + Self.preSeqOff)] *= cmplx(Float(nrz(seq.next() ? 1 : 0)))
        }
        // Save for differential payload demod
        for i in 0..<Self.payCarCnt {
            prev[i] = freq[bin(i + Self.payCarOff)]
        }
        doTransform()
    }

    private func fancySymbol() {
        var activeCarriers = 1
        for j in 0..<9 {
            for i in 0..<8 {
                activeCarriers += Int((Base37.bitmap[Int(call[j]) + 37 * fancyLine] >> i) & 1)
            }
        }
        let factor = Foundation.sqrt(Float(symbolLength) / Float(activeCarriers))
        for i in 0..<symbolLength { freq[i] = cmplx() }
        for j in 0..<9 {
            for i in 0..<8 {
                if Base37.bitmap[Int(call[j]) + 37 * fancyLine] & (1 << (7 - i)) != 0 {
                    freq[bin((8 * j + i) * 3 + Self.fancyOff)] =
                        cmplx(factor * Float(nrz(noiseSeq.next() ? 1 : 0)))
                }
            }
        }
        doTransform()
    }

    private func noiseSymbol() {
        let factor = Foundation.sqrt(Float(symbolLength) / Float(Self.payCarCnt))
        for i in 0..<symbolLength { freq[i] = cmplx() }
        for i in 0..<Self.payCarCnt {
            freq[bin(i + Self.payCarOff)] = cmplx(
                factor * Float(nrz(noiseSeq.next() ? 1 : 0)),
                factor * Float(nrz(noiseSeq.next() ? 1 : 0)))
        }
        doTransform()
    }

    private func payloadSymbol() {
        for i in 0..<symbolLength { freq[i] = cmplx() }
        for i in 0..<Self.payCarCnt {
            let offset = Self.modBits * (Self.payCarCnt * symbolNumber + i)
            let mapped = QPSK.map(code[offset], code[offset + 1])
            prev[i] *= mapped
            freq[bin(i + Self.payCarOff)] = prev[i]
        }
        doTransform()
    }

    private func silence() {
        for i in 0..<symbolLength { temp[i] = cmplx() }
    }

    private func doTransform() {
        improvePapr.improve(&freq)
        bwd.transform(&temp, freq)
        let norm = Foundation.sqrt(Float(8 * symbolLength))
        for i in 0..<symbolLength {
            temp[i] /= norm
        }
    }

    private func nextSample(_ signal: cmplx, channel: Int) -> Int16 {
        let v = Foundation.nearbyint(32767 * signal.real)
        return Int16(clamping: Int(min(max(v, -32768), 32767)))
    }

    // MARK: - Public API

    /// Configure the encoder with payload and callsign
    public func configure(payload: [UInt8], callSign: String,
                          carrierFrequency: Int = 1500,
                          noiseSymbols: Int = 0, fancyHeader: Bool = false) {
        var len = 0
        while len < payload.count && len <= 128 && payload[len] != 0 {
            len += 1
        }
        if len == 0 {
            operationMode = 0
        } else if len <= 85 {
            operationMode = 16
        } else if len <= 128 {
            operationMode = 15
        } else {
            operationMode = 14
        }

        carrierOffset = (carrierFrequency * symbolLength) / sampleRate
        metaData = (Base37.encode(callSign) << 8) | UInt64(operationMode)

        for i in 0..<9 { call[i] = 0 }
        for (i, c) in callSign.prefix(9).enumerated() {
            call[i] = Base37.map(c)
        }

        symbolNumber = 0
        countDown = 5
        fancyLine = fancyHeader ? 11 : 0
        noiseCount = noiseSymbols

        for i in 0..<guardLength { guardBuf[i] = cmplx() }

        guard operationMode != 0 else { return }

        let frozenBits: [UInt32]
        let dataBits: Int
        switch operationMode {
        case 14: dataBits = 1360; frozenBits = frozen_2048_1392
        case 15: dataBits = 1024; frozenBits = frozen_2048_1056
        case 16: dataBits = 680;  frozenBits = frozen_2048_712
        default: return
        }

        var scrambler = Xorshift32()
        for i in 0..<(dataBits / 8) {
            mesg[i] = payload[i] ^ UInt8(truncatingIfNeeded: scrambler.next())
        }
        polar.encode(&code, mesg, frozenBits, dataBits)
    }

    /// Produce one symbol of audio. Returns false when done.
    public func produce(_ audioBuffer: inout [Int16], channelSelect: Int = 0) -> Bool {
        var dataSymbol = false

        switch countDown {
        case 5:
            if noiseCount > 0 {
                noiseCount -= 1
                noiseSymbol()
            } else {
                countDown -= 1
                schmidlCox()
                dataSymbol = true
                countDown -= 1
            }
        case 4:
            schmidlCox()
            dataSymbol = true
            countDown -= 1
        case 3:
            preamble()
            dataSymbol = true
            countDown -= 1
            if operationMode == 0 { countDown -= 1 }
        case 2:
            payloadSymbol()
            dataSymbol = true
            symbolNumber += 1
            if symbolNumber == Self.symbolCount { countDown -= 1 }
        case 1:
            if fancyLine > 0 {
                fancyLine -= 1
                fancySymbol()
            } else {
                silence()
                countDown -= 1
            }
        default:
            for i in 0..<extendedLength {
                writeOutputSample(&audioBuffer, cmplx(), channelSelect, i)
            }
            return false
        }

        // Guard interval with windowed overlap
        for i in 0..<guardLength {
            var x = Float(i) / Float(guardLength - 1)
            let ratio: Float = 0.5
            if dataSymbol {
                x = min(x, ratio) / ratio
            }
            let y = 0.5 * (1 - Foundation.cos(Const.pi * x))
            let sum = lerp(guardBuf[i].real, temp[i + symbolLength - guardLength].real, y)
            let sumI = lerp(guardBuf[i].imag, temp[i + symbolLength - guardLength].imag, y)
            writeOutputSample(&audioBuffer, cmplx(sum, sumI), channelSelect, i)
        }

        // Save guard for next overlap
        for i in 0..<guardLength {
            guardBuf[i] = temp[i]
        }

        // Main symbol body
        for i in 0..<symbolLength {
            writeOutputSample(&audioBuffer, temp[i], channelSelect, i + guardLength)
        }
        return true
    }

    private func writeOutputSample(_ samples: inout [Int16], _ signal: cmplx,
                                    _ channel: Int, _ i: Int) {
        let clamp16 = { (v: Float) -> Int16 in
            Int16(clamping: Int(Foundation.nearbyint(min(max(32767 * v, -32768), 32767))))
        }
        switch channel {
        case 1:
            samples[2 * i] = clamp16(signal.real)
            samples[2 * i + 1] = 0
        case 2:
            samples[2 * i] = 0
            samples[2 * i + 1] = clamp16(signal.real)
        case 4:
            samples[2 * i] = clamp16(signal.real)
            samples[2 * i + 1] = clamp16(signal.imag)
        default:
            samples[i] = clamp16(signal.real)
        }
    }
}
