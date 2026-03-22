//
//  SpectralAnalyzer.swift
//  AmateurDigitalCore
//
//  Extracts spectral features from audio for mode classification.
//  Uses Accelerate vDSP for efficient FFT computation.
//

import Foundation
import Accelerate

/// Spectral features extracted from an audio signal, used for mode classification.
public struct SpectralFeatures {
    /// Power spectrum bins (linear scale), one per frequency bin up to Nyquist
    public let powerBins: [Float]

    /// Frequency resolution: Hz per bin
    public let binWidth: Double

    /// Sample rate of the analyzed audio
    public let sampleRate: Double

    /// Number of FFT windows averaged
    public let windowCount: Int

    /// Estimated noise floor (median power in 300–3500 Hz range)
    public let noiseFloor: Float

    /// Peaks detected above the noise floor, sorted by power descending
    public let peaks: [SpectralPeak]

    /// Occupied bandwidth in Hz (contiguous region >6 dB above noise floor)
    public let occupiedBandwidth: Double

    /// Center frequency of the occupied bandwidth
    public let occupiedCenter: Double

    /// Spectral flatness (0 = tonal, 1 = white noise) in the occupied band
    public let spectralFlatness: Float

    /// Detected mark/space pairs consistent with FSK (170 Hz shift)
    public let fskPairs: [FSKPair]

    /// Amplitude envelope statistics (computed from time domain)
    public let envelopeStats: EnvelopeStats

    /// Estimated symbol rate in baud (0 if no clear rate detected).
    /// Computed via cyclostationary analysis (squared-envelope FFT).
    /// Known rates: RTTY=45.45, PSK31=31.25, BPSK63=62.5, JS8Call=6.25
    public let estimatedBaudRate: Double

    /// Confidence of the baud rate estimate (0.0–1.0)
    public let baudRateConfidence: Float
}

/// A detected spectral peak.
public struct SpectralPeak: Comparable {
    /// Frequency of the peak in Hz
    public let frequency: Double

    /// Power in dB above noise floor
    public let powerAboveNoise: Float

    /// Raw linear power
    public let power: Float

    /// 3 dB bandwidth of the peak in Hz
    public let bandwidth3dB: Double

    public static func < (lhs: SpectralPeak, rhs: SpectralPeak) -> Bool {
        lhs.powerAboveNoise < rhs.powerAboveNoise
    }
}

/// A detected FSK mark/space frequency pair.
public struct FSKPair {
    /// Mark (higher) frequency in Hz
    public let markFreq: Double

    /// Space (lower) frequency in Hz
    public let spaceFreq: Double

    /// Frequency shift in Hz
    public let shift: Double

    /// Combined power score (geometric mean of mark and space power)
    public let score: Float

    /// Whether there is a spectral valley between mark and space
    public let hasValley: Bool
}

/// Statistics of the amplitude envelope (time domain).
public struct EnvelopeStats {
    /// Coefficient of variation (stdDev / mean) of the envelope.
    /// High (>0.5) for OOK signals like CW, low (<0.2) for constant-envelope signals.
    public let coefficientOfVariation: Float

    /// Fraction of time the signal is "on" (above adaptive threshold)
    public let dutyCycle: Float

    /// Standard deviation of the envelope
    public let stdDev: Float

    /// Number of on/off transitions per second
    public let transitionRate: Float

    /// Whether on-off keying was detected
    public let hasOnOffKeying: Bool
}

/// Extracts spectral features from audio samples for mode detection.
public struct SpectralAnalyzer {

    /// FFT size (number of samples per window)
    public let fftSize: Int

    /// Sample rate in Hz
    public let sampleRate: Double

    /// Minimum frequency to analyze (Hz)
    public let minFreq: Double

    /// Maximum frequency to analyze (Hz)
    public let maxFreq: Double

    public init(
        fftSize: Int = 8192,
        sampleRate: Double = 48000,
        minFreq: Double = 200,
        maxFreq: Double = 4000
    ) {
        self.fftSize = FFTProcessor.nextPow2(fftSize)
        self.sampleRate = sampleRate
        self.minFreq = minFreq
        self.maxFreq = maxFreq
    }

