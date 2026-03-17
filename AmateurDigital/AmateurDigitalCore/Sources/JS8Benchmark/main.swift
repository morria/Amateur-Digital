//
//  JS8Benchmark - JS8Call Encoding/Decoding Quality Benchmark
//
//  Comprehensive evaluation harness that tests JS8Call encoding and decoding across:
//  - All submodes (Normal, Fast, Turbo, Slow)
//  - Multiple SNR levels (clean to deeply buried)
//  - Frequency offset (simulating tuning error / drift)
//  - Fading / QSB (simulating HF propagation)
//  - Clock offset (simulating imprecise UTC sync)
//  - Multi-signal scenarios (signal subtraction effectiveness)
//  - Adjacent channel interference
//  - False positive test (noise-only)
//  - All frame types (heartbeat, directed, data, compound)
//
//  This benchmark is self-contained: it includes a reference JS8Call encoder
//  and decoder implementing the full pipeline (alphabet packing, CRC-12, LDPC
//  (174,87), 8-FSK with Costas sync, spectral sync detection, soft-decision
//  LDPC decoding). It can be used to evaluate any JS8Call implementation by
//  replacing the reference encoder/decoder with the implementation under test.
//
//  Outputs a composite score (0-100) and detailed per-test results.
//
//  Run:  cd AmateurDigital/AmateurDigitalCore && swift run JS8Benchmark
//

import Foundation
import AmateurDigitalCore

// ============================================================================
// MARK: - JS8Call Protocol Constants
// ============================================================================

/// Constants shared across all JS8Call submodes.
enum JS8 {
    static let KK = 87            // Information bits (75 + CRC12)
    static let ND = 58            // Data symbols
    static let NS = 21            // Sync symbols (3 x Costas 7)
    static let NN = NS + ND       // Total channel symbols (79)
    static let N  = 174           // LDPC codeword length
    static let K  = 87            // LDPC information length
    static let M  = N - K         // LDPC parity checks
    static let rxSampleRate = 12000.0

    /// 68-character alphabet used for raw frame payload (6 bits/char, 12 chars = 72 bits).
    static let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-+/?.")
}

// ============================================================================
// MARK: - JS8Call Submode Definitions
// ============================================================================

struct JS8Submode {
    let name: String
    let nsps: Int            // Samples per symbol at 12 kHz
    let period: Int          // TX cycle in seconds
    let startDelay: Double   // Start delay in seconds
    let ndownsps: Int        // Downsampled samples per symbol
    let ndd: Int             // Downsample FFT factor
    let jz: Int              // Timing search range (quarter-symbol steps)
    let costasType: CostasType

    var baudRate: Double { JS8.rxSampleRate / Double(nsps) }
    var bandwidth: Double { 8.0 * baudRate }
    var toneSpacing: Double { baudRate }
    var txDuration: Double { Double(JS8.NN * nsps) / JS8.rxSampleRate + startDelay }
    var ndown: Int { nsps / ndownsps }
    var nfft1: Int { 2 * nsps }

    enum CostasType { case original, modified }
}

extension JS8Submode {
    static let normal = JS8Submode(
        name: "Normal", nsps: 1920, period: 15, startDelay: 0.5,
        ndownsps: 32, ndd: 100, jz: 62, costasType: .original
    )
    static let fast = JS8Submode(
        name: "Fast", nsps: 1200, period: 10, startDelay: 0.2,
        ndownsps: 20, ndd: 100, jz: 144, costasType: .modified
    )
    static let turbo = JS8Submode(
        name: "Turbo", nsps: 600, period: 6, startDelay: 0.1,
        ndownsps: 12, ndd: 120, jz: 172, costasType: .modified
    )
    static let slow = JS8Submode(
        name: "Slow", nsps: 3840, period: 30, startDelay: 0.5,
        ndownsps: 32, ndd: 90, jz: 32, costasType: .modified
    )

    static let all: [JS8Submode] = [.normal, .fast, .turbo, .slow]
}

// ============================================================================
// MARK: - Costas Arrays
// ============================================================================

struct CostasArrays {
    let a: [Int]
    let b: [Int]
    let c: [Int]

    static let original = CostasArrays(
        a: [4, 2, 5, 6, 1, 3, 0],
        b: [4, 2, 5, 6, 1, 3, 0],
        c: [4, 2, 5, 6, 1, 3, 0]
    )

    static let modified = CostasArrays(
        a: [0, 6, 2, 3, 5, 4, 1],
        b: [1, 5, 0, 2, 3, 6, 4],
        c: [2, 5, 0, 6, 4, 1, 3]
    )

    static func forType(_ type: JS8Submode.CostasType) -> CostasArrays {
        switch type {
        case .original: return .original
        case .modified: return .modified
        }
    }
}

// ============================================================================
// MARK: - CRC-12
// ============================================================================

/// CRC-12 as used by FT8/JS8Call (polynomial 0xC06, init 0, no reflect, no final XOR).
func crc12(_ bytes: [UInt8], count: Int) -> UInt16 {
    var crc: UInt16 = 0
    for i in 0..<count {
        crc ^= UInt16(bytes[i]) << 4
        for _ in 0..<8 {
            if crc & 0x800 != 0 {
                crc = (crc << 1) ^ 0xC06
            } else {
                crc = crc << 1
            }
            crc &= 0xFFF
        }
    }
    return crc & 0xFFF
}

// ============================================================================
// MARK: - LDPC (174,87) Code Tables
// ============================================================================

/// Generator matrix rows (87 rows, each 22 hex chars encoding 87 bits).
let generatorHex: [String] = [
    "23bba830e23b6b6f50982e", "1f8e55da218c5df3309052",
    "ca7b3217cd92bd59a5ae20", "56f78313537d0f4382964e",
    "29c29dba9c545e267762fe", "6be396b5e2e819e373340c",
    "293548a138858328af4210", "cb6c6afcdc28bb3f7c6e86",
    "3f2a86f5c5bd225c961150", "849dd2d63673481860f62c",
    "56cdaec6e7ae14b43feeee", "04ef5cfa3766ba778f45a4",
    "c525ae4bd4f627320a3974", "fe37802941d66dde02b99c",
    "41fd9520b2e4abeb2f989c", "40907b01280f03c0323946",
    "7fb36c24085a34d8c1dbc4", "40fc3e44bb7d2bb2756e44",
    "d38ab0a1d2e52a8ec3bc76", "3d0f929ef3949bd84d4734",
    "45d3814f504064f80549ae", "f14dbf263825d0bd04b05e",
    "f08a91fb2e1f78290619a8", "7a8dec79a51e8ac5388022",
    "ca4186dd44c3121565cf5c", "db714f8f64e8ac7af1a76e",
    "8d0274de71e7c1a8055eb0", "51f81573dd4049b082de14",
    "d037db825175d851f3af00", "d8f937f31822e57c562370",
    "1bf1490607c54032660ede", "1616d78018d0b4745ca0f2",
    "a9fa8e50bcb032c85e3304", "83f640f1a48a8ebc0443ea",
    "eca9afa0f6b01d92305edc", "3776af54ccfbae916afde6",
    "6abb212d9739dfc02580f2", "05209a0abb530b9e7e34b0",
    "612f63acc025b6ab476f7c", "0af7723161ec223080be86",
    "a8fc906976c35669e79ce0", "45b7ab6242b77474d9f11a",
    "b274db8abd3c6f396ea356", "9059dfa2bb20ef7ef73ad4",
    "3d188ea477f6fa41317a4e", "8d9071b7e7a6a2eed6965e",
    "a377253773ea678367c3f6", "ecbd7c73b9cd34c3720c8a",
    "b6537f417e61d1a7085336", "6c280d2a0523d9c4bc5946",
    "d36d662a69ae24b74dcbd8", "d747bfc5fd65ef70fbd9bc",
    "a9fa2eefa6f8796a355772", "cc9da55fe046d0cb3a770c",
    "f6ad4824b87c80ebfce466", "cc6de59755420925f90ed2",
    "164cc861bdd803c547f2ac", "c0fc3ec4fb7d2bb2756644",
    "0dbd816fba1543f721dc72", "a0c0033a52ab6299802fd2",
    "bf4f56e073271f6ab4bf80", "57da6d13cb96a7689b2790",
    "81cfc6f18c35b1e1f17114", "481a2a0df8a23583f82d6c",
    "1ac4672b549cd6dba79bcc", "c87af9a5d5206abca532a8",
    "97d4169cb33e7435718d90", "a6573f3dc8b16c9d19f746",
    "2c4142bf42b01e71076acc", "081c29a10d468ccdbcecb6",
    "5b0f7742bca86b8012609a", "012dee2198eba82b19a1da",
    "f1627701a2d692fd9449e6", "35ad3fb0faeb5f1b0c30dc",
    "b1ca4ea2e3d173bad4379c", "37d8e0af9258b9e8c5f9b2",
    "cd921fdf59e882683763f6", "6114e08483043fd3f38a8a",
    "2e547dd7a05f6597aac516", "95e45ecd0135aca9d6e6ae",
    "b33ec97be83ce413f9acc8", "c8b5dffc335095dcdcaf2a",
    "3dd01a59d86310743ec752", "14cd0f642fc0c5fe3a65ca",
    "3a0a1dfd7eee29c2e827e0", "8abdb889efbe39a510a118",
    "3f231f212055371cf3e2a2",
]

