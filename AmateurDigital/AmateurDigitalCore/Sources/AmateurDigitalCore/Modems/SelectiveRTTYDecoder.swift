//
//  SelectiveRTTYDecoder.swift
//  AmateurDigitalCore
//
//  2Tone-style selective RTTY decoder (G3YYD).
//
//  Processes mark and space tones through independent threshold circuits,
//  then combines decisions. Each tone has its own signal/noise estimate so
//  a deep fade on one tone does not corrupt the other's threshold.
//
//  Decision logic:
//    Mark on + Space off  → mark bit (1)
//    Mark off + Space on  → space bit (0)
//    Both on              → stronger tone wins
//    Both off             → no decision (gap / squelch)
//

import Foundation

/// Delegate for receiving characters from the selective decoder.
public protocol SelectiveRTTYDecoderDelegate: AnyObject {
    func selectiveDecoder(_ decoder: SelectiveRTTYDecoder, didDecode character: Character, atFrequency frequency: Double)
    func selectiveDecoder(_ decoder: SelectiveRTTYDecoder, signalDetected detected: Bool, atFrequency frequency: Double)
}

/// 2Tone-style selective RTTY decoder with independent per-tone thresholds.
public final class SelectiveRTTYDecoder {

    // MARK: - Configuration & Filters

    private var configuration: RTTYConfiguration
    private var markFilter: GoertzelFilter
    private var spaceFilter: GoertzelFilter
    private let baudotCodec: BaudotCodec
    private var bandpassFilter: BandpassFilter
    private var noiseFilterMid: GoertzelFilter

    private let stateStepSize: Int       // samplesPerBit / 4
    private let goertzelWindowSize: Int   // samplesPerBit / 2
    private var sampleBuffer: [Float] = []
    private var analysisWindow: [Float] = []

    // MARK: - Independent Tone Tracking (2Tone core)

    private var markSignalEnvelope: Float = 0
    private var spaceSignalEnvelope: Float = 0
    private var markNoiseFloor: Float = 0.001
    private var spaceNoiseFloor: Float = 0.001

    private let signalAttack: Float = 0.08, signalDecay: Float = 0.003
    private let noiseAttack: Float = 0.03,  noiseDecay: Float = 0.001
    private let thresholdMultiplier: Float = 3.0

    // MARK: - AGC

    private var agcGain: Float = 1.0
    private let agcTarget: Float = 0.5, agcAttack: Float = 0.01, agcDecay: Float = 0.0001

    // MARK: - State Machine & Squelch

    private var smoothedSpectralSNR: Float = 0
    public private(set) var state: DemodulatorState = .waitingForStart
    public weak var delegate: SelectiveRTTYDecoderDelegate?
    private var pendingCode: UInt8?, pendingConfidence: Float = 0
    private var correlationHistory: [Float] = []
    private var correlationHistorySize: Int { max(16, configuration.samplesPerBit / stateStepSize) }
    public var polarityInverted: Bool = false
    public var squelchLevel: Float = 0
    private var noiseFloor: Float = 0.1
    public var stopBitThreshold: Float = 0.05
    private var _signalDetected: Bool = false
    public var signalDetected: Bool { _signalDetected }

    public var signalStrength: Float {
        guard !correlationHistory.isEmpty else { return 0 }
        return correlationHistory.map { abs($0) }.reduce(0, +) / Float(correlationHistory.count)
    }
    public var centerFrequency: Double { configuration.markFrequency }

    // MARK: - Init

    public init(configuration: RTTYConfiguration = .standard) {
        self.configuration = configuration
        self.baudotCodec = BaudotCodec()
        self.stateStepSize = max(16, configuration.samplesPerBit / 4)
        self.goertzelWindowSize = max(64, configuration.samplesPerBit / 2)
        self.markFilter = GoertzelFilter(frequency: configuration.markFrequency, sampleRate: configuration.sampleRate, blockSize: goertzelWindowSize)
        self.spaceFilter = GoertzelFilter(frequency: configuration.spaceFrequency, sampleRate: configuration.sampleRate, blockSize: goertzelWindowSize)
        self.bandpassFilter = BandpassFilter(markFrequency: configuration.markFrequency, spaceFrequency: configuration.spaceFrequency, margin: 75.0, sampleRate: configuration.sampleRate)
        let midFreq = (configuration.markFrequency + configuration.spaceFrequency) / 2.0
        self.noiseFilterMid = GoertzelFilter(frequency: midFreq, sampleRate: configuration.sampleRate, blockSize: goertzelWindowSize)
    }

    // MARK: - Processing