    /// Analyze audio samples and extract spectral features.
    /// - Parameter samples: Audio samples (mono, Float, at `sampleRate`)
    /// - Returns: Extracted spectral features
    public func analyze(_ samples: [Float]) -> SpectralFeatures {
        let (bins, binWidth, windowCount) = computePowerSpectrum(samples)
        let noiseFloor = estimateNoiseFloor(bins: bins, binWidth: binWidth)
        let peaks = findPeaks(bins: bins, binWidth: binWidth, noiseFloor: noiseFloor)
        let fskPairs = findFSKPairs(bins: bins, binWidth: binWidth, noiseFloor: noiseFloor)
        let (bandwidth, center) = measureOccupiedBandwidth(bins: bins, binWidth: binWidth, noiseFloor: noiseFloor)
        let flatness = computeSpectralFlatness(bins: bins, binWidth: binWidth, center: center, bandwidth: bandwidth)
        let envelopeStats = analyzeEnvelope(samples)
        let (baudRate, baudConf) = estimateBaudRate(samples)

        return SpectralFeatures(
            powerBins: bins,
            binWidth: binWidth,
            sampleRate: sampleRate,
            windowCount: windowCount,
            noiseFloor: noiseFloor,
            peaks: peaks,
            occupiedBandwidth: bandwidth,
            occupiedCenter: center,
            spectralFlatness: flatness,
            fskPairs: fskPairs,
            envelopeStats: envelopeStats,
            estimatedBaudRate: baudRate,
            baudRateConfidence: baudConf
        )
    }

    // MARK: - Power Spectrum (vDSP)

    private func computePowerSpectrum(_ samples: [Float]) -> (bins: [Float], binWidth: Double, windowCount: Int) {
        let halfN = fftSize / 2
        let log2n = vDSP_Length(log2(Float(fftSize)))

        guard samples.count >= fftSize,
              let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return ([Float](repeating: 0, count: halfN), sampleRate / Double(fftSize), 0)
        }
        defer { vDSP_destroy_fftsetup(setup) }

