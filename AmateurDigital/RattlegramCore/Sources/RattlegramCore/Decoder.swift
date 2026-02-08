/*
 OFDM Decoder - ported from decoder.hh
 Original Copyright 2022 Ahmet Inan <inan@aicodix.de>
 */

import Foundation

public enum DecoderStatus: Int {
    case okay = 0
    case fail = 1
    case sync = 2
    case done = 3
    case heap = 4
    case nope = 5
    case ping = 6
}

public final class Decoder {
    // Constants
    public let sampleRate: Int
    public let symbolLength: Int
    public let guardLength: Int
    public let extendedLength: Int

    private static let codeOrder = 11
    private static let modBits = 2
    private static let codeLen = 1 << codeOrder
    private static let symbolCount = 4
    private static let corSeqLen = 127
    private static let corSeqOff = 1 - corSeqLen
    private static let corSeqPoly = 0b10001001
    private static let preSeqLen = 255
    private static let preSeqOff = -preSeqLen / 2
    private static let preSeqPoly = 0b100101011
    private static let payCarCnt = 256
    private static let payCarOff = -payCarCnt / 2

    private static let bchPolynomials = [
        0b100011101, 0b101110111, 0b111110011, 0b101101001,
        0b110111101, 0b111100111, 0b100101011, 0b111010111,
        0b000010011, 0b101100101, 0b110001011, 0b101100011,
        0b100011011, 0b100111111, 0b110001101, 0b100101101,
        0b101011111, 0b111111001, 0b111000011, 0b100111001,
        0b110101001, 0b000011111, 0b110000111, 0b110110001,
    ]

    private let fwd: FFT
    private let correlator: SchmidlCox
    private var blockDc = BlockDC()
    private var hilbertFilter: Hilbert
    private var buffer: BipBuffer
    private var tse: TheilSenEstimator
    private var osc = Phasor()
    private var crc = CRC<UInt16>(poly: 0xA8F4)
    private let osd: OrderedStatisticsDecoder
    private let polar = PolarDecoderWrapper()

    private var temp: [cmplx]
    private var freq: [cmplx]
    private var prev: [cmplx]
    private var cons: [cmplx]
    private var code: [Int8]
    private var generator: [Int8]
    private var soft: [Int8]
    private var data: [UInt8]
    private var indexBuf: [Float]
    private var phaseBuf: [Float]

    private var symbolNumber: Int
    private var symbolPosition: Int = 0
    private var storedPosition: Int = 0
    private var stagedPosition: Int = 0
    private var stagedMode: Int = 0
    private var operationMode: Int = 0
    private var accumulated: Int = 0
    private var storedCfoRad: Float = 0
    private var stagedCfoRad: Float = 0
    private var stagedCall: UInt64 = 0
    private var storedCheck: Bool = false
    private var stagedCheck: Bool = false
    private var buf: [cmplx] = []  // captured buffer snapshot for process()
    private let bufferLength: Int
    private let searchPosition: Int
    private let filterLength: Int

    public init(sampleRate: Int = 48000) {
        self.sampleRate = sampleRate
        self.symbolLength = (1280 * sampleRate) / 8000
        self.guardLength = symbolLength / 8
        self.extendedLength = symbolLength + guardLength
        self.bufferLength = 4 * extendedLength
        self.searchPosition = extendedLength
        self.filterLength = (((33 * sampleRate) / 8000) & ~3) | 1
        self.symbolNumber = Self.symbolCount

        fwd = FFT(size: symbolLength, sign: -1)

        // Build correlation sequence for SchmidlCox
        var corSeq = [cmplx](repeating: cmplx(), count: symbolLength / 2)
        var seq = MLS(poly: Self.corSeqPoly)
        for i in 0..<Self.corSeqLen {
            let idx = (i + Self.corSeqOff / 2 + symbolLength / 2) % (symbolLength / 2)
            corSeq[idx] = cmplx(Float(nrz(seq.next() ? 1 : 0)))
        }

        correlator = SchmidlCox(
            searchPosition: searchPosition,
            symbolLength: symbolLength / 2,
            guardLength: guardLength,
            sequence: corSeq)

        hilbertFilter = Hilbert(taps: filterLength)
        buffer = BipBuffer(size: bufferLength)
        tse = TheilSenEstimator(maxLen: Self.payCarCnt)
        osd = OrderedStatisticsDecoder()

        temp = [cmplx](repeating: cmplx(), count: extendedLength)
        freq = [cmplx](repeating: cmplx(), count: symbolLength)
        prev = [cmplx](repeating: cmplx(), count: Self.payCarCnt)
        cons = [cmplx](repeating: cmplx(), count: Self.payCarCnt)
        code = [Int8](repeating: 0, count: Self.codeLen)
        generator = [Int8](repeating: 0, count: 255 * 71)
        soft = [Int8](repeating: 0, count: Self.preSeqLen)
        data = [UInt8](repeating: 0, count: (Self.preSeqLen + 7) / 8)
        indexBuf = [Float](repeating: 0, count: Self.payCarCnt)
        phaseBuf = [Float](repeating: 0, count: Self.payCarCnt)

        // Build BCH generator matrix
        BCHGenerator.matrix(&generator, systematic: true,
                            minimalPolynomials: Self.bchPolynomials)

        blockDc.samples(filterLength)
        osc.omega(-2000, sampleRate)
    }

