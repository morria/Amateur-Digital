//
//  TestAudioLoader.swift
//  DigiModes
//
//  Loads WAV files for integration testing of the demodulation pipeline
//

import Foundation
import AVFoundation

/// Loads and processes WAV files for testing the decoding pipeline
struct TestAudioLoader {

    /// Load a WAV file and return Float samples at the specified sample rate
    /// - Parameters:
    ///   - url: URL to the WAV file
    ///   - targetSampleRate: Target sample rate (default 48000 Hz)
    /// - Returns: Array of Float samples, or nil if loading fails
    static func loadWAV(from url: URL, targetSampleRate: Double = 48000) -> [Float]? {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let frameCount = AVAudioFrameCount(file.length)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
                print("[TestAudioLoader] Failed to create buffer")
                return nil
            }

            try file.read(into: buffer)

            // Convert to mono Float array
            guard let channelData = buffer.floatChannelData else {
                print("[TestAudioLoader] No float channel data")
                return nil
            }

            let channelCount = Int(format.channelCount)
            let length = Int(buffer.frameLength)
            var samples = [Float](repeating: 0, count: length)

            if channelCount == 1 {
                // Mono - copy directly
                for i in 0..<length {
                    samples[i] = channelData[0][i]
                }
            } else {
                // Stereo or more - mix to mono
                for i in 0..<length {
                    var sum: Float = 0
                    for ch in 0..<channelCount {
                        sum += channelData[ch][i]
                    }
                    samples[i] = sum / Float(channelCount)
                }
            }

            // Resample if needed
            if format.sampleRate != targetSampleRate {
                samples = resample(samples, from: format.sampleRate, to: targetSampleRate)
            }

            print("[TestAudioLoader] Loaded \(samples.count) samples from \(url.lastPathComponent)")
            return samples

        } catch {
            print("[TestAudioLoader] Error loading WAV: \(error)")
            return nil
        }
    }

    /// Load a WAV file from a path string
    static func loadWAV(from path: String, targetSampleRate: Double = 48000) -> [Float]? {
        let url = URL(fileURLWithPath: path)
        return loadWAV(from: url, targetSampleRate: targetSampleRate)
    }

    /// Simple linear interpolation resampling
    private static func resample(_ samples: [Float], from sourceSampleRate: Double, to targetSampleRate: Double) -> [Float] {
        let ratio = sourceSampleRate / targetSampleRate
        let newLength = Int(Double(samples.count) / ratio)
        var resampled = [Float](repeating: 0, count: newLength)

        for i in 0..<newLength {
            let sourceIndex = Double(i) * ratio
            let index0 = Int(sourceIndex)
            let index1 = min(index0 + 1, samples.count - 1)
            let frac = Float(sourceIndex - Double(index0))

            resampled[i] = samples[index0] * (1 - frac) + samples[index1] * frac
        }

        print("[TestAudioLoader] Resampled from \(Int(sourceSampleRate)) to \(Int(targetSampleRate)) Hz")
        return resampled
    }
}