        // Hann window
        var window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))

        var accumulated = [Float](repeating: 0, count: halfN)
        var windowCount = 0
        let hop = fftSize / 2

        var windowed = [Float](repeating: 0, count: fftSize)
        var realp = [Float](repeating: 0, count: halfN)
        var imagp = [Float](repeating: 0, count: halfN)

        var offset = 0
        while offset + fftSize <= samples.count {
            vDSP_vmul(Array(samples[offset..<offset + fftSize]), 1, window, 1, &windowed, 1, vDSP_Length(fftSize))

            for i in 0..<halfN {
                realp[i] = windowed[2 * i]
                imagp[i] = windowed[2 * i + 1]
            }

            realp.withUnsafeMutableBufferPointer { rBuf in
                imagp.withUnsafeMutableBufferPointer { iBuf in
                    var split = DSPSplitComplex(realp: rBuf.baseAddress!, imagp: iBuf.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                    for k in 0..<halfN {
                        accumulated[k] += rBuf[k] * rBuf[k] + iBuf[k] * iBuf[k]
                    }
                }
            }

            windowCount += 1
            offset += hop
        }

        if windowCount > 0 {
            var scale = 1.0 / Float(windowCount)
            vDSP_vsmul(accumulated, 1, &scale, &accumulated, 1, vDSP_Length(halfN))
        }

        return (accumulated, sampleRate / Double(fftSize), windowCount)
    }

    // MARK: - Noise Floor

    private func estimateNoiseFloor(bins: [Float], binWidth: Double) -> Float {
        let minBin = max(0, Int(ceil(minFreq / binWidth)))
        let maxBin = min(bins.count - 1, Int(floor(maxFreq / binWidth)))
        guard minBin < maxBin else { return 0 }

        let range = Array(bins[minBin...maxBin]).sorted()
        return range[range.count / 2] // median
    }

    // MARK: - Peak Detection

    private func findPeaks(bins: [Float], binWidth: Double, noiseFloor: Float) -> [SpectralPeak] {
        let minBin = max(1, Int(ceil(minFreq / binWidth)))
        let maxBin = min(bins.count - 2, Int(floor(maxFreq / binWidth)))
        guard minBin < maxBin else { return [] }

        let threshold = noiseFloor * 3.16 // ~5 dB above noise

        var peaks: [SpectralPeak] = []

        for bin in (minBin + 1)..<maxBin {
            guard bins[bin] > bins[bin - 1] && bins[bin] > bins[bin + 1] && bins[bin] > threshold else {
                continue
            }

            let freq = Double(bin) * binWidth
            let powerDB: Float = bins[bin] > 0 ? 10 * log10(bins[bin] / max(noiseFloor, 1e-10)) : -100
            let bw3dB = measure3dBBandwidth(bins: bins, peakBin: bin, binWidth: binWidth)

            peaks.append(SpectralPeak(
                frequency: freq,
                powerAboveNoise: powerDB,
                power: bins[bin],
                bandwidth3dB: bw3dB
            ))
        }

        // Sort by power descending, deduplicate within 20 Hz
        peaks.sort { $0.powerAboveNoise > $1.powerAboveNoise }
        var deduplicated: [SpectralPeak] = []
        for peak in peaks {
            if deduplicated.allSatisfy({ abs($0.frequency - peak.frequency) > 20 }) {
                deduplicated.append(peak)
            }
            if deduplicated.count >= 20 { break }
        }

        return deduplicated
    }

    private func measure3dBBandwidth(bins: [Float], peakBin: Int, binWidth: Double) -> Double {
        let halfPower = bins[peakBin] * 0.5
        var lo = peakBin
        while lo > 0 && bins[lo] > halfPower { lo -= 1 }
        var hi = peakBin
        while hi < bins.count - 1 && bins[hi] > halfPower { hi += 1 }
        return Double(hi - lo) * binWidth
    }

    // MARK: - FSK Pair Detection

    private func findFSKPairs(bins: [Float], binWidth: Double, noiseFloor: Float) -> [FSKPair] {
        var results: [FSKPair] = []

        // Check standard RTTY shifts: 170, 200, 425, 850 Hz
        for shift in [170.0, 200.0, 425.0, 850.0] {
            let pairs = findPairsForShift(bins: bins, binWidth: binWidth, noiseFloor: noiseFloor, shift: shift)
            results.append(contentsOf: pairs)
        }

        results.sort { $0.score > $1.score }
        return results
    }

    private func findPairsForShift(bins: [Float], binWidth: Double, noiseFloor: Float, shift: Double) -> [FSKPair] {
        let shiftBins = Int(round(shift / binWidth))
        let minBin = max(shiftBins, Int(ceil(minFreq / binWidth)))
        let maxBin = min(bins.count - 1, Int(floor(maxFreq / binWidth)))
        guard minBin < maxBin else { return [] }

        let threshold = noiseFloor * 10 // ~10 dB above noise

        var candidates: [(markFreq: Double, spaceFreq: Double, score: Float, hasValley: Bool)] = []

        for markBin in minBin...maxBin {
            let spaceBin = markBin - shiftBins
            guard spaceBin >= 0 else { continue }

            let markPower = bins[markBin]
            let spacePower = bins[spaceBin]
            guard markPower > threshold && spacePower > threshold else { continue }

            let score = sqrt(markPower * spacePower)

            // Check for spectral valley between mark and space
            var hasValley = true
            if markBin > spaceBin + 4 {
                var valley: Float = .infinity
                for b in (spaceBin + 2)..<(markBin - 1) {
                    valley = min(valley, bins[b])
                }
                if valley < .infinity {
                    let peakPower = min(markPower, spacePower)
                    hasValley = peakPower > valley * 4 // 6 dB contrast
                }
            }

            let markFreq = Double(markBin) * binWidth
            let spaceFreq = Double(spaceBin) * binWidth
            candidates.append((markFreq, spaceFreq, score, hasValley))
        }

        candidates.sort { $0.score > $1.score }

        // Deduplicate within shift distance
        let dedupeDistance = max(50, shift * 0.6)
        var result: [FSKPair] = []
        for c in candidates {
            if result.allSatisfy({ abs($0.markFreq - c.markFreq) > dedupeDistance }) {
                result.append(FSKPair(
                    markFreq: c.markFreq, spaceFreq: c.spaceFreq,
                    shift: shift, score: c.score, hasValley: c.hasValley
                ))
            }
            if result.count >= 3 { break }
        }

        return result
    }

    // MARK: - Occupied Bandwidth

    private func measureOccupiedBandwidth(bins: [Float], binWidth: Double, noiseFloor: Float) -> (bandwidth: Double, center: Double) {
        let minBin = max(0, Int(ceil(minFreq / binWidth)))
        let maxBin = min(bins.count - 1, Int(floor(maxFreq / binWidth)))
        guard minBin < maxBin else { return (0, 0) }

        let threshold = noiseFloor * 4 // ~6 dB above noise

        // Find the contiguous region with the most energy above threshold
        var bestStart = minBin
        var bestEnd = minBin
        var bestEnergy: Float = 0

        var curStart = -1
        var curEnergy: Float = 0

        for bin in minBin...maxBin {
            if bins[bin] > threshold {
                if curStart < 0 { curStart = bin }
                curEnergy += bins[bin]
            } else {
                if curStart >= 0 && curEnergy > bestEnergy {
                    bestStart = curStart
                    bestEnd = bin - 1
                    bestEnergy = curEnergy
                }
                curStart = -1
                curEnergy = 0
            }
        }
        if curStart >= 0 && curEnergy > bestEnergy {
            bestStart = curStart
            bestEnd = maxBin
        }

        let bandwidth = Double(bestEnd - bestStart) * binWidth
        let center = Double(bestStart + bestEnd) / 2.0 * binWidth

        return (bandwidth, center)
    }

    // MARK: - Spectral Flatness

    private func computeSpectralFlatness(bins: [Float], binWidth: Double, center: Double, bandwidth: Double) -> Float {
        guard bandwidth > 10 else { return 0 }

        let loFreq = center - bandwidth / 2
        let hiFreq = center + bandwidth / 2
        let loBin = max(0, Int(ceil(loFreq / binWidth)))
        let hiBin = min(bins.count - 1, Int(floor(hiFreq / binWidth)))
        guard loBin < hiBin else { return 0 }

        let count = hiBin - loBin + 1
        guard count > 1 else { return 0 }

        // Geometric mean / arithmetic mean (in log domain for stability)
        var logSum: Double = 0
        var linSum: Double = 0
        var validCount = 0

        for bin in loBin...hiBin {
            let v = max(Double(bins[bin]), 1e-20)
            logSum += log(v)
            linSum += v
            validCount += 1
        }

        guard validCount > 0, linSum > 0 else { return 0 }

        let geometricMean = exp(logSum / Double(validCount))
        let arithmeticMean = linSum / Double(validCount)

        return Float(geometricMean / arithmeticMean)
    }

    // MARK: - Baud Rate Estimation (Cyclostationary Analysis)

    /// Estimate the symbol rate by squaring the signal envelope and taking the FFT.
    /// Digital signals exhibit periodicity at the symbol rate in the squared envelope.
    /// Returns (baudRate, confidence) where confidence is the peak's SNR in the cyclic spectrum.
    private func estimateBaudRate(_ samples: [Float]) -> (Double, Float) {
        guard samples.count >= 4096 else { return (0, 0) }

        // Compute the squared envelope in short blocks (1 ms)
        let envBlockSize = Int(sampleRate / 1000) // 48 samples at 48 kHz
        guard envBlockSize > 0 else { return (0, 0) }
        let numEnvBlocks = samples.count / envBlockSize
        guard numEnvBlocks >= 64 else { return (0, 0) }

        var envelope = [Float](repeating: 0, count: numEnvBlocks)
        for i in 0..<numEnvBlocks {
            let start = i * envBlockSize
            var rms: Float = 0
            for j in 0..<envBlockSize {
                let s = samples[start + j]
                rms += s * s
            }
            envelope[i] = rms / Float(envBlockSize) // squared envelope (power)
        }

        // FFT of squared envelope to find cyclic frequencies
        let fftN = FFTProcessor.nextPow2(numEnvBlocks)
        var real = [Double](repeating: 0, count: fftN)
        var imag = [Double](repeating: 0, count: fftN)
        for i in 0..<numEnvBlocks {
            real[i] = Double(envelope[i])
        }
        FFTProcessor.fft(&real, &imag)

        // Compute power spectrum of the cyclic frequencies
        let halfN = fftN / 2
        let envSampleRate = sampleRate / Double(envBlockSize) // 1000 Hz for 1ms blocks
        let cyclicBinWidth = envSampleRate / Double(fftN)

        // Search for peaks near known baud rates
        let knownRates: [(name: String, rate: Double)] = [
            ("JS8Call", 6.25),
            ("PSK31", 31.25),
            ("RTTY", 45.45),
            ("BPSK63", 62.5),
            ("RTTY75", 75.0),
            ("RTTY100", 100.0),
        ]

        // Compute local noise floor (median power in cyclic spectrum)
        var allPowers = [Double]()
        for bin in 2..<halfN {
            allPowers.append(real[bin] * real[bin] + imag[bin] * imag[bin])
        }
        allPowers.sort()
        let medianNoise = allPowers.isEmpty ? 1.0 : allPowers[allPowers.count / 2]

        // Measure SNR for each known rate against the local noise floor
        struct RateCandidate {
            let rate: Double
            let snr: Double
        }
        var candidates: [RateCandidate] = []

        for (_, rate) in knownRates {
            let bin = Int(round(rate / cyclicBinWidth))
            guard bin > 0 && bin < halfN else { continue }

            var peakPower: Double = 0
            for b in max(1, bin - 1)...min(halfN - 1, bin + 1) {
                let p = real[b] * real[b] + imag[b] * imag[b]
                if p > peakPower { peakPower = p }
            }

            let snr = medianNoise > 0 ? peakPower / medianNoise : 0
            candidates.append(RateCandidate(rate: rate, snr: snr))
        }

        // Pick the rate with highest SNR, but prefer higher rates over their subharmonics.
        // 6.25 is a subharmonic of 31.25, 45.45, 62.5 — if any of those also has
        // significant power (SNR > 3), prefer the higher rate.
        candidates.sort { $0.snr > $1.snr }
        var bestRate = candidates.first?.rate ?? 0
        let bestSNR = candidates.first?.snr ?? 0

        if bestRate == 6.25 && bestSNR > 0 {
            // 6.25 is a subharmonic of 31.25, 45.45, 62.5.
            // Only prefer a higher rate if it has at least 50% of the 6.25 SNR.
            let threshold = bestSNR * 0.5
            for c in candidates where c.rate > 10 && c.snr > threshold {
                bestRate = c.rate
                break
            }
        }

        let confidence = min(1.0, max(0.0, Float(bestSNR - 1) / 10))
        return (confidence > 0.1 ? bestRate : 0, confidence)
    }

    // MARK: - Envelope Analysis

    private func analyzeEnvelope(_ samples: [Float]) -> EnvelopeStats {
        let defaultStats = EnvelopeStats(coefficientOfVariation: 0, dutyCycle: 1, stdDev: 0, transitionRate: 0, hasOnOffKeying: false)
        guard samples.count > 1000 else { return defaultStats }

        // Compute envelope using broadband RMS in 10 ms blocks
        let blockSize = Int(sampleRate / 100) // 10 ms blocks
        guard blockSize > 0 else { return defaultStats }

        let numBlocks = samples.count / blockSize
        guard numBlocks > 10 else { return defaultStats }

        var fullEnvelope = [Float](repeating: 0, count: numBlocks)
        for i in 0..<numBlocks {
            let start = i * blockSize
            var rms: Float = 0
            for j in 0..<blockSize {
                let s = samples[start + j]
                rms += s * s
            }
            fullEnvelope[i] = sqrt(rms / Float(blockSize))
        }

        // Trim leading/trailing silence to avoid biasing CV from zero-padded clips.
        // Find the peak envelope value, then trim blocks below 5% of peak from ends.
        let peakEnv = fullEnvelope.max() ?? 0
        let silenceThresh = peakEnv * 0.05
        var startBlock = 0
        while startBlock < numBlocks && fullEnvelope[startBlock] < silenceThresh { startBlock += 1 }
        var endBlock = numBlocks - 1
        while endBlock > startBlock && fullEnvelope[endBlock] < silenceThresh { endBlock -= 1 }

        // Use trimmed envelope if it's at least 10 blocks, otherwise use full
        let envelope: [Float]
        if endBlock - startBlock >= 10 {
            envelope = Array(fullEnvelope[startBlock...endBlock])
        } else {
            envelope = fullEnvelope
        }
        let activeBlocks = envelope.count

        // Statistics
        let mean = envelope.reduce(0, +) / Float(activeBlocks)
        guard mean > 1e-6 else {
            return EnvelopeStats(coefficientOfVariation: 0, dutyCycle: 0, stdDev: 0, transitionRate: 0, hasOnOffKeying: false)
        }

        var variance: Float = 0
        for v in envelope {
            let d = v - mean
            variance += d * d
        }
        variance /= Float(activeBlocks)
        let stdDev = sqrt(variance)

        // Coefficient of variation: high for OOK (CW swings 0 to peak), low for constant envelope (FSK/PSK)
        let cv = stdDev / mean

        // Adaptive threshold for on/off using Otsu-style: midpoint between sorted 25th and 75th percentiles
        let sorted = envelope.sorted()
        let q25 = sorted[activeBlocks / 4]
        let q75 = sorted[3 * activeBlocks / 4]
        let onThreshold = (q25 + q75) / 2

        let onCount = envelope.filter { $0 > onThreshold }.count
        let dutyCycle = Float(onCount) / Float(activeBlocks)

        // Count on/off transitions
        var transitions = 0
        var wasOn = envelope[0] > onThreshold
        for i in 1..<activeBlocks {
            let isOn = envelope[i] > onThreshold
            if isOn != wasOn { transitions += 1 }
            wasOn = isOn
        }
        // Use active duration (trimmed) for transition rate
        let activeDuration = Float(activeBlocks * blockSize) / Float(sampleRate)
        let transitionRate = activeDuration > 0 ? Float(transitions) / activeDuration : 0

        // OOK detection
        let p5 = sorted[max(0, activeBlocks / 20)]
        let p95 = sorted[min(activeBlocks - 1, 19 * activeBlocks / 20)]
        let silenceRatio = p95 > 0 ? p5 / p95 : 1.0

        // True OOK: bottom 5% is < 15% of top 5% (real silence during key-up)
        // PSK envelope dips: bottom 5% is > 20% of top 5% (never reaches silence)
        let hasTrueSilence = silenceRatio < 0.12

        // CW transition rates: 5 WPM ≈ 2/s, 60 WPM ≈ 24/s. Cap at 25/s to exclude
        // PSK beating artifacts which have 30-50 transitions/s.
        let hasOOK = cv > 0.4 && hasTrueSilence && dutyCycle > 0.15 && dutyCycle < 0.85
                   && transitionRate > 3 && transitionRate < 25

        return EnvelopeStats(
            coefficientOfVariation: cv,
            dutyCycle: dutyCycle,
            stdDev: stdDev,
            transitionRate: transitionRate,
            hasOnOffKeying: hasOOK
        )
    }
}