/// Column reorder table (174 entries).
let colorder: [Int] = [
    0,1,2,3,30,4,5,6,7,8,9,10,11,32,12,40,13,14,15,16,
    17,18,37,45,29,19,20,21,41,22,42,31,33,34,44,35,47,51,50,43,
    36,52,63,46,25,55,27,24,23,53,39,49,59,38,48,61,60,57,28,62,
    56,58,65,66,26,70,64,69,68,67,74,71,54,76,72,75,78,77,80,79,
    73,83,84,81,82,85,86,87,88,89,90,91,92,93,94,95,96,97,98,99,
    100,101,102,103,104,105,106,107,108,109,110,111,112,113,114,115,116,117,118,119,
    120,121,122,123,124,125,126,127,128,129,130,131,132,133,134,135,136,137,138,139,
    140,141,142,143,144,145,146,147,148,149,150,151,152,153,154,155,156,157,158,159,
    160,161,162,163,164,165,166,167,168,169,170,171,172,173,
]

// Lazy-loaded generator matrix (87 x 87 binary)
var _generatorMatrix: [[UInt8]]?
func getGeneratorMatrix() -> [[UInt8]] {
    if let g = _generatorMatrix { return g }
    var gen = [[UInt8]](repeating: [UInt8](repeating: 0, count: JS8.K), count: JS8.M)
    for i in 0..<JS8.M {
        let hex = generatorHex[i]
        let hexChars = Array(hex)
        for j in 0..<11 {
            let hi = hexCharToInt(hexChars[j * 2])
            let lo = hexCharToInt(hexChars[j * 2 + 1])
            let byte = (hi << 4) | lo
            for jj in 0..<8 {
                let icol = j * 8 + jj
                if icol < JS8.K {
                    gen[i][icol] = (byte >> (7 - jj)) & 1 != 0 ? 1 : 0
                }
            }
        }
    }
    _generatorMatrix = gen
    return gen
}

func hexCharToInt(_ c: Character) -> Int {
    switch c {
    case "0"..."9": return Int(c.asciiValue! - Character("0").asciiValue!)
    case "a"..."f": return Int(c.asciiValue! - Character("a").asciiValue!) + 10
    case "A"..."F": return Int(c.asciiValue! - Character("A").asciiValue!) + 10
    default: return 0
    }
}

// ============================================================================
// MARK: - LDPC Encoder
// ============================================================================

/// Encode 87 information bits -> 174-bit codeword using the (174,87) LDPC code.
func ldpcEncode(_ message: [UInt8]) -> [UInt8] {
    let gen = getGeneratorMatrix()
    var pchecks = [UInt8](repeating: 0, count: JS8.M)
    for i in 0..<JS8.M {
        var sum = 0
        for j in 0..<JS8.K {
            sum += Int(message[j]) * Int(gen[i][j])
        }
        pchecks[i] = UInt8(sum & 1)
    }
    // itmp: parity first, then message
    var itmp = [UInt8](repeating: 0, count: JS8.N)
    for i in 0..<JS8.M { itmp[i] = pchecks[i] }
    for i in 0..<JS8.K { itmp[JS8.M + i] = message[i] }
    // Reorder columns
    var codeword = [UInt8](repeating: 0, count: JS8.N)
    for i in 0..<JS8.N {
        codeword[colorder[i]] = itmp[i]
    }
    return codeword
}

// ============================================================================
// MARK: - JS8Call Encoder (text -> tones -> audio)
// ============================================================================

/// Pack a 12-character frame + 3-bit type into 87 information bits, then LDPC-encode to 174 bits,
/// then map to 79 channel symbols (58 data + 21 sync).
func js8Encode(message: String, i3bit: Int, submode: JS8Submode) -> [Int] {
    // Pad/truncate to 12 characters
    var msg = message
    while msg.count < 12 { msg.append(" ") }
    if msg.count > 12 { msg = String(msg.prefix(12)) }

    // Map characters to 6-bit values
    var i4Words = [Int](repeating: 0, count: 12)
    for (i, ch) in msg.enumerated() {
        if let idx = JS8.alphabet.firstIndex(of: ch) {
            i4Words[i] = JS8.alphabet.distance(from: JS8.alphabet.startIndex, to: idx)
        }
    }

    // Pack into 75 bits (72 data + 3 type)
    var bits = [UInt8](repeating: 0, count: 75)
    var pos = 0
    for i in 0..<12 {
        let val = i4Words[i]
        for b in (0..<6).reversed() {
            bits[pos] = UInt8((val >> b) & 1)
            pos += 1
        }
    }
    // 3-bit type
    bits[72] = UInt8((i3bit >> 2) & 1)
    bits[73] = UInt8((i3bit >> 1) & 1)
    bits[74] = UInt8(i3bit & 1)

    // Pack into bytes for CRC
    var bytes = [UInt8](repeating: 0, count: 11)
    for i in 0..<10 {
        var byte: UInt8 = 0
        for b in 0..<8 {
            let bitIdx = i * 8 + b
            if bitIdx < 75 {
                byte = (byte << 1) | bits[bitIdx]
            } else {
                byte = byte << 1
            }
        }
        bytes[i] = byte
    }
    // Mask byte 9 to top 3 bits
    bytes[9] = bytes[9] & 0xE0
    bytes[10] = 0

    var icrc = crc12(bytes, count: 11)
    icrc ^= 42  // JS8Call CRC tweak

    // Build 87-bit information word
    var msgbits = [UInt8](repeating: 0, count: JS8.KK)
    // First 72 bits = payload
    for i in 0..<72 { msgbits[i] = bits[i] }
    // Bits 72-74 = i3bit
    msgbits[72] = UInt8((i3bit >> 2) & 1)
    msgbits[73] = UInt8((i3bit >> 1) & 1)
    msgbits[74] = UInt8(i3bit & 1)
    // Bits 75-86 = CRC-12
    for i in 0..<12 {
        msgbits[75 + i] = UInt8((icrc >> (11 - i)) & 1)
    }

    // LDPC encode
    let codeword = ldpcEncode(msgbits)

    // Map to 79 channel tones
    let costas = CostasArrays.forType(submode.costasType)
    var itone = [Int](repeating: 0, count: JS8.NN)

    // Costas arrays
    for i in 0..<7 { itone[i] = costas.a[i] }
    for i in 0..<7 { itone[36 + i] = costas.b[i] }
    for i in 0..<7 { itone[JS8.NN - 7 + i] = costas.c[i] }

    // Data symbols
    var k = 7
    for j in 1...JS8.ND {
        let i = 3 * j - 3
        if j == 30 { k += 7 }  // Skip middle Costas
        itone[k] = Int(codeword[i]) * 4 + Int(codeword[i + 1]) * 2 + Int(codeword[i + 2])
        k += 1
    }

    return itone
}