    public func process(samples: [Float]) {
        for sample in samples {
            let filtered = bandpassFilter.process(sample)
            let agcSample = applyAGC(filtered)
            sampleBuffer.append(agcSample)
            analysisWindow.append(agcSample)
            if analysisWindow.count > goertzelWindowSize {
                analysisWindow.removeFirst(analysisWindow.count - goertzelWindowSize)
            }
            if sampleBuffer.count >= stateStepSize {
                let decision = analyzeBlock()
                updateCorrelationHistory(decision.correlation)
                updateNoiseFloor(decision.correlation)
                updateSignalDetection()
                processStateMachine(decision: decision)
                sampleBuffer.removeAll(keepingCapacity: true)
            }
        }
    }

    private func applyAGC(_ sample: Float) -> Float {
        let output = sample * agcGain
        if abs(output) > agcTarget { agcGain *= (1.0 - agcAttack) }
        else { agcGain *= (1.0 + agcDecay) }
        agcGain = max(0.1, min(10.0, agcGain))
        return output
    }

    // MARK: - Selective Tone Analysis (2Tone Core)

    private struct ToneDecision {
        let markOn: Bool, spaceOn: Bool
        let markPower: Float, spacePower: Float
        let correlation: Float, confidence: Float
    }

    /// Analyze the current window using independent tone thresholds.
    /// Each tone is compared against its own adaptive threshold so a deep
    /// fade on mark does not lower the space threshold (and vice versa).
    private func analyzeBlock() -> ToneDecision {
        let m = markFilter.processBlock(analysisWindow)
        let s = spaceFilter.processBlock(analysisWindow)
        let nMid = noiseFilterMid.processBlock(analysisWindow)
        markFilter.reset(); spaceFilter.reset(); noiseFilterMid.reset()

        // Spectral SNR for squelch
        smoothedSpectralSNR = smoothedSpectralSNR * 0.9 + (max(m, s) / max(nMid, 0.0001)) * 0.1

        // --- Independent mark envelope & noise tracking ---
        updateEnvelope(&markSignalEnvelope, power: m)
        updateToneNoiseFloor(&markNoiseFloor, power: m)

        // --- Independent space envelope & noise tracking ---
        updateEnvelope(&spaceSignalEnvelope, power: s)
        updateToneNoiseFloor(&spaceNoiseFloor, power: s)

        // Per-tone threshold decisions
        let markThreshold = markNoiseFloor * thresholdMultiplier
        let spaceThreshold = spaceNoiseFloor * thresholdMultiplier
        let markOn = m > markThreshold
        let spaceOn = s > spaceThreshold

        // Combine decisions into correlation [-1, +1]
        let correlation: Float
        let confidence: Float

        if markOn && !spaceOn {
            let ratio = m / max(markThreshold, 0.0001)
            confidence = min(1.0, (ratio - 1.0) / 2.0)
            correlation = confidence
        } else if spaceOn && !markOn {
            let ratio = s / max(spaceThreshold, 0.0001)
            confidence = min(1.0, (ratio - 1.0) / 2.0)
            correlation = -confidence
        } else if markOn && spaceOn {
            let total = m + s
            let rawCorr = total > 0.001 ? (m - s) / total : 0
            correlation = rawCorr
            confidence = abs(rawCorr) * 0.5
        } else {
            // Both off — weak correlation for start bit detection only
            let total = m + s
            correlation = total > 0.001 ? (m - s) / total * 0.2 : 0
            confidence = 0
        }

        let c = polarityInverted ? -correlation : correlation
        return ToneDecision(markOn: markOn, spaceOn: spaceOn, markPower: m, spacePower: s, correlation: c, confidence: confidence)
    }

    private func updateEnvelope(_ envelope: inout Float, power: Float) {
        let rate = power > envelope ? signalAttack : signalDecay
        envelope += (power - envelope) * rate
    }

    private func updateToneNoiseFloor(_ floor: inout Float, power: Float) {
        if power < floor {
            floor += (power - floor) * noiseAttack
        } else if power < floor * 2.0 {
            floor += (power - floor) * noiseDecay
        }
        floor = max(0.0001, floor)
    }

    // MARK: - State Machine

