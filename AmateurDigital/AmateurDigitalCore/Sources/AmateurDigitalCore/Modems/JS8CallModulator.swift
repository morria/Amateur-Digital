//
//  JS8CallModulator.swift
//  AmateurDigitalCore
//
//  JS8Call encoder and modulator: text -> LDPC codeword -> 8-FSK tones -> audio.
//  Delegates tone generation to GFSKModulator (shared physical layer).
//

import Foundation

public struct JS8CallModulator {

    public private(set) var currentConfiguration: JS8CallConfiguration
    private var gfskModulator: GFSKModulator

    public init(configuration: JS8CallConfiguration = .standard) {
        self.currentConfiguration = configuration
        self.gfskModulator = GFSKModulator(config: configuration.gfskConfig)
    }

    // MARK: - Tone Encoding

    /// Encode a message string (up to 12 chars) and frame type into 79 channel tones (values 0-7).
    public func encodeTones(message: String, frameType: Int = 0) -> [Int] {
        let msgbits = JS8CallCodec.pack(message: message, frameType: frameType)
        let codeword = LDPC174_87.encode(msgbits)
        return gfskModulator.mapCodewordToSymbols(codeword)
    }

    // MARK: - Audio Generation

    /// Generate 8-FSK audio at the internal 12 kHz sample rate from tone sequence.
    public mutating func generateAudioInternal(tones: [Int]) -> [Float] {
        return gfskModulator.generateAudioInternal(symbols: tones)
    }

    /// Generate audio at the external sample rate (default 48 kHz).
    /// Upsamples from 12 kHz using linear interpolation.
    public mutating func generateAudio(tones: [Int]) -> [Float] {
        return gfskModulator.generateAudio(symbols: tones)
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
        gfskModulator.reset()
    }
}