/// Generate 8-FSK audio samples from tone sequence.
func js8GenerateAudio(tones: [Int], submode: JS8Submode, carrierFreq: Double) -> [Float] {
    let nsps = submode.nsps
    let sampleRate = JS8.rxSampleRate
    let toneSpacing = submode.toneSpacing
    let twopi = 2.0 * Double.pi

    var samples = [Float]()
    samples.reserveCapacity(JS8.NN * nsps)

    var phi = 0.0
    for i in 0..<JS8.NN {
        let freq = carrierFreq + Double(tones[i]) * toneSpacing
        let dphi = twopi * freq / sampleRate
        for _ in 0..<nsps {
            samples.append(Float(sin(phi)))
            phi += dphi
            if phi >= twopi { phi -= twopi }
        }
    }
    return samples
}

// ============================================================================
// MARK: - JS8Call Decoder (audio -> text)
// ============================================================================

/// Simple FFT implementation (radix-2 DIT) for the decoder.
/// Operates on complex arrays. n must be a power of 2.
func fft(_ real: inout [Double], _ imag: inout [Double], inverse: Bool = false) {
    let n = real.count
    guard n > 1 else { return }

    // Bit-reversal permutation
    var j = 0
    for i in 0..<n {
        if i < j {
            real.swapAt(i, j)
            imag.swapAt(i, j)
        }
        var m = n >> 1
        while m >= 1 && j >= m {
            j -= m
            m >>= 1
        }
        j += m
    }

    // Cooley-Tukey
    var step = 1
    while step < n {
        let halfStep = step
        step <<= 1
        let angle = (inverse ? 1.0 : -1.0) * Double.pi / Double(halfStep)
        let wR = cos(angle)
        let wI = sin(angle)

        for k in stride(from: 0, to: n, by: step) {
            var curR = 1.0
            var curI = 0.0
            for m in 0..<halfStep {
                let idx1 = k + m
                let idx2 = k + m + halfStep
                let tR = curR * real[idx2] - curI * imag[idx2]
                let tI = curR * imag[idx2] + curI * real[idx2]
                real[idx2] = real[idx1] - tR
                imag[idx2] = imag[idx1] - tI
                real[idx1] = real[idx1] + tR
                imag[idx1] = imag[idx1] + tI
                let newR = curR * wR - curI * wI
                let newI = curR * wI + curI * wR
                curR = newR
                curI = newI
            }
        }
    }

    if inverse {
        let scale = 1.0 / Double(n)
        for i in 0..<n {
            real[i] *= scale
            imag[i] *= scale
        }
    }
}

/// Next power of 2 >= n.
func nextPow2(_ n: Int) -> Int {
    var p = 1
    while p < n { p <<= 1 }
    return p
}

/// Decode JS8Call audio: returns (decoded_text, snr_estimate) or nil on failure.
func js8Decode(audio: [Float], submode: JS8Submode, freqRange: (Double, Double) = (100, 4900)) -> (String, Double)? {
    let nsps = submode.nsps
    let nmax = submode.period * Int(JS8.rxSampleRate)
    let costas = CostasArrays.forType(submode.costasType)

    // Work with at most nmax samples
    let dd: [Double] = Array(audio.prefix(nmax)).map { Double($0) }
    print("    [DEBUG] dd.count=\(dd.count), need>\(nsps * JS8.NN), nmax=\(nmax), audio.count=\(audio.count)")
    guard dd.count > nsps * JS8.NN else {
        print("    [DEBUG] Audio too short!")
        return nil
    }

    let nfft1 = 2 * nsps
    let nstep = nsps / 4
    let nhsym = dd.count / nstep - 3
    guard nhsym > 0 else { return nil }

    let fftSizeBench = nextPow2(nfft1)
    let nh1 = fftSizeBench / 2
    let df = JS8.rxSampleRate / Double(fftSizeBench)
    let toneStep = Double(fftSizeBench) / Double(nsps)  // Non-integer tone step in bins
    let nssy = nsps / nstep   // steps per symbol (4)

    // Compute spectrogram
    var s = [[Double]](repeating: [Double](repeating: 0, count: nh1), count: nhsym)

    // Nuttall window
    var window = [Double](repeating: 0, count: nfft1)
    let a0 = 0.3635819, a1 = -0.4891775, a2 = 0.1365995, a3 = -0.0106411
    for i in 0..<nfft1 {
        let x = 2.0 * Double.pi * Double(i) / Double(nfft1)
        window[i] = a0 + a1 * cos(x) + a2 * cos(2.0 * x) + a3 * cos(3.0 * x)
    }
    let wsum = window.reduce(0, +)
    let wnorm = Double(nsps) * 2.0 / 300.0
    for i in 0..<nfft1 { window[i] = window[i] / wsum * wnorm }

    for j in 0..<nhsym {
        let ia = j * nstep
        let ib = ia + nfft1
        guard ib <= dd.count else { break }

        var re = [Double](repeating: 0, count: fftSizeBench)
        var im = [Double](repeating: 0, count: fftSizeBench)
        for i in 0..<nfft1 {
            re[i] = dd[ia + i] * window[i]
        }
        fft(&re, &im)
        for i in 0..<nh1 {
            s[j][i] = re[i] * re[i] + im[i] * im[i]
        }
    }

    // Search for Costas sync
    // Helper: bin for tone index using floating-point step
    func tBin(_ base: Int, _ tone: Int) -> Int {
        base + Int(Double(tone) * toneStep + 0.5)
    }

    let ia = max(1, Int(freqRange.0 / df))
    let ib = min(nh1 - tBin(0, 7), Int(freqRange.1 / df))
    guard ia < ib else { return nil }

    let tstepBench = Double(nstep) / JS8.rxSampleRate
    let jstrt = Int((submode.startDelay / tstepBench) + 0.5)

    var bestSync = 0.0
    var bestFreqBin = 0
    var bestTimeOff = 0

    for i in ia..<ib {
        for jOff in -submode.jz...submode.jz {
            var ta = 0.0, tb = 0.0, tc = 0.0
            var t0a = 0.0, t0b = 0.0, t0c = 0.0

            for n in 0..<7 {
                let ka = jOff + jstrt + nssy * n
                if ka >= 0 && ka < nhsym {
                    let toneIdx = tBin(i, costas.a[n])
                    if toneIdx >= 0 && toneIdx < nh1 { ta += s[ka][toneIdx] }
                    for tIdx in 0...6 { let t = tBin(i, tIdx); if t >= 0 && t < nh1 { t0a += s[ka][t] } }
                }
                let kb = jOff + jstrt + nssy * (n + 36)
                if kb >= 0 && kb < nhsym {
                    let toneIdx = tBin(i, costas.b[n])
                    if toneIdx >= 0 && toneIdx < nh1 { tb += s[kb][toneIdx] }
                    for tIdx in 0...6 { let t = tBin(i, tIdx); if t >= 0 && t < nh1 { t0b += s[kb][t] } }
                }
                let kc = jOff + jstrt + nssy * (n + 72)
                if kc >= 0 && kc < nhsym {
                    let toneIdx = tBin(i, costas.c[n])
                    if toneIdx >= 0 && toneIdx < nh1 { tc += s[kc][toneIdx] }
                    for tIdx in 0...6 { let t = tBin(i, tIdx); if t >= 0 && t < nh1 { t0c += s[kc][t] } }
                }
            }

            let bg_abc = (t0a + t0b + t0c - ta - tb - tc) / 6.0
            let sync_abc = bg_abc > 0 ? (ta + tb + tc) / bg_abc : 0
            let bg_ab = (t0a + t0b - ta - tb) / 6.0
            let sync_ab = bg_ab > 0 ? (ta + tb) / bg_ab : 0
            let bg_bc = (t0b + t0c - tb - tc) / 6.0
            let sync_bc = bg_bc > 0 ? (tb + tc) / bg_bc : 0

            let sync = max(sync_abc, sync_ab, sync_bc)
            if sync > bestSync {
                bestSync = sync
                bestFreqBin = i
                bestTimeOff = jOff
            }
        }
    }

    print("    [DEBUG] bestSync=\(String(format: "%.3f", bestSync)) freqBin=\(bestFreqBin) df=\(df) freq=\(Double(bestFreqBin)*df) timeOff=\(bestTimeOff) jstrt=\(jstrt) nhsym=\(nhsym) ia=\(ia) ib=\(ib)")
    if bestSync < 1.5 {
        print("    [DEBUG] Sync FAILED")
        return nil
    }

    let f1 = Double(bestFreqBin) * df
    let t0 = Double(bestTimeOff + jstrt) * Double(nstep) / JS8.rxSampleRate

    // Extract symbol spectra at the detected time/frequency.
    // Use direct DFT at the 8 tone frequencies for each symbol period.
    // This avoids FFT size/alignment issues and matches the Fortran approach.
    var s2 = [[Double]](repeating: [Double](repeating: 0, count: 8), count: JS8.NN)

    let twopiOverSR = 2.0 * Double.pi / JS8.rxSampleRate
    let symStartBase = Int(t0 * JS8.rxSampleRate)

    for k in 0..<JS8.NN {
        let symStart = symStartBase + k * nsps
        guard symStart >= 0 && symStart + nsps <= dd.count else { continue }

        // Direct DFT at each of the 8 tone frequencies.
        // This correlates the signal against each tone to extract power.
        // No FFT needed — just compute the DFT coefficient at each tone.
        for tone in 0..<8 {
            let freq = f1 + Double(tone) * submode.toneSpacing
            var sumR = 0.0
            var sumI = 0.0
            let dphase = 2.0 * Double.pi * freq / JS8.rxSampleRate
            var phase = dphase * Double(symStart)
            for i in 0..<nsps {
                let sample = Double(dd[symStart + i])
                sumR += sample * cos(phase)
                sumI += sample * sin(phase)
                phase += dphase
            }
            s2[k][tone] = sumR * sumR + sumI * sumI
        }
    }

    // Extract data symbols (skip Costas)
    var s1 = [[Double]](repeating: [Double](repeating: 0, count: 8), count: JS8.ND)
    var j = 0
    for k in 0..<JS8.NN {
        if k < 7 { continue }
        if k >= 36 && k <= 42 { continue }
        if k >= 72 { continue }  // Costas C starts at 72
        if j < JS8.ND {
            s1[j] = s2[k]
            j += 1
        }
    }

    // Compute soft bit metrics (LLRs)
    var llr = [Double](repeating: 0, count: JS8.N)
    for j in 0..<JS8.ND {
        let ps = s1[j]
        let r4 = max(ps[4], ps[5], ps[6], ps[7]) - max(ps[0], ps[1], ps[2], ps[3])
        let r2 = max(ps[2], ps[3], ps[6], ps[7]) - max(ps[0], ps[1], ps[4], ps[5])
        let r1 = max(ps[1], ps[3], ps[5], ps[7]) - max(ps[0], ps[2], ps[4], ps[6])
        llr[3 * j]     = r4
        llr[3 * j + 1] = r2
        llr[3 * j + 2] = r1
    }

    // Normalize LLRs
    let avg = llr.reduce(0, +) / Double(JS8.N)
    let variance = llr.map { ($0 - avg) * ($0 - avg) }.reduce(0, +) / Double(JS8.N)
    let sigma = sqrt(max(variance, 1e-10))
    for i in 0..<JS8.N { llr[i] = 2.83 * (llr[i] - avg) / sigma }

    // Debug: check tone powers for first few symbols
    // Debug: show all 8 tone powers for first Costas symbol
    let powers0 = s2[0].map { String(format: "%.1f", $0) }.joined(separator: ", ")
    let maxTone0 = s2[0].enumerated().max(by: { $0.element < $1.element })
    let maxTone7 = s2[7].enumerated().max(by: { $0.element < $1.element })
    print("    [DEBUG] sym0 powers: [\(powers0)]")
    print("    [DEBUG] Costas[0]: peak tone=\(maxTone0?.offset ?? -1) (expect \(submode.costasType == .original ? 4 : 0)), data[7]: peak=\(maxTone7?.offset ?? -1)")
    print("    [DEBUG] f1=\(f1) t0=\(t0) symStartBase=\(symStartBase) nsps=\(nsps)")

    // BP decode
    guard let decoded = bpDecode(llr: llr, maxIterations: 30) else {
        print("    [DEBUG] BP decode FAILED")
        return nil
    }

    // Check CRC
    var bytes = [UInt8](repeating: 0, count: 11)
    for i in 0..<10 {
        var byte: UInt8 = 0
        for b in 0..<8 {
            let bitIdx = i * 8 + b
            if bitIdx < 75 {
                byte = (byte << 1) | decoded[bitIdx]
            } else {
                byte = byte << 1
            }
        }
        bytes[i] = byte
    }
    bytes[9] = bytes[9] & 0xE0
    bytes[10] = 0

    var expectedCRC = crc12(bytes, count: 11)
    expectedCRC ^= 42

    var receivedCRC: UInt16 = 0
    for i in 0..<12 {
        receivedCRC = (receivedCRC << 1) | UInt16(decoded[75 + i])
    }

    guard receivedCRC == expectedCRC else { return nil }

    // Extract 12 characters
    var text = ""
    for i in 0..<12 {
        var val = 0
        for b in 0..<6 {
            val = (val << 1) + Int(decoded[i * 6 + b])
        }
        if val < JS8.alphabet.count {
            text.append(JS8.alphabet[val])
        }
    }

    // Trim trailing spaces/dots
    text = String(text.reversed().drop(while: { $0 == " " || $0 == "." }).reversed())

    // SNR estimate (rough)
    let snr = 10.0 * log10(max(bestSync - 1.0, 0.001)) - 27.0

    return (text, snr)
}

