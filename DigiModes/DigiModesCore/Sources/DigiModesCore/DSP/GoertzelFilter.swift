//
//  GoertzelFilter.swift
//  DigiModesCore
//
//  Goertzel algorithm for efficient single-frequency DFT
//  More efficient than FFT when detecting only a few frequencies
//

import Foundation

/// Goertzel filter for efficient single-frequency power detection
///
/// The Goertzel algorithm is a method for computing individual
/// terms of a DFT. It's more efficient than FFT when only a small
/// number of frequencies need to be detected, making it ideal for
/// FSK demodulation where we only need mark and space frequencies.
///
/// Usage:
/// ```swift
/// var filter = GoertzelFilter(frequency: 2125, sampleRate: 48000, blockSize: 256)
/// let power = filter.processBlock(samples)
/// ```
public struct GoertzelFilter {

    // MARK: - Configuration

    private let targetFrequency: Double
    private let sampleRate: Double
    private let blockSize: Int
    private let coefficient: Float

    // MARK: - State

    private var s0: Float = 0
    private var s1: Float = 0
    private var s2: Float = 0
    private var sampleCount: Int = 0

    // MARK: - Initialization

    /// Initialize a Goertzel filter for a specific frequency
    /// - Parameters:
    ///   - frequency: Target frequency to detect (Hz)
    ///   - sampleRate: Audio sample rate (Hz)
    ///   - blockSize: Number of samples per detection block.
    ///                Larger blocks = better frequency resolution, slower response.
    ///                Smaller blocks = faster response, less frequency selectivity.
    public init(frequency: Double, sampleRate: Double, blockSize: Int) {
        self.targetFrequency = frequency
        self.sampleRate = sampleRate
        self.blockSize = blockSize

        // Calculate coefficient: 2 * cos(2 * pi * k / N)
        // where k = (N * targetFrequency) / sampleRate
        let k = (Double(blockSize) * frequency) / sampleRate
        self.coefficient = Float(2.0 * cos(2.0 * .pi * k / Double(blockSize)))
    }

    // MARK: - Processing

    /// Process a single sample
    /// - Parameter sample: Input audio sample
    /// - Returns: Power at target frequency if block complete, nil otherwise
    public mutating func process(sample: Float) -> Float? {
        // Goertzel iteration: s0 = sample + coeff * s1 - s2
        s0 = sample + coefficient * s1 - s2
        s2 = s1
        s1 = s0
        sampleCount += 1

        if sampleCount >= blockSize {
            let power = calculatePower()
            reset()
            return power
        }
        return nil
    }

    /// Process a block of samples and return power
    /// - Parameter samples: Array of audio samples
    /// - Returns: Power at target frequency
    public mutating func processBlock(_ samples: [Float]) -> Float {
        reset()

        // Process all samples in block
        for sample in samples.prefix(blockSize) {
            s0 = sample + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }

        return calculatePower()
    }

    /// Process samples and return power without resetting
    /// Useful for sliding window analysis
    /// - Parameter samples: Array of audio samples
    /// - Returns: Power at target frequency
    public mutating func processSamples(_ samples: [Float]) -> Float? {
        for sample in samples {
            if let power = process(sample: sample) {
                return power
            }
        }
        return nil
    }

    // MARK: - Power Calculation

    /// Calculate power from current state
    /// Power = s1^2 + s2^2 - coeff * s1 * s2
    private func calculatePower() -> Float {
        return s1 * s1 + s2 * s2 - coefficient * s1 * s2
    }

    /// Calculate magnitude (sqrt of power)
    public func calculateMagnitude() -> Float {
        return sqrt(calculatePower())
    }

    // MARK: - Control

    /// Reset filter state
    public mutating func reset() {
        s0 = 0
        s1 = 0
        s2 = 0
        sampleCount = 0
    }

    /// Get the target frequency
    public var frequency: Double {
        targetFrequency
    }

    /// Get samples remaining until next power calculation
    public var samplesRemaining: Int {
        blockSize - sampleCount
    }

    /// Check if filter has a complete block ready
    public var isBlockComplete: Bool {
        sampleCount >= blockSize
    }
}

// MARK: - FSK Detection Helper

/// Pair of Goertzel filters for FSK mark/space detection
public struct FSKDetector {

    private var markFilter: GoertzelFilter
    private var spaceFilter: GoertzelFilter

    /// Create an FSK detector for mark and space frequencies
    /// - Parameters:
    ///   - markFrequency: Mark (logic 1) frequency in Hz
    ///   - spaceFrequency: Space (logic 0) frequency in Hz
    ///   - sampleRate: Audio sample rate
    ///   - blockSize: Samples per detection block
    public init(
        markFrequency: Double,
        spaceFrequency: Double,
        sampleRate: Double,
        blockSize: Int
    ) {
        self.markFilter = GoertzelFilter(
            frequency: markFrequency,
            sampleRate: sampleRate,
            blockSize: blockSize
        )
        self.spaceFilter = GoertzelFilter(
            frequency: spaceFrequency,
            sampleRate: sampleRate,
            blockSize: blockSize
        )
    }

    /// Process a block and return correlation value
    /// - Parameter samples: Audio samples
    /// - Returns: Correlation in range [-1, 1] where positive = mark, negative = space
    public mutating func processBlock(_ samples: [Float]) -> Float {
        let markPower = markFilter.processBlock(samples)
        let spacePower = spaceFilter.processBlock(samples)

        // Normalized correlation: (mark - space) / (mark + space)
        // Returns value in [-1, 1]
        let total = markPower + spacePower
        guard total > 0 else { return 0 }

        return (markPower - spacePower) / total
    }

    /// Get individual power values
    /// - Parameter samples: Audio samples
    /// - Returns: Tuple of (markPower, spacePower)
    public mutating func getPowers(_ samples: [Float]) -> (mark: Float, space: Float) {
        let markPower = markFilter.processBlock(samples)
        let spacePower = spaceFilter.processBlock(samples)
        return (markPower, spacePower)
    }

    /// Reset both filters
    public mutating func reset() {
        markFilter.reset()
        spaceFilter.reset()
    }
}
