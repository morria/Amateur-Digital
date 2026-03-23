//
//  DualCWDecoder.swift
//  AmateurDigitalCore
//
//  Multi-decoder diversity for CW: runs Classic (Goertzel + state machine)
//  and Bayesian (probabilistic + beam search) decoders in parallel, merging
//  output using an adaptive selection strategy.
//
//  Inspired by N1MM+ contest operators who run MMTTY + 2Tone simultaneously
//  because "no single decoder performs best under all conditions."
//
//  Strategy:
//  - Feed the same audio to both decoders simultaneously
//  - Track recent output rate from each decoder (characters per window)
//  - Characters that both decoders agree on are emitted immediately (high confidence)
//  - When they disagree, use the decoder with higher recent output rate
//  - A short merge window (~300ms) allows the slower decoder to catch up
//

import Foundation

/// Diversity CW decoder that runs Classic and Bayesian decoders in parallel.
///
/// Uses callback closures (`onCharacterDecoded`, `onSignalDetected`) matching
/// the BayesianCWDecoder pattern for easy integration.
public final class DualCWDecoder {

    // MARK: - Sub-Decoders

    private let classicDecoder: CWDemodulator
    private let bayesianDecoder: BayesianCWDecoder

    // MARK: - Merge State

    /// Timestamped character from a decoder
    private struct TimedChar {
        let character: Character
        let frequency: Double
        let timestamp: Int  // block count at time of decode
    }

    /// Pending characters from each decoder, waiting for merge
    private var classicPending: [TimedChar] = []
    private var bayesianPending: [TimedChar] = []

    /// Block counter (incremented per process call for coarse timing)
    private var blockCounter: Int = 0

    /// Merge window in blocks. At 48kHz with 4096-sample audio buffers,
    /// each process() call is ~85ms. 4 blocks = ~340ms merge window.
    private let mergeWindowBlocks: Int = 4

    /// Recent character counts for adaptive selection (sliding window)
    private var classicRecentCount: Int = 0
    private var bayesianRecentCount: Int = 0

    /// Decay counter for resetting recent counts periodically
    private var decayCounter: Int = 0
    private let decayInterval: Int = 20  // Reset counts every ~20 blocks (~1.7s)

    // MARK: - Callbacks

    /// Callback when a character is decoded. Parameters: (character, frequency)
    public var onCharacterDecoded: ((Character, Double) -> Void)?

    /// Callback when signal detection state changes. Parameters: (detected, frequency)
    public var onSignalDetected: ((Bool, Double) -> Void)?

    // MARK: - Public Properties

    public var signalDetected: Bool {
        classicDecoder.signalDetected || bayesianDecoder.signalDetected
    }

    public var signalStrength: Float {
        max(classicDecoder.signalStrength, bayesianDecoder.signalStrength)
    }

    public var estimatedWPM: Double {
        // Use the decoder that currently has signal
        if classicDecoder.signalDetected && bayesianDecoder.signalDetected {
            return (classicDecoder.estimatedWPM + bayesianDecoder.estimatedWPM) / 2.0
        } else if classicDecoder.signalDetected {
            return classicDecoder.estimatedWPM
        } else {
            return bayesianDecoder.estimatedWPM
        }
    }

    public var toneFrequency: Double {
        classicDecoder.toneFrequency
    }

    public var currentConfiguration: CWConfiguration {
        classicDecoder.currentConfiguration
    }

    // MARK: - Initialization

    public init(configuration: CWConfiguration = .standard) {
        self.classicDecoder = CWDemodulator(configuration: configuration)
        self.bayesianDecoder = BayesianCWDecoder(configuration: configuration)

        // Wire up classic decoder via delegate adapter
        classicDecoder.delegate = classicAdapter
        classicAdapter.owner = self

        // Wire up bayesian decoder via closures
        bayesianDecoder.onCharacterDecoded = { [weak self] char, freq in
            self?.onBayesianCharacter(char, frequency: freq)
        }
        bayesianDecoder.onSignalDetected = { [weak self] detected, freq in
            self?.onDecoderSignalChanged()
        }
    }

    /// Internal adapter to receive CWDemodulatorDelegate callbacks
    private let classicAdapter = ClassicDecoderAdapter()

    // MARK: - Processing