    private func processStateMachine(decision: ToneDecision) {
        let samplesPerStep = stateStepSize
        let samplesPerBit = configuration.samplesPerBit
        let bitSamplePoint = samplesPerBit * 3 / 4

        switch state {
        case .waitingForStart:
            if decision.correlation < -0.1 {
                state = .inStartBit(samplesProcessed: samplesPerStep)
            }

        case .inStartBit(let samplesProcessed):
            let newSamples = samplesProcessed + samplesPerStep
            if decision.correlation > 0.2 {
                state = .waitingForStart
            } else if newSamples >= samplesPerBit {
                state = .receivingData(bit: 0, samplesProcessed: 0, accumulator: 0, confidence: 1.0)
            } else {
                state = .inStartBit(samplesProcessed: newSamples)
            }

        case .receivingData(let bit, let samplesProcessed, var accumulator, var confidence):
            let newSamples = samplesProcessed + samplesPerStep
            if samplesProcessed < bitSamplePoint && newSamples >= bitSamplePoint {
                if decision.correlation > 0 { accumulator |= (1 << bit) }
                confidence = min(confidence, decision.confidence)
            }
            if newSamples >= samplesPerBit {
                if bit >= 4 {
                    state = .inStopBits(samplesProcessed: 0, markAccumulator: 0, sampleCount: 0)
                    pendingCode = accumulator; pendingConfidence = confidence
                } else {
                    state = .receivingData(bit: bit + 1, samplesProcessed: 0, accumulator: accumulator, confidence: confidence)
                }
            } else {
                state = .receivingData(bit: bit, samplesProcessed: newSamples, accumulator: accumulator, confidence: confidence)
            }

        case .inStopBits(let samplesProcessed, var markAccumulator, var sampleCount):
            let newSamples = samplesProcessed + samplesPerStep
            let stopBitSamples = Int(1.5 * Double(samplesPerBit))
            markAccumulator += decision.correlation; sampleCount += 1
            if newSamples >= stopBitSamples {
                let avg = sampleCount > 0 ? markAccumulator / Float(sampleCount) : 0
                if avg > stopBitThreshold, let code = pendingCode { decodeAndEmit(code, confidence: pendingConfidence) }
                pendingCode = nil; state = .waitingForStart
            } else {
                state = .inStopBits(samplesProcessed: newSamples, markAccumulator: markAccumulator, sampleCount: sampleCount)
            }
        }
    }

    // MARK: - Character Emission & Signal Detection

    private func decodeAndEmit(_ code: UInt8, confidence: Float) {
        let effectiveSquelch = squelchLevel > 0 ? squelchLevel : (noiseFloor * 3.0)
        guard signalStrength >= effectiveSquelch else { return }
        if goertzelWindowSize >= 400 { guard smoothedSpectralSNR > 2.2 else { return } }
        if let character = baudotCodec.decode(code) {
            delegate?.selectiveDecoder(self, didDecode: character, atFrequency: centerFrequency)
        }
    }

    private func updateCorrelationHistory(_ correlation: Float) {
        correlationHistory.append(correlation)
        while correlationHistory.count > correlationHistorySize { correlationHistory.removeFirst() }
    }

    private func updateNoiseFloor(_ correlation: Float) {
        let mag = abs(correlation)
        if mag < noiseFloor { noiseFloor = noiseFloor * 0.99 + mag * 0.01 }
        else if mag < noiseFloor * 2.0 { noiseFloor = noiseFloor * 0.999 + mag * 0.001 }
        noiseFloor = max(0.01, min(0.5, noiseFloor))
    }

    private func updateSignalDetection() {
        let effectiveSquelch = squelchLevel > 0 ? squelchLevel : (noiseFloor * 3.0)
        let newDetected = signalStrength > effectiveSquelch
        if newDetected != _signalDetected {
            _signalDetected = newDetected
            delegate?.selectiveDecoder(self, signalDetected: newDetected, atFrequency: centerFrequency)
        }
    }

    // MARK: - Control

    public func reset() {
        state = .waitingForStart
        sampleBuffer.removeAll(keepingCapacity: true)
        analysisWindow.removeAll(keepingCapacity: true)
        correlationHistory.removeAll(keepingCapacity: true)
        markFilter.reset(); spaceFilter.reset(); noiseFilterMid.reset()
        bandpassFilter.reset(); baudotCodec.reset()
        _signalDetected = false; agcGain = 1.0; noiseFloor = 0.1
        smoothedSpectralSNR = 0; pendingCode = nil; pendingConfidence = 0
        markSignalEnvelope = 0; spaceSignalEnvelope = 0
        markNoiseFloor = 0.001; spaceNoiseFloor = 0.001
    }

    public func tune(to frequency: Double) {
        configuration = configuration.withCenterFrequency(frequency)
        markFilter = GoertzelFilter(frequency: configuration.markFrequency, sampleRate: configuration.sampleRate, blockSize: goertzelWindowSize)
        spaceFilter = GoertzelFilter(frequency: configuration.spaceFrequency, sampleRate: configuration.sampleRate, blockSize: goertzelWindowSize)
        bandpassFilter = BandpassFilter(markFrequency: configuration.markFrequency, spaceFrequency: configuration.spaceFrequency, margin: 75.0, sampleRate: configuration.sampleRate)
        let midFreq = (configuration.markFrequency + configuration.spaceFrequency) / 2.0
        noiseFilterMid = GoertzelFilter(frequency: midFreq, sampleRate: configuration.sampleRate, blockSize: goertzelWindowSize)
        reset()
    }

    public var currentShiftState: BaudotCodec.ShiftState { baudotCodec.currentShift }
}

// MARK: - Convenience

extension SelectiveRTTYDecoder {
    public static func withCenterFrequency(_ centerFrequency: Double, baseConfiguration: RTTYConfiguration = .standard) -> SelectiveRTTYDecoder {
        SelectiveRTTYDecoder(configuration: baseConfiguration.withCenterFrequency(centerFrequency))
    }
}