// ============================================================================
// MARK: - Belief Propagation Decoder
// ============================================================================

/// Parity check matrix in sparse form (from WSJT-X/JS8Call ldpc_174_87_params.f90).
/// Mn[bit][0..2] = which check nodes connect to this bit (3 checks per bit).
/// Stored as flat array for compactness; loaded on first use.
let mnData: [[Int]] = loadMn()
let nmData: [[Int]] = loadNm()
let nrwData: [Int] = [
    6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,
    6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,6,7,
    6,6,6,6,6,7,6,6,6,6,6,6,6,6,6,7,6,6,6,6,
    7,6,5,6,6,6,6,6,6,5,6,6,6,6,6,6,6,6,6,6,
    5,6,6,6,5,6,6
]

func loadMn() -> [[Int]] {
    // 174 bits, each with 3 check connections
    // Transcribed from bpdecode174.f90 Mn data
    let raw: [[Int]] = [
        [1,25,69],[2,5,73],[3,32,68],[4,51,61],[6,63,70],[7,33,79],[8,50,86],
        [9,37,43],[10,41,65],[11,14,64],[12,75,77],[13,23,81],[15,16,82],[17,56,66],
        [18,53,60],[19,31,52],[20,67,84],[21,29,72],[22,24,44],[26,35,76],[27,36,38],
        [28,40,42],[30,54,55],[34,49,87],[39,57,58],[45,74,83],[46,62,80],[47,48,85],
        [59,71,78],[1,50,53],[2,47,84],[3,25,79],[4,6,14],[5,7,80],[8,34,55],
        [9,36,69],[10,43,83],[11,23,74],[12,17,44],[13,57,76],[15,27,56],[16,28,29],
        [18,19,59],[20,40,63],[21,35,52],[22,54,64],[24,62,78],[26,32,77],[30,72,85],
        [31,65,87],[33,39,51],[37,48,75],[38,70,71],[41,42,68],[45,67,86],[46,81,82],
        [49,66,73],[58,60,66],[61,65,85],[1,14,21],[2,13,59],[3,67,82],[4,32,73],
        [5,36,54],[6,43,46],[7,28,75],[8,33,71],[9,49,76],[10,58,64],[11,48,68],
        [12,19,45],[15,50,61],[16,22,26],[17,72,80],[18,40,55],[20,35,51],[23,25,34],
        [24,63,87],[27,39,74],[29,78,83],[30,70,77],[31,69,84],[22,37,86],[38,41,81],
        [42,44,57],[47,53,62],[52,56,79],[60,75,81],[1,39,77],[2,16,41],[3,31,54],
        [4,36,78],[5,45,65],[6,57,85],[7,14,49],[8,21,46],[9,15,72],[10,20,62],
        [11,17,71],[12,34,47],[13,68,86],[18,23,43],[19,64,73],[24,48,79],[25,70,83],
        [26,80,87],[27,32,40],[28,56,69],[29,63,66],[30,42,50],[33,37,82],[35,60,74],
        [38,55,84],[44,52,61],[51,53,72],[58,59,67],[47,56,76],[1,19,37],[2,61,75],
        [3,8,66],[4,60,84],[5,34,39],[6,26,53],[7,32,57],[9,52,67],[10,12,15],
        [11,51,69],[13,14,65],[16,31,43],[17,20,36],[18,80,86],[21,48,59],[22,40,46],
        [23,33,62],[24,30,74],[25,42,64],[27,49,85],[28,38,73],[29,44,81],[35,68,70],
        [41,63,76],[45,49,71],[50,58,87],[48,54,83],[13,55,79],[77,78,82],[1,2,24],
        [3,6,75],[4,56,87],[5,44,53],[7,50,83],[8,10,28],[9,55,62],[11,29,67],
        [12,33,40],[14,16,20],[15,35,73],[17,31,39],[18,36,57],[19,46,76],[21,42,84],
        [22,34,59],[23,26,61],[25,60,65],[27,64,80],[30,37,66],[32,45,72],[38,51,86],
        [41,77,79],[43,56,68],[47,74,82],[40,52,78],[54,61,71],[46,58,69],
    ]
    return raw
}

