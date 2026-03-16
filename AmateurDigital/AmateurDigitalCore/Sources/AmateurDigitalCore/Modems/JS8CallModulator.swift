//
//  JS8CallModulator.swift
//  AmateurDigitalCore
//
//  JS8Call encoder and modulator: text -> LDPC codeword -> 8-FSK tones -> audio.
//

import Foundation

public struct JS8CallModulator {

    public private(set) var currentConfiguration: JS8CallConfiguration
    private var phase: Double = 0

    public init(configuration: JS8CallConfiguration = .standard) {
        self.currentConfiguration = configuration
    }

    // MARK: - Tone Encoding

    /// Encode a message string (up to 12 chars) and frame type into 79 channel tones (values 0-7).
    public func encodeTones(message: String, frameType: Int = 0) -> [Int] {
        let msgbits = JS8CallCodec.pack(message: message, frameType: frameType)
        let codeword = LDPC174_87.encode(msgbits)
        return mapToTones(codeword: codeword)
    }

    /// Map a 174-bit LDPC codeword to 79 channel symbols with Costas sync interleaving.
    private func mapToTones(codeword: [UInt8]) -> [Int] {
        let costas = currentConfiguration.submode.costas
        var itone = [Int](repeating: 0, count: JS8CallConstants.NN)

        // Insert Costas sync arrays
        for i in 0..<7 { itone[i] = costas.a[i] }
        for i in 0..<7 { itone[36 + i] = costas.b[i] }
        for i in 0..<7 { itone[JS8CallConstants.NN - 7 + i] = costas.c[i] }

        // Fill data symbols (58 total, 3 bits each from the 174-bit codeword)
        var k = 7  // Start after first Costas
        for j in 1...JS8CallConstants.ND {
            let i = 3 * j - 3
            if j == 30 { k += 7 }  // Skip middle Costas block
            itone[k] = Int(codeword[i]) * 4 + Int(codeword[i + 1]) * 2 + Int(codeword[i + 2])
            k += 1
        }

        return itone
    }

    // MARK: - Audio Generation

    /// Generate 8-FSK audio at the internal 12 kHz sample rate from tone sequence.
    public mutating func generateAudioInternal(tones: [Int]) -> [Float] {
        let nsps = currentConfiguration.submode.nsps
        let sr = JS8CallConstants.internalSampleRate
        let spacing = currentConfiguration.submode.toneSpacing
        let carrier = currentConfiguration.carrierFrequency
        let twopi = 2.0 * Double.pi

        var samples = [Float]()
        samples.reserveCapacity(JS8CallConstants.NN * nsps)

        for i in 0..<JS8CallConstants.NN {
            let freq = carrier + Double(tones[i]) * spacing
            let dphi = twopi * freq / sr
            for _ in 0..<nsps {
                samples.append(Float(sin(phase)))
                phase += dphi
                if phase >= twopi { phase -= twopi }
            }
        }
        return samples
    }

    /// Generate audio at the external sample rate (default 48 kHz).
    /// Upsamples from 12 kHz using linear interpolation.
    public mutating func generateAudio(tones: [Int]) -> [Float] {
        let internal12k = generateAudioInternal(tones: tones)
        let factor = currentConfiguration.decimationFactor
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

    // MARK: - Convenience

    /// Full pipeline: text -> tones -> audio at external sample rate.
    public mutating func modulateText(_ text: String, frameType: Int = 0) -> [Float] {
        let tones = encodeTones(message: text, frameType: frameType)
        return generateAudio(tones: tones)
    }

    /// Encode with startDelay silence and trailing silence.
    /// The caller (ChatViewModel) is responsible for waiting until the
    /// next UTC period boundary before playing the returned audio.
    /// The startDelay silence (e.g., 500ms for Normal) positions the
    /// 8-FSK waveform at the correct offset within the period.
    public mutating func modulateTextWithEnvelope(
        _ text: String,
        frameType: Int = 0,
        preambleMs: Double = 0,
        postambleMs: Double = 200
    ) -> [Float] {
        let sr = currentConfiguration.sampleRate
        let startDelay = currentConfiguration.submode.startDelay

        // startDelay positions the signal within the period (e.g., 500ms for Normal)
        let preSamples = Int((startDelay + preambleMs / 1000.0) * sr)
        let postSamples = Int(postambleMs / 1000.0 * sr)

        var samples = [Float](repeating: 0, count: preSamples)
        samples.append(contentsOf: modulateText(text, frameType: frameType))
        samples.append(contentsOf: [Float](repeating: 0, count: postSamples))

        // Fade-out over the last ~17ms of the signal portion
        let sigEnd = preSamples + (JS8CallConstants.NN * currentConfiguration.submode.nsps * currentConfiguration.decimationFactor)
        let fadeLen = Int(0.017 * sr)
        if sigEnd > fadeLen && sigEnd <= samples.count {
            for i in 0..<fadeLen {
                let idx = sigEnd - fadeLen + i
                if idx >= 0 && idx < samples.count {
                    samples[idx] *= Float(0.5 * (1.0 + cos(Double.pi * Double(i) / Double(fadeLen))))
                }
            }
        }

        return samples
    }

    /// Reset modulator phase state.
    public mutating func reset() {
        phase = 0
    }
}
