//
//  GFSKModulator.swift
//  AmateurDigitalCore
//
//  Generic 8-GFSK modulator shared by FT8, JS8Call, and related modes.
//  Converts an LDPC codeword into 79 channel symbols with Costas sync,
//  then generates continuous-phase FSK audio at the internal sample rate.
//

import Foundation

/// Modulates 8-GFSK audio from LDPC codewords or pre-built symbol sequences.
///
/// The modulator handles two concerns:
/// 1. **Symbol mapping**: Interleave 58 data symbols (from 174-bit LDPC codeword)
///    with 21 Costas sync symbols to produce 79 channel symbols.
/// 2. **Tone generation**: Convert symbol sequence to continuous-phase FSK audio
///    at the internal sample rate (typically 12 kHz).
///
/// Usage:
/// ```swift
/// var mod = GFSKModulator(config: .ft8)
/// let symbols = mod.mapCodewordToSymbols(codeword)  // 174 bits -> 79 symbols
/// let audio = mod.generateAudio(symbols: symbols)    // 79 symbols -> audio samples
/// ```
public struct GFSKModulator {

    public let config: GFSKConfig
    private var phase: Double = 0

    public init(config: GFSKConfig) {
        self.config = config
    }

    // MARK: - Symbol Mapping

    /// Map a 174-bit LDPC codeword to 79 channel symbols (0-7) with Costas sync interleaving.
    ///
    /// The 79-symbol frame structure is:
    /// - Symbols 0-6: Costas array A (sync)
    /// - Symbols 7-35: Data symbols 1-29 (3 bits each from codeword)
    /// - Symbols 36-42: Costas array B (sync)
    /// - Symbols 43-71: Data symbols 30-58 (3 bits each from codeword)
    /// - Symbols 72-78: Costas array C (sync)
    ///
    /// Each data symbol encodes 3 consecutive codeword bits as a Gray-coded tone index (0-7).
    public func mapCodewordToSymbols(_ codeword: [UInt8]) -> [Int] {
        let costas = config.costasArrays
        var symbols = [Int](repeating: 0, count: config.symbolCount)

        // Insert Costas sync arrays at positions 0-6, 36-42, 72-78
        for i in 0..<7 { symbols[i] = costas.a[i] }
        for i in 0..<7 { symbols[36 + i] = costas.b[i] }
        for i in 0..<7 { symbols[config.symbolCount - 7 + i] = costas.c[i] }

        // Fill 58 data symbols (3 bits each from the 174-bit codeword)
        var k = 7  // Start after first Costas
        for j in 1...config.dataSymbolCount {
            let i = 3 * j - 3
            if j == 30 { k += 7 }  // Skip middle Costas block (symbols 36-42)
            symbols[k] = Int(codeword[i]) * 4 + Int(codeword[i + 1]) * 2 + Int(codeword[i + 2])
            k += 1
        }

        return symbols
    }

    // MARK: - Audio Generation

    /// Generate 8-GFSK audio at the internal sample rate from a 79-symbol sequence.
    ///
    /// Produces continuous-phase FSK: the phase accumulator carries across symbol
    /// boundaries, ensuring smooth frequency transitions (no phase discontinuities).
    ///
    /// - Parameter symbols: Array of 79 tone indices (0-7).
    /// - Returns: Audio samples at the internal rate (typically 12 kHz).
    public mutating func generateAudioInternal(symbols: [Int]) -> [Float] {
        let nsps = config.samplesPerSymbol
        let sr = config.internalRate
        let spacing = config.toneSpacing
        let carrier = config.carrierFrequency
        let twopi = 2.0 * Double.pi

        var samples = [Float]()
        samples.reserveCapacity(config.symbolCount * nsps)

        for i in 0..<config.symbolCount {
            let freq = carrier + Double(symbols[i]) * spacing
            let dphi = twopi * freq / sr
            for _ in 0..<nsps {
                samples.append(Float(sin(phase)))
                phase += dphi
                if phase >= twopi { phase -= twopi }
            }
        }
        return samples
    }

    /// Generate audio at the external sample rate.
    /// Upsamples from the internal rate using linear interpolation.
    ///
    /// - Parameter symbols: Array of 79 tone indices (0-7).
    /// - Returns: Audio samples at the external rate (typically 48 kHz).
    public mutating func generateAudio(symbols: [Int]) -> [Float] {
        let internal12k = generateAudioInternal(symbols: symbols)
        let factor = config.decimationFactor
        if factor <= 1 { return internal12k }

        // Upsample by linear interpolation
        let outCount = internal12k.count * factor
        var output = [Float](repeating: 0, count: outCount)
        for i in 0..<internal12k.count - 1 {
            let a = internal12k[i]
            let b = internal12k[i + 1]
            for j in 0..<factor {
                let frac = Float(j) / Float(factor)
                output[i * factor + j] = a + (b - a) * frac
            }
        }
        // Last sample
        let last = internal12k.count - 1
        for j in 0..<factor {
            output[last * factor + j] = internal12k[last]
        }
        return output
    }

    /// Reset the phase accumulator.
    public mutating func reset() {
        phase = 0
    }
}
