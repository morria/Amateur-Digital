//
//  DualRTTYDecoder.swift
//  AmateurDigitalCore
//
//  Multi-decoder diversity for RTTY: runs Classic (FSKDemodulator with W7AY ATC)
//  and Selective (2Tone-style independent tone thresholds) decoders in parallel,
//  merging output using adaptive selection.
//
//  Modeled after the N1MM+ approach where contest operators run MMTTY + 2Tone
//  simultaneously. The classic correlator excels at strong signals and frequency
//  drift, while the selective decoder handles selective fading better.
//
//  Strategy:
//  - Feed the same audio to both decoders simultaneously
//  - Track recent output rate from each decoder
//  - Matching characters emitted immediately (high confidence)
//  - Disagreements resolved by the decoder with higher recent output rate
//

import Foundation

/// Delegate protocol for receiving characters from the dual RTTY decoder.
public protocol DualRTTYDecoderDelegate: AnyObject {
    func dualDecoder(_ decoder: DualRTTYDecoder, didDecode character: Character, atFrequency frequency: Double)
    func dualDecoder(_ decoder: DualRTTYDecoder, signalDetected detected: Bool, atFrequency frequency: Double)
}

/// Diversity RTTY decoder that runs FSKDemodulator and SelectiveRTTYDecoder in parallel.
public final class DualRTTYDecoder {

    // MARK: - Sub-Decoders

    private let classicDecoder: FSKDemodulator
    private let selectiveDecoder: SelectiveRTTYDecoder

    // MARK: - Delegate

    public weak var delegate: DualRTTYDecoderDelegate?

    // MARK: - Merge State

    private struct TimedChar {
        let character: Character
        let frequency: Double
        let timestamp: Int
    }

    private var classicPending: [TimedChar] = []
    private var selectivePending: [TimedChar] = []

    /// Block counter (incremented per process call)
    private var blockCounter: Int = 0

    /// Merge window in process() calls.
    /// RTTY at 45.45 baud: one character = 7.5 bits = ~165ms.
    /// With 4096-sample buffers at 48kHz (~85ms per call), 3 blocks = ~255ms.
    private let mergeWindowBlocks: Int = 3

    /// Recent character counts for adaptive selection
    private var classicRecentCount: Int = 0
    private var selectiveRecentCount: Int = 0
    private var decayCounter: Int = 0
    private let decayInterval: Int = 20

    // MARK: - Public Properties

    public var signalDetected: Bool {
        classicDecoder.signalDetected || selectiveDecoder.signalDetected
    }

    public var signalStrength: Float {
        max(classicDecoder.signalStrength, selectiveDecoder.signalStrength)
    }

    public var centerFrequency: Double {
        classicDecoder.centerFrequency
    }

    /// Manual squelch level (0 = adaptive)
    public var squelchLevel: Float = 0 {
        didSet {
            classicDecoder.squelchLevel = squelchLevel
            selectiveDecoder.squelchLevel = squelchLevel
        }
    }

    /// Polarity inversion
    public var polarityInverted: Bool = false {
        didSet {
            classicDecoder.polarityInverted = polarityInverted
            selectiveDecoder.polarityInverted = polarityInverted
        }
    }

    // MARK: - Initialization

    public init(configuration: RTTYConfiguration = .standard) {
        self.classicDecoder = FSKDemodulator(configuration: configuration)
        self.selectiveDecoder = SelectiveRTTYDecoder(configuration: configuration)

        // Wire up classic decoder via delegate adapter
        classicDecoder.delegate = classicAdapter
        classicAdapter.owner = self

        // Wire up selective decoder via delegate adapter
        selectiveDecoder.delegate = selectiveAdapter
        selectiveAdapter.owner = self
    }

    private let classicAdapter = ClassicAdapter()
    private let selectiveAdapter = SelectiveAdapter()

    // MARK: - Processing

    public func process(samples: [Float]) {
        blockCounter += 1

        // Feed audio to both decoders simultaneously
        classicDecoder.process(samples: samples)
        selectiveDecoder.process(samples: samples)

        // Merge pending characters
        flushMergeWindow()

        // Periodic decay of recent counts
        decayCounter += 1
        if decayCounter >= decayInterval {
            decayCounter = 0
            classicRecentCount = classicRecentCount / 2
            selectiveRecentCount = selectiveRecentCount / 2
        }
    }

    // MARK: - Character Callbacks from Sub-Decoders

