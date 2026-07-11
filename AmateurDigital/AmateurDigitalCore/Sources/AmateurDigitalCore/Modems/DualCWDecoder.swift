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
        let timestamp: Int  // sample clock at time of decode
    }

    /// Pending characters from each decoder, waiting for merge
    private var classicPending: [TimedChar] = []
    private var bayesianPending: [TimedChar] = []

    /// Sample clock: total samples fed so far. Using samples (not process()
    /// call counts) makes merge timing independent of the caller's buffer
    /// size — a benchmark feeding one giant buffer and an app feeding 85 ms
    /// chunks behave identically.
    private var sampleClock: Int = 0

    /// Merge window in samples (~350 ms): how long a character may wait for
    /// its counterpart from the other decoder before the disagreement is
    /// resolved.
    private let mergeWindowSamples: Int

    /// Reliability = EMA of each decoder's recent agreement fraction.
    /// Characters the decoders agree on raise both; characters that lose a
    /// disagreement lower the loser. This prefers the decoder that is
    /// *corroborated*, not the one that merely produces more output —
    /// in noise, a hallucinating decoder out-produces an accurate one.
    private var classicReliability: Double = 0.60   // slight classic bias at start
    private var bayesianReliability: Double = 0.50
    private let reliabilityAlpha: Double = 0.08

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

    /// Minimum tracked speed, forwarded to both sub-decoders.
    public var minWPM: Double {
        get { classicDecoder.minWPM }
        set {
            classicDecoder.minWPM = newValue
            bayesianDecoder.minWPM = newValue
        }
    }

    /// Maximum tracked speed, forwarded to both sub-decoders.
    public var maxWPM: Double {
        get { classicDecoder.maxWPM }
        set {
            classicDecoder.maxWPM = newValue
            bayesianDecoder.maxWPM = newValue
        }
    }

    // MARK: - Initialization

    public init(configuration: CWConfiguration = .standard) {
        self.classicDecoder = CWDemodulator(configuration: configuration)
        self.bayesianDecoder = BayesianCWDecoder(configuration: configuration)
        self.mergeWindowSamples = Int(0.35 * configuration.sampleRate)

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

    /// Background/low-power: run only the classic leg. Halves the DSP
    /// cost while the app isn't frontmost; the Bayesian leg keeps its
    /// calibration and is resynchronized when full power returns.
    public var lowPowerMode: Bool = false {
        didSet {
            guard oldValue != lowPowerMode, !lowPowerMode else { return }
            bayesianDecoder.resynchronize()
        }
    }

    public func process(samples: [Float]) {
        sampleClock += samples.count

        // Feed audio to both decoders simultaneously
        classicDecoder.process(samples: samples)
        if !lowPowerMode {
            bayesianDecoder.process(samples: samples)
        }

        // Attempt to merge pending characters
        flushMergeWindow()
    }

    // MARK: - Character Callbacks from Sub-Decoders

    fileprivate func onClassicCharacter(_ character: Character, frequency: Double) {
        classicPending.append(TimedChar(
            character: character,
            frequency: frequency,
            timestamp: sampleClock
        ))
    }

    private func onBayesianCharacter(_ character: Character, frequency: Double) {
        bayesianPending.append(TimedChar(
            character: character,
            frequency: frequency,
            timestamp: sampleClock
        ))
    }

    fileprivate func onDecoderSignalChanged() {
        let detected = signalDetected
        let freq = toneFrequency
        onSignalDetected?(detected, freq)
    }

    // MARK: - Merge Logic

    /// Merge the two character streams, preserving temporal order.
    ///
    /// Strategy (order-safe by construction — output is only ever produced
    /// from the queue heads, never from the middle):
    ///
    /// 1. **Agreement:** while both queue heads hold the same character within
    ///    the merge window, emit it once and credit both decoders.
    /// 2. **Disagreement:** when the heads differ, wait until the older head
    ///    falls out of the merge window, then resolve the whole disagreement
    ///    run at once: emit the more *reliable* decoder's characters and drop
    ///    the other's. Reliability is an EMA of agreement fraction, so the
    ///    decoder whose output is regularly corroborated wins — NOT the one
    ///    that produces the most characters (in noise the hallucinating
    ///    decoder produces more, not better, output).
    /// 3. **Solo output:** if only one decoder produced anything (the other
    ///    queue stayed empty past the window), emit it — a silent decoder
    ///    casts no vote against a producing one.
    private func flushMergeWindow() {
        // Phase 1: emit head-to-head agreements immediately.
        while let c = classicPending.first, let b = bayesianPending.first,
              c.character == b.character,
              abs(c.timestamp - b.timestamp) <= mergeWindowSamples {
            classicPending.removeFirst()
            bayesianPending.removeFirst()
            onCharacterDecoded?(c.character, c.frequency)
            credit(&classicReliability, hit: true)
            credit(&bayesianReliability, hit: true)
        }

        // Phase 2: resolve expired disagreements.
        let cutoff = sampleClock - mergeWindowSamples
        let classicExpired = classicPending.prefix { $0.timestamp <= cutoff }
        let bayesianExpired = bayesianPending.prefix { $0.timestamp <= cutoff }
        guard !classicExpired.isEmpty || !bayesianExpired.isEmpty else { return }

        if classicExpired.isEmpty {
            // Bayesian-only output: emit it, no penalty for the silent side.
            for char in bayesianExpired { onCharacterDecoded?(char.character, char.frequency) }
            bayesianPending.removeFirst(bayesianExpired.count)
        } else if bayesianExpired.isEmpty {
            for char in classicExpired { onCharacterDecoded?(char.character, char.frequency) }
            classicPending.removeFirst(classicExpired.count)
        } else {
            // True disagreement: align the two runs and emit the merged
            // reading instead of winner-take-all — a single inserted
            // character used to forfeit the whole region.
            resolveDisagreement(Array(classicExpired), Array(bayesianExpired))
            classicPending.removeFirst(classicExpired.count)
            bayesianPending.removeFirst(bayesianExpired.count)

            // The resolved region may have desynchronized the heads; retry
            // agreement immediately so a match right after the region isn't
            // forced to wait out another window.
            flushAgreementsAfterResolve()
        }
    }

    /// Merge two disagreement runs via longest-common-subsequence
    /// alignment: characters both decoders produced (possibly at
    /// different positions) are corroborated and always emitted, in
    /// order; the divergent stretches between them go to whichever
    /// decoder is currently more reliable. Recovers the agreeing
    /// majority of a region that one stray insertion used to forfeit.
    private func resolveDisagreement(_ classicRun: [TimedChar], _ bayesianRun: [TimedChar]) {
        let a = classicRun.map(\.character)
        let b = bayesianRun.map(\.character)
        var dp = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1),
                         count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j]
                    ? dp[i + 1][j + 1] + 1
                    : max(dp[i + 1][j], dp[i][j + 1])
            }
        }

        let preferClassic = classicReliability >= bayesianReliability
        var divergentClassic: [TimedChar] = []
        var divergentBayesian: [TimedChar] = []

        func emitDivergent() {
            guard !divergentClassic.isEmpty || !divergentBayesian.isEmpty else { return }
            let winner = preferClassic ? divergentClassic : divergentBayesian
            for ch in winner { onCharacterDecoded?(ch.character, ch.frequency) }
            credit(&classicReliability, hit: preferClassic)
            credit(&bayesianReliability, hit: !preferClassic)
            divergentClassic.removeAll()
            divergentBayesian.removeAll()
        }

        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                emitDivergent()
                onCharacterDecoded?(classicRun[i].character, classicRun[i].frequency)
                credit(&classicReliability, hit: true)
                credit(&bayesianReliability, hit: true)
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                divergentClassic.append(classicRun[i])
                i += 1
            } else {
                divergentBayesian.append(bayesianRun[j])
                j += 1
            }
        }
        divergentClassic.append(contentsOf: classicRun[i...])
        divergentBayesian.append(contentsOf: bayesianRun[j...])
        emitDivergent()
    }

    private func flushAgreementsAfterResolve() {
        while let c = classicPending.first, let b = bayesianPending.first,
              c.character == b.character,
              abs(c.timestamp - b.timestamp) <= mergeWindowSamples {
            classicPending.removeFirst()
            bayesianPending.removeFirst()
            onCharacterDecoded?(c.character, c.frequency)
            credit(&classicReliability, hit: true)
            credit(&bayesianReliability, hit: true)
        }
    }

    private func credit(_ reliability: inout Double, hit: Bool) {
        reliability = reliability * (1 - reliabilityAlpha) + (hit ? reliabilityAlpha : 0)
    }

    // MARK: - Control

    /// Resolve all pending characters immediately (end of stream). During
    /// continuous operation the merge window handles this; call flush() when
    /// no more audio will arrive so trailing characters aren't stranded.
    public func flush() {
        // Give copy still held in emission probation its last-chance
        // structural check before resolving the merge window.
        classicDecoder.flushPending()
        bayesianDecoder.flushPending()
        flushAgreementsAfterResolve()
        guard !classicPending.isEmpty || !bayesianPending.isEmpty else { return }

        if classicPending.isEmpty {
            for ch in bayesianPending { onCharacterDecoded?(ch.character, ch.frequency) }
        } else if bayesianPending.isEmpty {
            for ch in classicPending { onCharacterDecoded?(ch.character, ch.frequency) }
        } else {
            resolveDisagreement(classicPending, bayesianPending)
        }
        classicPending.removeAll()
        bayesianPending.removeAll()
    }

    /// Preserve both sub-decoders' calibration across a transmit gap.
    /// Pending characters were decoded before the gap and are emitted
    /// (via flush) rather than dropped.
    public func resynchronize() {
        flush()
        classicDecoder.resynchronize()
        bayesianDecoder.resynchronize()
    }

    public func reset() {
        classicDecoder.reset()
        bayesianDecoder.reset()
        classicPending.removeAll()
        bayesianPending.removeAll()
        sampleClock = 0
        classicReliability = 0.60
        bayesianReliability = 0.50
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