    private static func bin(_ carrier: Int, _ symbolLength: Int) -> Int {
        (carrier + symbolLength) % symbolLength
    }

    private func bin(_ carrier: Int) -> Int {
        Self.bin(carrier, symbolLength)
    }

    private func analytic(_ real: Float) -> cmplx {
        hilbertFilter.process(blockDc.process(real))
    }

    private func demodOrErase(_ curr: cmplx, _ prev: cmplx) -> cmplx {
        if norm(prev) <= 0 { return cmplx() }
        let cons = curr / prev
        if norm(cons) > 4 { return cmplx() }
        return cons
    }

    // MARK: - Public API

    /// Feed audio samples. Returns true when a full buffer is ready for processing.
    public func feed(_ audioBuffer: [Int16], sampleCount: Int, channelSelect: Int = 0) -> Bool {
        for i in 0..<sampleCount {
            let sample: cmplx
            switch channelSelect {
            case 1: sample = analytic(Float(audioBuffer[2 * i]) / 32768.0)
            case 2: sample = analytic(Float(audioBuffer[2 * i + 1]) / 32768.0)
            case 3: sample = analytic(Float(Int(audioBuffer[2 * i]) + Int(audioBuffer[2 * i + 1])) / 65536.0)
            case 4: sample = cmplx(Float(audioBuffer[2 * i]) / 32768.0,
                                   Float(audioBuffer[2 * i + 1]) / 32768.0)
            default: sample = analytic(Float(audioBuffer[i]) / 32768.0)
            }

            // Write sample and run correlator on every sample (matching C++)
            let readOff = buffer.write(sample)
            if correlator.process(buffer.rawBuffer, offset: readOff) {
                storedCfoRad = correlator.cfoRad
                storedPosition = correlator.symbolPos + accumulated
                storedCheck = true
            }

            accumulated += 1
            if accumulated == extendedLength {
                buf = Array(buffer.read())
            }
        }

        if accumulated >= extendedLength {
            accumulated -= extendedLength
            if storedCheck {
                stagedCfoRad = storedCfoRad
                stagedPosition = storedPosition
                stagedCheck = true
                storedCheck = false
            }
            return true
        }
        return false
    }

    /// Process a decoded buffer. Returns decoder status.
    public func process() -> DecoderStatus {
        var status = DecoderStatus.okay

        if stagedCheck {
            stagedCheck = false
            let preambleResult = decodePreamble(buf)
            if preambleResult == .okay {
                operationMode = stagedMode
                osc.omega(-stagedCfoRad)
                symbolPosition = stagedPosition
                symbolNumber = -1
                status = .sync
            } else {
                status = preambleResult
            }
        }

        if symbolNumber < Self.symbolCount {
            // CFO correction + FFT
            var oscCopy = osc
            for i in 0..<extendedLength {
                let idx = symbolPosition + i
                if idx >= 0 && idx < buf.count {
                    temp[i] = buf[idx] * oscCopy.next()
                } else {
                    temp[i] = cmplx()
                    oscCopy.next()
                }
            }
            osc = oscCopy
            fwd.transform(&freq, Array(temp[0..<symbolLength]))

            if symbolNumber >= 0 {
                // Differential demodulation
                for i in 0..<Self.payCarCnt {
                    cons[i] = demodOrErase(freq[bin(i + Self.payCarOff)], prev[i])
                }
                compensate()
                demap()
            }

            symbolNumber += 1
            if symbolNumber == Self.symbolCount {
                status = .done
            }

            // Save current carriers for differential demod
            for i in 0..<Self.payCarCnt {
                prev[i] = freq[bin(i + Self.payCarOff)]
            }
        }

        return status
    }