    public func process(samples: [Float]) {
        blockCounter += 1

        // Feed audio to both decoders simultaneously
        classicDecoder.process(samples: samples)
        bayesianDecoder.process(samples: samples)

        // Attempt to merge pending characters
        flushMergeWindow()

        // Periodic decay of recent counts for adaptive selection
        decayCounter += 1
        if decayCounter >= decayInterval {
            decayCounter = 0
            classicRecentCount = classicRecentCount / 2
            bayesianRecentCount = bayesianRecentCount / 2
        }
    }

    // MARK: - Character Callbacks from Sub-Decoders

    fileprivate func onClassicCharacter(_ character: Character, frequency: Double) {
        classicPending.append(TimedChar(
            character: character,
            frequency: frequency,
            timestamp: blockCounter
        ))
        classicRecentCount += 1
    }

    private func onBayesianCharacter(_ character: Character, frequency: Double) {
        bayesianPending.append(TimedChar(
            character: character,
            frequency: frequency,
            timestamp: blockCounter
        ))
        bayesianRecentCount += 1
    }

    fileprivate func onDecoderSignalChanged() {
        let detected = signalDetected
        let freq = toneFrequency
        onSignalDetected?(detected, freq)
    }

    // MARK: - Merge Logic

    /// Flush characters whose merge window has expired.
    ///
    /// Strategy:
    /// 1. If both decoders produced the same character within the merge window, emit it (agreement).
    /// 2. If only one decoder produced a character and the window expired, emit it from
    ///    the decoder with higher recent output rate (adaptive selection).
    /// 3. Spaces are always passed through from the preferred decoder (they indicate word gaps).
    private func flushMergeWindow() {
        let cutoff = blockCounter - mergeWindowBlocks

        // First pass: find matching characters (agreement between decoders)
        var classicConsumed = Set<Int>()
        var bayesianConsumed = Set<Int>()

        for (ci, classic) in classicPending.enumerated() {
            for (bi, bayesian) in bayesianPending.enumerated() {
                if bayesianConsumed.contains(bi) { continue }
                // Characters match if they're the same and within the merge window
                if classic.character == bayesian.character &&
                   abs(classic.timestamp - bayesian.timestamp) <= mergeWindowBlocks {
                    // Agreement — emit immediately
                    onCharacterDecoded?(classic.character, classic.frequency)
                    classicConsumed.insert(ci)
                    bayesianConsumed.insert(bi)
                    break
                }
            }
        }

        // Remove consumed entries
        classicPending = classicPending.enumerated()
            .filter { !classicConsumed.contains($0.offset) }
            .map { $0.element }
        bayesianPending = bayesianPending.enumerated()
            .filter { !bayesianConsumed.contains($0.offset) }
            .map { $0.element }

        // Second pass: emit expired characters from the preferred decoder
        let classicExpired = classicPending.filter { $0.timestamp <= cutoff }
        let bayesianExpired = bayesianPending.filter { $0.timestamp <= cutoff }

        // Determine preferred decoder based on recent output rate
        let preferClassic = classicRecentCount >= bayesianRecentCount

        if preferClassic {
            // Emit classic decoder's expired characters
            for char in classicExpired {
                onCharacterDecoded?(char.character, char.frequency)
            }
        } else {
            // Emit bayesian decoder's expired characters
            for char in bayesianExpired {
                onCharacterDecoded?(char.character, char.frequency)
            }
        }

        // Remove all expired entries from both queues
        classicPending.removeAll { $0.timestamp <= cutoff }
        bayesianPending.removeAll { $0.timestamp <= cutoff }
    }

    // MARK: - Control

    public func reset() {
        classicDecoder.reset()
        bayesianDecoder.reset()
        classicPending.removeAll()
        bayesianPending.removeAll()
        classicRecentCount = 0
        bayesianRecentCount = 0
        blockCounter = 0
        decayCounter = 0
    }
}

// MARK: - Classic Decoder Adapter

/// Bridges CWDemodulatorDelegate to the DualCWDecoder's internal method.
private class ClassicDecoderAdapter: CWDemodulatorDelegate {
    weak var owner: DualCWDecoder?

    func demodulator(_ demodulator: CWDemodulator, didDecode character: Character, atFrequency frequency: Double) {
        owner?.onClassicCharacter(character, frequency: frequency)
    }

    func demodulator(_ demodulator: CWDemodulator, signalDetected detected: Bool, atFrequency frequency: Double) {
        owner?.onDecoderSignalChanged()
    }
}