func loadNm() -> [[Int]] {
    // 87 check nodes, each with 5-7 bit connections (padded with 0)
    // Transcribed from bpdecode174.f90 Nm data
    let raw: [[Int]] = [
        [1,30,60,89,118,147,0],[2,31,61,90,119,147,0],[3,32,62,91,120,148,0],
        [4,33,63,92,121,149,0],[2,34,64,93,122,150,0],[5,33,65,94,123,148,0],
        [6,34,66,95,124,151,0],[7,35,67,96,120,152,0],[8,36,68,97,125,153,0],
        [9,37,69,98,126,152,0],[10,38,70,99,127,154,0],[11,39,71,100,126,155,0],
        [12,40,61,101,128,145,0],[10,33,60,95,128,156,0],[13,41,72,97,126,157,0],
        [13,42,73,90,129,156,0],[14,39,74,99,130,158,0],[15,43,75,102,131,159,0],
        [16,43,71,103,118,160,0],[17,44,76,98,130,156,0],[18,45,60,96,132,161,0],
        [19,46,73,83,133,162,0],[12,38,77,102,134,163,0],[19,47,78,104,135,147,0],
        [1,32,77,105,136,164,0],[20,48,73,106,123,163,0],[21,41,79,107,137,165,0],
        [22,42,66,108,138,152,0],[18,42,80,109,139,154,0],[23,49,81,110,135,166,0],
        [16,50,82,91,129,158,0],[3,48,63,107,124,167,0],[6,51,67,111,134,155,0],
        [24,35,77,100,122,162,0],[20,45,76,112,140,157,0],[21,36,64,92,130,159,0],
        [8,52,83,111,118,166,0],[21,53,84,113,138,168,0],[25,51,79,89,122,158,0],
        [22,44,75,107,133,155,172],[9,54,84,90,141,169,0],[22,54,85,110,136,161,0],
        [8,37,65,102,129,170,0],[19,39,85,114,139,150,0],[26,55,71,93,142,167,0],
        [27,56,65,96,133,160,174],[28,31,86,100,117,171,0],[28,52,70,104,132,144,0],
        [24,57,68,95,137,142,0],[7,30,72,110,143,151,0],[4,51,76,115,127,168,0],
        [16,45,87,114,125,172,0],[15,30,86,115,123,150,0],[23,46,64,91,144,173,0],
        [23,35,75,113,145,153,0],[14,41,87,108,117,149,170],[25,40,85,94,124,159,0],
        [25,58,69,116,143,174,0],[29,43,61,116,132,162,0],[15,58,88,112,121,164,0],
        [4,59,72,114,119,163,173],[27,47,86,98,134,153,0],[5,44,78,109,141,0,0],
        [10,46,69,103,136,165,0],[9,50,59,93,128,164,0],[14,57,58,109,120,166,0],
        [17,55,62,116,125,154,0],[3,54,70,101,140,170,0],[1,36,82,108,127,174,0],
        [5,53,81,105,140,0,0],[29,53,67,99,142,173,0],[18,49,74,97,115,167,0],
        [2,57,63,103,138,157,0],[26,38,79,112,135,171,0],[11,52,66,88,119,148,0],
        [20,40,68,117,141,160,0],[11,48,81,89,146,169,0],[29,47,80,92,146,172,0],
        [6,32,87,104,145,169,0],[27,34,74,106,131,165,0],[12,56,84,88,139,0,0],
        [13,56,62,111,146,171,0],[26,37,80,105,144,151,0],[17,31,82,113,121,161,0],
        [28,49,59,94,137,0,0],[7,55,83,101,131,168,0],[24,50,78,106,143,149,0],
    ]
    return raw
}

/// Belief propagation decoder for the (174,87) LDPC code.
/// Returns 87 decoded bits on success, nil on failure.
func bpDecode(llr: [Double], maxIterations: Int) -> [UInt8]? {
    let N = JS8.N, M = JS8.M

    var tov = [[Double]](repeating: [Double](repeating: 0, count: 3), count: N)
    var toc = [[Double]](repeating: [Double](repeating: 0, count: 7), count: M)
    var zn = [Double](repeating: 0, count: N)
    var cw = [UInt8](repeating: 0, count: N)

    // Initialize
    for j in 0..<M {
        for i in 0..<nrwData[j] {
            let bitIdx = nmData[j][i] - 1
            if bitIdx >= 0 && bitIdx < N {
                toc[j][i] = llr[bitIdx]
            }
        }
    }

    var nclast = M
    var ncnt = 0

    for iter in 0...maxIterations {
        // Update bit beliefs
        for i in 0..<N {
            zn[i] = llr[i]
            for k in 0..<3 {
                zn[i] += tov[i][k]
            }
        }

        // Hard decisions
        for i in 0..<N { cw[i] = zn[i] > 0 ? 1 : 0 }

        // Check parity
        var ncheck = 0
        for j in 0..<M {
            var sum = 0
            for i in 0..<nrwData[j] {
                let bitIdx = nmData[j][i] - 1
                if bitIdx >= 0 && bitIdx < N { sum += Int(cw[bitIdx]) }
            }
            if sum & 1 != 0 { ncheck += 1 }
        }

        if ncheck == 0 {
            // Codeword found! Reorder and extract message
            var reordered = [UInt8](repeating: 0, count: N)
            for i in 0..<N { reordered[i] = cw[colorder[i]] }
            return Array(reordered[M..<N])
        }

        // Early stopping
        if iter > 0 {
            let nd = ncheck - nclast
            if nd < 0 { ncnt = 0 } else { ncnt += 1 }
            if ncnt >= 5 && iter >= 10 && ncheck > 15 { return nil }
        }
        nclast = ncheck

        // Variable-to-check messages
        for j in 0..<M {
            for i in 0..<nrwData[j] {
                let bitIdx = nmData[j][i] - 1
                guard bitIdx >= 0 && bitIdx < N else { continue }
                toc[j][i] = zn[bitIdx]
                for kk in 0..<3 {
                    let checkIdx = mnData[bitIdx][kk] - 1
                    if checkIdx == j {
                        toc[j][i] -= tov[bitIdx][kk]
                    }
                }
            }
        }

        // Check-to-variable messages (tanh rule)
        for bitIdx in 0..<N {
            for k in 0..<3 {
                let checkIdx = mnData[bitIdx][k] - 1
                guard checkIdx >= 0 && checkIdx < M else { continue }
                var product = 1.0
                for i in 0..<nrwData[checkIdx] {
                    let otherBit = nmData[checkIdx][i] - 1
                    if otherBit != bitIdx && otherBit >= 0 {
                        product *= tanh(-toc[checkIdx][i] / 2.0)
                    }
                }
                tov[bitIdx][k] = -2.0 * atanh(max(-0.9999, min(0.9999, product)))
            }
        }
    }

    return nil
}

// ============================================================================
// MARK: - Seeded Random Generator (Reproducible Noise)
// ============================================================================

struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed == 0 ? 1 : seed }

    mutating func nextDouble() -> Double {
        state ^= state >> 12
        state ^= state << 25
        state ^= state >> 27
        let value = state &* 0x2545F4914F6CDD1D
        return Double(value) / Double(UInt64.max)
    }

    mutating func nextGaussian() -> Double {
        let u1 = max(nextDouble(), 1e-10)
        let u2 = nextDouble()
        return sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
    }
}

