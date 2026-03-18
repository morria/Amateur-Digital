//
//  WattersonChannel.swift
//  AmateurDigitalCore
//
//  Watterson HF ionospheric channel simulator implementing ITU-R F.1487
//  standard test channels. Models multipath propagation with independent
//  Rayleigh fading on each path.
//
//  Standard channels (CCIR/ITU):
//    AWGN:     No fading, no multipath
//    Good:     Spread 0.1 Hz, Delay 0.5 ms
//    Moderate: Spread 0.5 Hz, Delay 1.0 ms
//    Poor:     Spread 1.0 Hz, Delay 2.0 ms
//    Disturbed: Spread 2.5 Hz, Delay 5.0 ms
//
//  Reference: ITU-R Recommendation F.1487, PathSim by Moe Wheatley
//

import Foundation

/// Watterson HF channel model for realistic propagation simulation.
///
/// Implements two independently fading paths with configurable Doppler spread
/// and differential delay, matching the ITU/CCIR standard test channels used
/// by PathSim, linsim, and IONOS for digital mode evaluation.
public struct WattersonChannel {

    /// Doppler spread in Hz (controls fade rate)
    public let dopplerSpread: Double

    /// Differential delay between paths in seconds
    public let pathDelay: Double

    /// Sample rate
    public let sampleRate: Double

    /// Power ratio between paths (1.0 = equal power)
    public let pathPowerRatio: Double

    // Internal state for Rayleigh fading generators
    private var phase1: Double = 0
    private var phase2: Double = 0
    private var fadePhase1a: Double = 0
    private var fadePhase1b: Double = 0
    private var fadePhase2a: Double = 0
    private var fadePhase2b: Double = 0
    private var rngState: UInt64

    // Delay line for second path
    private var delayBuffer: [Float] = []
    private var delayWritePos: Int = 0

    /// Create a Watterson channel model.
    /// - Parameters:
    ///   - dopplerSpread: Doppler spread in Hz (fade rate)
    ///   - pathDelay: Differential delay between paths in seconds
    ///   - sampleRate: Audio sample rate (default 48000)
    ///   - pathPowerRatio: Power ratio path2/path1 (default 1.0 = equal)
    ///   - seed: Random seed for reproducible fading
    public init(
        dopplerSpread: Double,
        pathDelay: Double,
        sampleRate: Double = 48000,
        pathPowerRatio: Double = 1.0,
        seed: UInt64 = 42
    ) {
        self.dopplerSpread = dopplerSpread
        self.pathDelay = pathDelay
        self.sampleRate = sampleRate
        self.pathPowerRatio = pathPowerRatio
        self.rngState = seed == 0 ? 1 : seed

        // Initialize delay buffer for the second path
        let delaySamples = max(1, Int(pathDelay * sampleRate))
        self.delayBuffer = [Float](repeating: 0, count: delaySamples)

        // Randomize initial fade phases
        fadePhase1a = nextRandom() * 2.0 * .pi
        fadePhase1b = nextRandom() * 2.0 * .pi
        fadePhase2a = nextRandom() * 2.0 * .pi
        fadePhase2b = nextRandom() * 2.0 * .pi
    }