    /// Get staged sync info
    public func staged() -> (cfo: Float, mode: Int, callSign: String) {
        let cfo = stagedCfoRad * (Float(sampleRate) / Const.twoPi)
        let callStr = Base37.decode(stagedCall, length: 9)
        return (cfo, stagedMode, callStr)
    }

    /// Fetch decoded payload after STATUS_DONE
    public func fetch(_ payload: inout [UInt8]) -> Int {
        let frozenBits: [UInt32]
        let dataBits: Int
        switch operationMode {
        case 14: dataBits = 1360; frozenBits = frozen_2048_1392
        case 15: dataBits = 1024; frozenBits = frozen_2048_1056
        case 16: dataBits = 680;  frozenBits = frozen_2048_712
        default: return -1
        }

        let result = polar.decode(&payload, code, frozenBits, dataBits)

        var scrambler = Xorshift32()
        for i in 0..<(dataBits / 8) {
            payload[i] ^= UInt8(truncatingIfNeeded: scrambler.next())
        }
        for i in (dataBits / 8)..<170 {
            payload[i] = 0
        }
        return result
    }

    // MARK: - Private

    private func decodePreamble(_ buf: [cmplx]) -> DecoderStatus {
        var nco = Phasor()
        nco.omega(-stagedCfoRad)
        var fftIn = [cmplx](repeating: cmplx(), count: symbolLength)
        for i in 0..<symbolLength {
            let idx = stagedPosition + i
            if idx >= 0 && idx < buf.count {
                fftIn[i] = buf[idx] * nco.next()
            } else {
                nco.next()
            }
        }
        fwd.transform(&freq, fftIn)

        // MLS despreading
        var seq = MLS(poly: Self.preSeqPoly)
        for i in 0..<Self.preSeqLen {
            freq[bin(i + Self.preSeqOff)] *= cmplx(Float(nrz(seq.next() ? 1 : 0)))
        }

        // Differential demodulation + soft decisions
        for i in 0..<Self.preSeqLen {
            let cons = demodOrErase(freq[bin(i + Self.preSeqOff)],
                                     freq[bin(i - 1 + Self.preSeqOff)])
            soft[i] = BPSK.soft(cons, precision: 32)
        }

        // OSD decode
        if !osd.decode(&data, soft, generator) {
            return .fail
        }

        // Extract metadata
        var md: UInt64 = 0
        for i in 0..<55 {
            if getBEBit(data, i) {
                md |= UInt64(1) << i
            }
        }
        var cs: UInt16 = 0
        for i in 0..<16 {
            if getBEBit(data, i + 55) {
                cs |= UInt16(1) << i
            }
        }

        // CRC check
        crc.reset()
        crc.update(uint64: md << 9)
        if crc.value != cs {
            return .fail
        }

        stagedMode = Int(md & 255)
        stagedCall = md >> 8

        if stagedMode != 0 && (stagedMode < 14 || stagedMode > 16) {
            return .nope
        }
        if stagedCall == 0 || stagedCall >= 129961739795077 {
            stagedCall = 0
            return .nope
        }
        if stagedMode == 0 {
            return .ping
        }
        return .okay
    }

    private func compensate() {
        var count = 0
        for i in 0..<Self.payCarCnt {
            let con = cons[i]
            if con.real != 0 && con.imag != 0 {
                let h = QPSK.hard(con)
                let mapped = QPSK.map(h.0, h.1)
                indexBuf[count] = Float(i + Self.payCarOff)
                phaseBuf[count] = arg(con * conj(mapped))
                count += 1
            }
        }
        tse.compute(indexBuf, phaseBuf, count)
        for i in 0..<Self.payCarCnt {
            cons[i] *= RattlegramCore.polar(1 as Float, -tse.evaluate(Float(i + Self.payCarOff)))
        }
    }

    private func precision() -> Float {
        var sp: Float = 0
        var np: Float = 0
        for i in 0..<Self.payCarCnt {
            let h = QPSK.hard(cons[i])
            let hard = QPSK.map(h.0, h.1)
            let error = cons[i] - hard
            sp += norm(hard)
            np += norm(error)
        }
        return np > 0 ? sp / np : 1
    }

    private func demap() {
        let pre = precision()
        for i in 0..<Self.payCarCnt {
            let offset = Self.modBits * (symbolNumber * Self.payCarCnt + i)
            QPSK.soft(&code, offset: offset, cons[i], precision: pre)
        }
    }
}