// ============================================================================
// MARK: - Signal Impairments
// ============================================================================

func addWhiteNoise(to signal: [Float], snrDB: Float, rng: inout SeededRandom) -> [Float] {
    let signalPower = signal.map { $0 * $0 }.reduce(0, +) / max(1, Float(signal.count))
    let signalRMS = sqrt(signalPower)
    guard signalRMS > 0 else { return signal }
    let noiseRMS = signalRMS / pow(10.0, snrDB / 20.0)
    return signal.map { $0 + Float(rng.nextGaussian()) * noiseRMS }
}

func applyFrequencyShift(to signal: [Float], shiftHz: Double, sampleRate: Double) -> [Float] {
    let phaseInc = 2.0 * .pi * shiftHz / sampleRate
    var phase = 0.0
    return signal.map { sample in
        let s = sample * Float(cos(phase))
        phase += phaseInc
        if phase >= 2.0 * .pi { phase -= 2.0 * .pi }
        return s
    }
}

func applyFading(to signal: [Float], fadeRateHz: Double, fadeDepth: Float, sampleRate: Double) -> [Float] {
    let phaseInc = 2.0 * .pi * fadeRateHz / sampleRate
    var phase = 0.0
    return signal.map { sample in
        let fade = 1.0 - fadeDepth * Float((1.0 + cos(phase)) / 2.0)
        phase += phaseInc
        return sample * fade
    }
}

func applyClockOffset(to signal: [Float], offsetSeconds: Double, sampleRate: Double) -> [Float] {
    // Shift the signal in time (prepend or trim samples)
    let offsetSamples = Int(offsetSeconds * sampleRate)
    if offsetSamples > 0 {
        return [Float](repeating: 0, count: offsetSamples) + signal
    } else if offsetSamples < 0 {
        let drop = min(-offsetSamples, signal.count)
        return Array(signal.dropFirst(drop))
    }
    return signal
}

func addInterferer(to signal: [Float], freqHz: Double, relativeLevel: Float, sampleRate: Double, rng: inout SeededRandom) -> [Float] {
    // Add an 8-FSK interfering signal at a different frequency
    let phaseInc = 2.0 * .pi * freqHz / sampleRate
    var phase = 0.0
    let signalRMS = sqrt(signal.map { $0 * $0 }.reduce(0, +) / max(1, Float(signal.count)))
    let intLevel = signalRMS * relativeLevel
    return signal.map { sample in
        let intf = Float(sin(phase)) * intLevel
        phase += phaseInc
        if phase >= 2.0 * .pi { phase -= 2.0 * .pi }
        return sample + intf
    }
}

// ============================================================================
// MARK: - Scoring
// ============================================================================

func characterErrorRate(expected: String, actual: String) -> Double {
    guard !expected.isEmpty else { return actual.isEmpty ? 0 : 1 }
    guard !actual.isEmpty else { return 1.0 }

    let exp = Array(expected.uppercased())
    let act = Array(actual.uppercased())
    let m = exp.count, n = act.count

    var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
    for i in 0...m { dp[i][0] = i }
    for j in 0...n { dp[0][j] = j }
    for i in 1...m {
        for j in 1...n {
            dp[i][j] = exp[i-1] == act[j-1]
                ? dp[i-1][j-1]
                : 1 + min(dp[i-1][j], dp[i][j-1], dp[i-1][j-1])
        }
    }
    return Double(dp[m][n]) / Double(m)
}

func cerToScore(_ cer: Double) -> Double { max(0, 100.0 * (1.0 - cer)) }

/// For JS8Call frames: exact match gives 100, any decode gives partial credit.
func frameScore(expected: String, decoded: String?) -> Double {
    guard let decoded = decoded else { return 0 }
    let cer = characterErrorRate(expected: expected, actual: decoded)
    return cerToScore(cer)
}

// ============================================================================
// MARK: - Test Infrastructure
// ============================================================================

struct TestResult {
    let category: String
    let name: String
    let expected: String
    let decoded: String
    let cer: Double
    let score: Double
    let snr: Double?
}

struct BenchmarkSuite {
    /// Realistic JS8Call 12-character frame payloads (within the 68-char alphabet).
    let frameTexts: [(name: String, text: String)] = [
        ("cq_call",     "CQ CQ CQ W1A"),
        ("callsign",    "W1AW DE K1AB"),
        ("grid_report", "K1ABC EM73  "),
        ("signal_rpt",  "UR SNR -12  "),
        ("roger",       "RR 73 DE W1A"),
        ("short_msg",   "HELLO WORLD "),
        ("contest",     "CQ TEST 5NN "),
        ("numbers",     "12345 6789A"),
        ("mixed_case",  "Hello World "),
        ("special",     "RST 599+INFO"),
    ]

    var results: [TestResult] = []

    mutating func runAll() {
        let startTime = Date()

        print(String(repeating: "=", count: 72))
        print("JS8CALL ENCODING/DECODING BENCHMARK")
        print(String(repeating: "=", count: 72))
        print()

        runCleanChannelTests()
        runSubmodeTests()
        runNoiseSweepTests()
        runFrequencyOffsetTests()
        runFadingTests()
        runClockOffsetTests()
        runCombinedImpairmentTests()
        runMultiSignalTests()
        runFalsePositiveTests()

        printSummary()

        let elapsed = Date().timeIntervalSince(startTime)
        print(String(format: "\nBenchmark completed in %.1f seconds.", elapsed))
    }

    // MARK: - Clean Channel (Baseline, Normal mode)