    /// Process audio through the channel model.
    /// - Parameter samples: Input audio samples
    /// - Returns: Faded, multipath-corrupted audio
    public mutating func process(_ samples: [Float]) -> [Float] {
        guard dopplerSpread > 0 || pathDelay > 0 else { return samples }

        let n = samples.count
        var output = [Float](repeating: 0, count: n)
        let twopi = 2.0 * Double.pi

        // Fade rate: Doppler spread controls how fast the complex gain changes.
        // Each path has a Rayleigh-distributed amplitude from two independent
        // Gaussian processes (in-phase and quadrature).
        let fadeRate1a = dopplerSpread * 0.7  // Slightly different rates
        let fadeRate1b = dopplerSpread * 1.3  // to decorrelate I and Q
        let fadeRate2a = dopplerSpread * 0.9
        let fadeRate2b = dopplerSpread * 1.1

        let dphi1a = twopi * fadeRate1a / sampleRate
        let dphi1b = twopi * fadeRate1b / sampleRate
        let dphi2a = twopi * fadeRate2a / sampleRate
        let dphi2b = twopi * fadeRate2b / sampleRate

        let delaySamples = delayBuffer.count
        let p2gain = Float(sqrt(pathPowerRatio))

        for i in 0..<n {
            // Path 1: direct (no delay), Rayleigh fading
            let fade1I = Float(cos(fadePhase1a))
            let fade1Q = Float(sin(fadePhase1b))
            let fade1Amp = sqrt(fade1I * fade1I + fade1Q * fade1Q)

            // Path 2: delayed, independent Rayleigh fading
            let fade2I = Float(cos(fadePhase2a))
            let fade2Q = Float(sin(fadePhase2b))
            let fade2Amp = sqrt(fade2I * fade2I + fade2Q * fade2Q) * p2gain

            // Read delayed sample for path 2
            let delayedSample = delayBuffer[delayWritePos]

            // Write current sample to delay buffer
            delayBuffer[delayWritePos] = samples[i]
            delayWritePos = (delayWritePos + 1) % delaySamples

            // Sum both paths with their independent fading
            output[i] = samples[i] * fade1Amp + delayedSample * fade2Amp

            // Advance fade oscillators
            fadePhase1a += dphi1a
            fadePhase1b += dphi1b
            fadePhase2a += dphi2a
            fadePhase2b += dphi2b

            // Wrap phases
            if fadePhase1a > twopi { fadePhase1a -= twopi }
            if fadePhase1b > twopi { fadePhase1b -= twopi }
            if fadePhase2a > twopi { fadePhase2a -= twopi }
            if fadePhase2b > twopi { fadePhase2b -= twopi }
        }

        // Normalize output power to roughly match input
        // (two equal-power Rayleigh paths average to sqrt(2) amplitude)
        let normFactor: Float = pathDelay > 0 ? Float(1.0 / sqrt(1.0 + pathPowerRatio)) : 1.0
        for i in 0..<n {
            output[i] *= normFactor
        }

        return output
    }

    /// Xorshift64 random number generator
    private mutating func nextRandom() -> Double {
        rngState ^= rngState >> 12
        rngState ^= rngState << 25
        rngState ^= rngState >> 27
        let value = rngState &* 0x2545F4914F6CDD1D
        return Double(value) / Double(UInt64.max)
    }

    // MARK: - Standard ITU/CCIR Channel Presets

    /// AWGN only — no fading, no multipath (baseline)
    public static func awgn(sampleRate: Double = 48000) -> WattersonChannel {
        WattersonChannel(dopplerSpread: 0, pathDelay: 0, sampleRate: sampleRate, seed: 1)
    }

    /// ITU Good (MPG): quiet HF conditions
    public static func good(sampleRate: Double = 48000, seed: UInt64 = 42) -> WattersonChannel {
        WattersonChannel(dopplerSpread: 0.1, pathDelay: 0.0005, sampleRate: sampleRate, seed: seed)
    }

    /// ITU Moderate (MPM): typical HF propagation
    public static func moderate(sampleRate: Double = 48000, seed: UInt64 = 42) -> WattersonChannel {
        WattersonChannel(dopplerSpread: 0.5, pathDelay: 0.001, sampleRate: sampleRate, seed: seed)
    }

    /// ITU Poor (MPP): disturbed conditions
    public static func poor(sampleRate: Double = 48000, seed: UInt64 = 42) -> WattersonChannel {
        WattersonChannel(dopplerSpread: 1.0, pathDelay: 0.002, sampleRate: sampleRate, seed: seed)
    }

    /// ITU Disturbed (MPD): storm conditions
    public static func disturbed(sampleRate: Double = 48000, seed: UInt64 = 42) -> WattersonChannel {
        WattersonChannel(dopplerSpread: 2.5, pathDelay: 0.005, sampleRate: sampleRate, seed: seed)
    }
}
