//
//  AudioSampleBuffer.swift
//  AmateurDigital
//
//  Thread-safe ring buffer for audio samples.
//  Designed to be written from the audio thread and read from the main thread.
//

import Foundation

/// Thread-safe audio sample buffer that can be shared across actor boundaries.
/// Uses a lock for synchronization since it's accessed from both the audio thread
/// and the main actor.
final class AudioSampleBuffer: @unchecked Sendable {
    private var buffer: [Float] = []
    private let lock = NSLock()
    private let maxSamples: Int

    /// Create a buffer that holds up to `maxSamples` samples.
    /// Default is 96000 (~2 seconds at 48 kHz).
    init(maxSamples: Int = 96000) {
        self.maxSamples = maxSamples
    }

    /// Append samples (called from audio thread).
    func append(_ samples: [Float]) {
        lock.lock()
        buffer.append(contentsOf: samples)
        if buffer.count > maxSamples {
            buffer.removeFirst(buffer.count - maxSamples)
        }
        lock.unlock()
    }

    /// Get a copy of all buffered samples (called from main thread).
    func snapshot() -> [Float] {
        lock.lock()
        let copy = buffer
        lock.unlock()
        return copy
    }

    /// Clear the buffer.
    func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }
}