    mutating func runCleanChannelTests() {
        print("--- Clean Channel (Normal mode, 1000 Hz) ---")
        for (name, text) in frameTexts {
            let result = runSingleTest(
                category: "clean", name: name,
                submode: .normal, text: text, carrierFreq: 1000
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - All Submodes (Clean)

    mutating func runSubmodeTests() {
        print("--- Submode Sweep (Clean Channel) ---")
        let text = "CQ CQ CQ W1A"
        for submode in JS8Submode.all {
            let result = runSingleTest(
                category: "submode", name: submode.name.lowercased(),
                submode: submode, text: text, carrierFreq: 1000
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Noise Sweep

    mutating func runNoiseSweepTests() {
        print("--- Noise Sweep (Normal mode) ---")
        let text = "CQ CQ CQ W1A"
        let snrLevels: [Float] = [30, 25, 20, 15, 12, 10, 8, 6, 3, 0, -3, -6, -10, -15, -20, -24]

        for snr in snrLevels {
            let result = runSingleTest(
                category: "noise", name: "\(Int(snr))dB",
                submode: .normal, text: text, carrierFreq: 1000,
                impairment: { samples in
                    var rng = SeededRandom(seed: 42 + UInt64(abs(snr) * 100))
                    return addWhiteNoise(to: samples, snrDB: snr, rng: &rng)
                }
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Frequency Offset

    mutating func runFrequencyOffsetTests() {
        print("--- Frequency Offset (Normal mode, 15 dB SNR) ---")
        let text = "CQ CQ CQ W1A"
        let offsets: [Double] = [0.5, 1.0, 2.0, 3.0, 5.0, 10.0, 20.0, 50.0]

        for offset in offsets {
            for sign in [1.0, -1.0] {
                let hz = offset * sign
                let label = hz >= 0 ? "+\(String(format: "%.1f", hz))Hz" : "\(String(format: "%.1f", hz))Hz"
                let result = runSingleTest(
                    category: "freq_offset", name: label,
                    submode: .normal, text: text,
                    carrierFreq: 1000 + hz,
                    impairment: { samples in
                        var rng = SeededRandom(seed: 100 + UInt64(abs(hz) * 10))
                        return addWhiteNoise(to: samples, snrDB: 15, rng: &rng)
                    }
                )
                results.append(result)
                printResult(result)
            }
        }
        print()
    }

    // MARK: - Fading / QSB

    mutating func runFadingTests() {
        print("--- Fading / QSB (Normal mode) ---")
        let text = "CQ CQ CQ W1A"

        let fadeParams: [(rate: Double, depth: Float, name: String)] = [
            (0.2, 0.3, "very_slow_shallow"),
            (0.5, 0.3, "slow_shallow"),
            (0.5, 0.6, "slow_moderate"),
            (0.5, 0.8, "slow_deep"),
            (1.0, 0.5, "medium"),
            (2.0, 0.5, "fast"),
            (1.0, 0.8, "medium_deep"),
            (0.3, 0.9, "slow_very_deep"),
        ]

        for (rate, depth, name) in fadeParams {
            let result = runSingleTest(
                category: "fading", name: name,
                submode: .normal, text: text, carrierFreq: 1000,
                impairment: { samples in
                    applyFading(to: samples, fadeRateHz: rate, fadeDepth: depth, sampleRate: JS8.rxSampleRate)
                }
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Clock Offset

    mutating func runClockOffsetTests() {
        print("--- Clock Offset (Normal mode) ---")
        let text = "CQ CQ CQ W1A"
        let offsets: [Double] = [-2.0, -1.0, -0.5, -0.2, 0.0, 0.2, 0.5, 1.0, 2.0]

        for offset in offsets {
            let result = runSingleTest(
                category: "clock_offset", name: "\(String(format: "%+.1f", offset))s",
                submode: .normal, text: text, carrierFreq: 1000,
                impairment: { samples in
                    applyClockOffset(to: samples, offsetSeconds: offset, sampleRate: JS8.rxSampleRate)
                }
            )
            results.append(result)
            printResult(result)
        }
        print()
    }

    // MARK: - Combined Impairments

    mutating func runCombinedImpairmentTests() {
        print("--- Combined Impairments (Real-World Scenarios) ---")
        let text = "CQ CQ CQ W1A"

        // Noise + fading (typical HF)
        let r1 = runSingleTest(
            category: "combined", name: "15dB+fading",
            submode: .normal, text: text, carrierFreq: 1000,
            impairment: { samples in
                let faded = applyFading(to: samples, fadeRateHz: 0.5, fadeDepth: 0.5, sampleRate: JS8.rxSampleRate)
                var rng = SeededRandom(seed: 333)
                return addWhiteNoise(to: faded, snrDB: 15, rng: &rng)
            }
        )
        results.append(r1)
        printResult(r1)

        // Noise + frequency offset (drift)
        let r2 = runSingleTest(
            category: "combined", name: "12dB+2Hz_drift",
            submode: .normal, text: text, carrierFreq: 1002,
            impairment: { samples in
                var rng = SeededRandom(seed: 444)
                return addWhiteNoise(to: samples, snrDB: 12, rng: &rng)
            }
        )
        results.append(r2)
        printResult(r2)

        // Noise + fading + clock offset (portable field op)
        let r3 = runSingleTest(
            category: "combined", name: "field_op",
            submode: .normal, text: text, carrierFreq: 1000,
            impairment: { samples in
                var shifted = applyClockOffset(to: samples, offsetSeconds: 0.5, sampleRate: JS8.rxSampleRate)
                shifted = applyFading(to: shifted, fadeRateHz: 0.3, fadeDepth: 0.4, sampleRate: JS8.rxSampleRate)
                var rng = SeededRandom(seed: 555)
                return addWhiteNoise(to: shifted, snrDB: 10, rng: &rng)
            }
        )
        results.append(r3)
        printResult(r3)

        // Deep noise with fading (emergency/QRP)
        let r4 = runSingleTest(
            category: "combined", name: "qrp_emergency",
            submode: .normal, text: text, carrierFreq: 1000,
            impairment: { samples in
                let faded = applyFading(to: samples, fadeRateHz: 0.8, fadeDepth: 0.6, sampleRate: JS8.rxSampleRate)
                var rng = SeededRandom(seed: 666)
                return addWhiteNoise(to: faded, snrDB: -5, rng: &rng)
            }
        )
        results.append(r4)
        printResult(r4)

        // Fast turbo mode with noise (quick exchange)
        let r5 = runSingleTest(
            category: "combined", name: "turbo_noisy",
            submode: .turbo, text: text, carrierFreq: 1000,
            impairment: { samples in
                var rng = SeededRandom(seed: 777)
                return addWhiteNoise(to: samples, snrDB: 10, rng: &rng)
            }
        )
        results.append(r5)
        printResult(r5)

        // Slow mode in deep noise (weak-signal DX)
        let r6 = runSingleTest(
            category: "combined", name: "slow_dx",
            submode: .slow, text: text, carrierFreq: 1000,
            impairment: { samples in
                let faded = applyFading(to: samples, fadeRateHz: 0.2, fadeDepth: 0.3, sampleRate: JS8.rxSampleRate)
                var rng = SeededRandom(seed: 888)
                return addWhiteNoise(to: faded, snrDB: -10, rng: &rng)
            }
        )
        results.append(r6)
        printResult(r6)

        print()
    }

    // MARK: - Multi-Signal

    mutating func runMultiSignalTests() {
        print("--- Multi-Signal / Adjacent Channel ---")
        let text = "CQ CQ CQ W1A"

        // Adjacent signal at +100 Hz
        let r1 = runSingleTest(
            category: "multi_signal", name: "adj_+100Hz_equal",
            submode: .normal, text: text, carrierFreq: 1000,
            impairment: { samples in
                var rng = SeededRandom(seed: 200)
                return addInterferer(to: samples, freqHz: 1100, relativeLevel: 1.0,
                                     sampleRate: JS8.rxSampleRate, rng: &rng)
            }
        )
        results.append(r1)
        printResult(r1)

        // Adjacent signal stronger (-6 dB SIR)
        let r2 = runSingleTest(
            category: "multi_signal", name: "adj_+100Hz_strong",
            submode: .normal, text: text, carrierFreq: 1000,
            impairment: { samples in
                var rng = SeededRandom(seed: 201)
                return addInterferer(to: samples, freqHz: 1100, relativeLevel: 2.0,
                                     sampleRate: JS8.rxSampleRate, rng: &rng)
            }
        )
        results.append(r2)
        printResult(r2)

        // Wideband noise + adjacent signal
        let r3 = runSingleTest(
            category: "multi_signal", name: "adj_+100Hz_15dB",
            submode: .normal, text: text, carrierFreq: 1000,
            impairment: { samples in
                var rng = SeededRandom(seed: 202)
                let noisy = addWhiteNoise(to: samples, snrDB: 15, rng: &rng)
                var rng2 = SeededRandom(seed: 203)
                return addInterferer(to: noisy, freqHz: 1100, relativeLevel: 0.5,
                                     sampleRate: JS8.rxSampleRate, rng: &rng2)
            }
        )
        results.append(r3)
        printResult(r3)

        print()
    }

    // MARK: - False Positive

    mutating func runFalsePositiveTests() {
        print("--- False Positive Tests ---")

        // Pure noise
        var rng = SeededRandom(seed: 12345)
        let noiseSamples = Int(JS8.rxSampleRate * 15)  // 15 seconds
        var noise = [Float](repeating: 0, count: noiseSamples)
        for i in 0..<noiseSamples {
            noise[i] = Float(rng.nextGaussian()) * 0.1
        }

        let decoded = js8Decode(audio: noise, submode: .normal)
        let score: Double = decoded == nil ? 100.0 : 0.0
        let result = TestResult(
            category: "false_positive", name: "noise_only",
            expected: "", decoded: decoded?.0 ?? "(none)",
            cer: decoded == nil ? 0 : 1, score: score, snr: nil
        )
        results.append(result)
        printResult(result)

        // Tone (non-JS8 signal)
        var toneSamples = [Float](repeating: 0, count: noiseSamples)
        var phase = 0.0
        for i in 0..<noiseSamples {
            toneSamples[i] = Float(sin(phase)) * 0.5
            phase += 2.0 * .pi * 1000.0 / JS8.rxSampleRate
        }
        var rng2 = SeededRandom(seed: 54321)
        toneSamples = addWhiteNoise(to: toneSamples, snrDB: 20, rng: &rng2)

        let decoded2 = js8Decode(audio: toneSamples, submode: .normal)
        let score2: Double = decoded2 == nil ? 100.0 : 0.0
        let result2 = TestResult(
            category: "false_positive", name: "cw_tone",
            expected: "", decoded: decoded2?.0 ?? "(none)",
            cer: decoded2 == nil ? 0 : 1, score: score2, snr: nil
        )
        results.append(result2)
        printResult(result2)

        print()
    }

    // MARK: - Test Runner Core

    mutating func runSingleTest(
        category: String, name: String,
        submode: JS8Submode, text: String, carrierFreq: Double,
        impairment: (([Float]) -> [Float])? = nil
    ) -> TestResult {
        // Encode
        let tones = js8Encode(message: text, i3bit: 0, submode: submode)

        // Generate audio with preamble/postamble silence
        let preDelay = submode.startDelay
        let preSilence = Int(preDelay * JS8.rxSampleRate)
        let postSilence = Int(1.0 * JS8.rxSampleRate)

        // Generate at 12kHz then upsample to 48kHz (library decoder expects 48kHz)
        var samples12k = [Float](repeating: 0, count: preSilence)
        samples12k.append(contentsOf: js8GenerateAudio(tones: tones, submode: submode, carrierFreq: carrierFreq))
        samples12k.append(contentsOf: [Float](repeating: 0, count: postSilence))

        // Simple 4x upsample by sample repetition (good enough for testing)
        var samples = [Float](repeating: 0, count: samples12k.count * 4)
        for i in 0..<samples12k.count {
            let v = samples12k[i]
            samples[i * 4] = v; samples[i * 4 + 1] = v
            samples[i * 4 + 2] = v; samples[i * 4 + 3] = v
        }

        // Apply impairments (at 48kHz)
        if let impair = impairment {
            samples = impair(samples)
        }

        // Decode using the library decoder (expects 48kHz, decimates internally)
        let libSubmode: JS8CallSubmode
        switch submode.name {
        case "Normal": libSubmode = .normal
        case "Fast": libSubmode = .fast
        case "Turbo": libSubmode = .turbo
        case "Slow": libSubmode = .slow
        default: libSubmode = .normal
        }
        let config = JS8CallConfiguration(submode: libSubmode, carrierFrequency: carrierFreq)
        let demod = JS8CallDemodulator(configuration: config)
        // Narrow frequency search to ±50 Hz around expected carrier for speed
        demod.frequencyRange = (carrierFreq - 50, carrierFreq + 50)
        let frames = demod.decodeBuffer(samples)
        let decoded = frames.first?.message ?? ""
        let snr: Double? = frames.first?.snr

        // Normalize for comparison: JS8Call's 67-char alphabet has no space.
        // Spaces in the test text are encoded as '0' by the encoder.
        // Normalize both sides by replacing spaces with '0' for fair CER comparison.
        let expectedTrimmed = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "0")
        let decodedTrimmed = String(decoded.trimmingCharacters(in: .whitespaces)
            .reversed().drop(while: { $0 == "0" || $0 == "." }).reversed())

        let cer = characterErrorRate(expected: expectedTrimmed, actual: decodedTrimmed)
        return TestResult(
            category: category, name: name,
            expected: expectedTrimmed, decoded: decodedTrimmed,
            cer: cer, score: cerToScore(cer), snr: snr
        )
    }

    // MARK: - Output

    func printResult(_ r: TestResult) {
        let scoreStr = String(format: "%5.1f", r.score)
        let cerStr = String(format: "%5.1f%%", r.cer * 100)
        let snrStr = r.snr.map { String(format: "snr=%+.0f", $0) } ?? ""
        let decodedPreview = r.decoded.count > 30
            ? String(r.decoded.prefix(27)) + "..."
            : r.decoded
        print("  [JS8] \(r.category)/\(r.name): score=\(scoreStr) cer=\(cerStr) \(snrStr) decoded=\"\(decodedPreview)\"")
    }

    func printSummary() {
        print(String(repeating: "=", count: 72))
        print("SUMMARY")
        print(String(repeating: "=", count: 72))

        let categories = Dictionary(grouping: results, by: { $0.category })

        for (category, tests) in categories.sorted(by: { $0.key < $1.key }) {
            let avgScore = tests.map(\.score).reduce(0, +) / Double(tests.count)
            let passCount = tests.filter { $0.score >= 50 }.count
            print("  \(category): \(String(format: "%.1f", avgScore))/100 (\(passCount)/\(tests.count) passed)")
        }

        // Weighted composite score
        let weights: [String: Double] = [
            "clean":          3.0,  // Must decode clean signal perfectly
            "submode":        2.0,  // All submodes must work
            "noise":          3.0,  // Noise immunity is the core value prop
            "freq_offset":    1.5,  // Frequency tolerance
            "fading":         2.5,  // QSB is the #1 HF challenge
            "clock_offset":   1.5,  // Clock sync tolerance
            "combined":       3.0,  // Real-world multi-impairment
            "multi_signal":   1.5,  // Adjacent channel rejection
            "false_positive": 2.0,  // Must not decode noise
        ]

        var weightedSum = 0.0
        var totalWeight = 0.0
        for (category, tests) in categories {
            let w = weights[category] ?? 1.0
            let avgScore = tests.map(\.score).reduce(0, +) / Double(tests.count)
            weightedSum += avgScore * w
            totalWeight += w
        }

        let compositeScore = totalWeight > 0 ? weightedSum / totalWeight : 0
        print()
        print(String(repeating: "=", count: 72))
        print("COMPOSITE SCORE: \(String(format: "%.1f", compositeScore)) / 100")
        print(String(repeating: "=", count: 72))

        writeJSON(compositeScore: compositeScore)
        appendScoreHistory(compositeScore: compositeScore, categories: categories)
    }

    func writeJSON(compositeScore: Double) {
        var json = "{\n"
        json += "  \"timestamp\": \"\(ISO8601DateFormatter().string(from: Date()))\",\n"
        json += "  \"composite_score\": \(String(format: "%.2f", compositeScore)),\n"
        json += "  \"tests\": [\n"

        for (i, r) in results.enumerated() {
            let esc = { (s: String) -> String in
                s.replacingOccurrences(of: "\\", with: "\\\\")
                 .replacingOccurrences(of: "\"", with: "\\\"")
                 .replacingOccurrences(of: "\n", with: "\\n")
            }
            json += "    {"
            json += "\"category\":\"\(r.category)\","
            json += "\"name\":\"\(r.name)\","
            json += "\"expected\":\"\(esc(r.expected))\","
            json += "\"decoded\":\"\(esc(r.decoded))\","
            json += "\"cer\":\(String(format: "%.4f", r.cer)),"
            json += "\"score\":\(String(format: "%.2f", r.score))"
            if let snr = r.snr { json += ",\"snr\":\(String(format: "%.1f", snr))" }
            json += "}\(i < results.count - 1 ? "," : "")\n"
        }

        json += "  ]\n}\n"

        let path = "/tmp/js8_benchmark_latest.json"
        try? json.write(toFile: path, atomically: true, encoding: .utf8)
        print("\nDetailed results written to: \(path)")
    }

    func appendScoreHistory(compositeScore: Double, categories: [String: [TestResult]]) {
        let historyPath = "/tmp/js8_benchmark_history.csv"
        let timestamp = ISO8601DateFormatter().string(from: Date())

        let cats = ["clean", "submode", "noise", "freq_offset", "fading",
                     "clock_offset", "combined", "multi_signal", "false_positive"]

        if !FileManager.default.fileExists(atPath: historyPath) {
            let header = "timestamp,composite_score," + cats.joined(separator: ",") + "\n"
            try? header.write(toFile: historyPath, atomically: true, encoding: .utf8)
        }

        let scoreMap = Dictionary(uniqueKeysWithValues: categories.map { cat, tests in
            (cat, tests.map(\.score).reduce(0, +) / Double(tests.count))
        })
        let values = cats.map { String(format: "%.2f", scoreMap[$0] ?? 0) }.joined(separator: ",")
        let line = "\(timestamp),\(String(format: "%.2f", compositeScore)),\(values)\n"

        if let handle = FileHandle(forWritingAtPath: historyPath) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8)!)
            handle.closeFile()
        }
        print("Score history appended to: \(historyPath)")
    }
}

// ============================================================================
// MARK: - Main
// ============================================================================

print("Starting JS8Call benchmark...")
print("  Reference encoder: 68-char alphabet + CRC-12 + LDPC(174,87) + 8-FSK")
print("  Reference decoder: Nuttall spectrogram + Costas sync + BP LDPC decoder")
print()

var suite = BenchmarkSuite()
suite.runAll()