    fileprivate func onClassicCharacter(_ character: Character, frequency: Double) {
        classicPending.append(TimedChar(character: character, frequency: frequency, timestamp: blockCounter))
        classicRecentCount += 1
    }

    fileprivate func onSelectiveCharacter(_ character: Character, frequency: Double) {
        selectivePending.append(TimedChar(character: character, frequency: frequency, timestamp: blockCounter))
        selectiveRecentCount += 1
    }

    fileprivate func onSignalChanged() {
        delegate?.dualDecoder(self, signalDetected: signalDetected, atFrequency: centerFrequency)
    }

    // MARK: - Merge Logic

    private func flushMergeWindow() {
        let cutoff = blockCounter - mergeWindowBlocks

        // First pass: find matching characters (agreement)
        var classicConsumed = Set<Int>()
        var selectiveConsumed = Set<Int>()

        for (ci, classic) in classicPending.enumerated() {
            for (si, selective) in selectivePending.enumerated() {
                if selectiveConsumed.contains(si) { continue }
                if classic.character == selective.character &&
                   abs(classic.timestamp - selective.timestamp) <= mergeWindowBlocks {
                    delegate?.dualDecoder(self, didDecode: classic.character, atFrequency: classic.frequency)
                    classicConsumed.insert(ci)
                    selectiveConsumed.insert(si)
                    break
                }
            }
        }

        // Remove consumed
        classicPending = classicPending.enumerated()
            .filter { !classicConsumed.contains($0.offset) }
            .map { $0.element }
        selectivePending = selectivePending.enumerated()
            .filter { !selectiveConsumed.contains($0.offset) }
            .map { $0.element }

        // Second pass: emit expired from preferred decoder
        let classicExpired = classicPending.filter { $0.timestamp <= cutoff }
        let selectiveExpired = selectivePending.filter { $0.timestamp <= cutoff }

        let preferClassic = classicRecentCount >= selectiveRecentCount

        if preferClassic {
            for char in classicExpired {
                delegate?.dualDecoder(self, didDecode: char.character, atFrequency: char.frequency)
            }
        } else {
            for char in selectiveExpired {
                delegate?.dualDecoder(self, didDecode: char.character, atFrequency: char.frequency)
            }
        }

        classicPending.removeAll { $0.timestamp <= cutoff }
        selectivePending.removeAll { $0.timestamp <= cutoff }
    }

    // MARK: - Control

    public func reset() {
        classicDecoder.reset()
        selectiveDecoder.reset()
        classicPending.removeAll()
        selectivePending.removeAll()
        classicRecentCount = 0
        selectiveRecentCount = 0
        blockCounter = 0
        decayCounter = 0
    }

    public func tune(to frequency: Double) {
        classicDecoder.tune(to: frequency)
        selectiveDecoder.tune(to: frequency)
        reset()
    }

    /// Current Baudot shift state (from whichever decoder is preferred)
    public var currentShiftState: BaudotCodec.ShiftState {
        if classicRecentCount >= selectiveRecentCount {
            return classicDecoder.currentShiftState
        } else {
            return selectiveDecoder.currentShiftState
        }
    }
}

// MARK: - Convenience

extension DualRTTYDecoder {
    /// Create a dual decoder centered at a specific frequency.
    public static func withCenterFrequency(_ centerFrequency: Double, baseConfiguration: RTTYConfiguration = .standard) -> DualRTTYDecoder {
        DualRTTYDecoder(configuration: baseConfiguration.withCenterFrequency(centerFrequency))
    }
}

// MARK: - Delegate Adapters

private class ClassicAdapter: FSKDemodulatorDelegate {
    weak var owner: DualRTTYDecoder?

    func demodulator(_ demodulator: FSKDemodulator, didDecode character: Character, atFrequency frequency: Double) {
        owner?.onClassicCharacter(character, frequency: frequency)
    }

    func demodulator(_ demodulator: FSKDemodulator, signalDetected detected: Bool, atFrequency frequency: Double) {
        owner?.onSignalChanged()
    }
}

private class SelectiveAdapter: SelectiveRTTYDecoderDelegate {
    weak var owner: DualRTTYDecoder?

    func selectiveDecoder(_ decoder: SelectiveRTTYDecoder, didDecode character: Character, atFrequency frequency: Double) {
        owner?.onSelectiveCharacter(character, frequency: frequency)
    }

    func selectiveDecoder(_ decoder: SelectiveRTTYDecoder, signalDetected detected: Bool, atFrequency frequency: Double) {
        owner?.onSignalChanged()
    }
}
