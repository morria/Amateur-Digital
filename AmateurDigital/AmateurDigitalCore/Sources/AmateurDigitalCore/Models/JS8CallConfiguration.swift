//
//  JS8CallConfiguration.swift
//  AmateurDigitalCore
//
//  Configuration for JS8Call submodes and protocol constants.
//

import Foundation

// MARK: - Protocol Constants

/// Constants shared across all JS8Call submodes.
public enum JS8CallConstants {
    public static let KK = 87            // Information bits (75 + CRC12)
    public static let ND = 58            // Data symbols
    public static let NS = 21            // Sync symbols (3 x Costas 7)
    public static let NN = NS + ND       // Total channel symbols (79)
    public static let N  = 174           // LDPC codeword length
    public static let K  = 87            // LDPC information length
    public static let M  = N - K         // LDPC parity checks (87)
    public static let internalSampleRate = 12000.0
    public static let externalSampleRate = 48000.0
    public static let decimationFactor = 4
    public static let asyncMin = 1.5     // Minimum sync metric for candidate acceptance
    public static let nfsrch = 5         // Fine frequency search range (integer, +/- nfsrch/2 Hz)
    public static let maxCandidates = 300

    /// 68-character alphabet used for raw frame payload.
    public static let alphabet: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-+/?.")
}

// MARK: - Costas Arrays

public enum JS8CallCostasType: Sendable, Equatable {
    case original   // Normal mode (backwards compat with early JS8Call)
    case modified   // Fast, Turbo, Slow, Ultra
}

public struct JS8CallCostasArrays: Sendable, Equatable {
    public let a: [Int]   // Beginning sync (symbols 0-6)
    public let b: [Int]   // Middle sync (symbols 36-42)
    public let c: [Int]   // End sync (symbols 72-78)

    public static let original = JS8CallCostasArrays(
        a: [4, 2, 5, 6, 1, 3, 0],
        b: [4, 2, 5, 6, 1, 3, 0],
        c: [4, 2, 5, 6, 1, 3, 0]
    )

    public static let modified = JS8CallCostasArrays(
        a: [0, 6, 2, 3, 5, 4, 1],
        b: [1, 5, 0, 2, 3, 6, 4],
        c: [2, 5, 0, 6, 4, 1, 3]
    )

    public static func forType(_ type: JS8CallCostasType) -> JS8CallCostasArrays {
        switch type {
        case .original: return .original
        case .modified: return .modified
        }
    }
}

// MARK: - Submode

public struct JS8CallSubmode: Equatable, Sendable {
    public let name: String
    public let id: Int              // Submode identifier (0, 1, 2, 4, 8)
    public let nsps: Int            // Samples per symbol at 12 kHz
    public let period: Int          // TX cycle in seconds
    public let startDelay: Double   // Start delay in seconds
    public let ndownsps: Int        // Downsampled samples per symbol
    public let ndd: Int             // Downsample FFT factor
    public let jz: Int              // Timing search range (quarter-symbol steps)
    public let costasType: JS8CallCostasType
    public let rxSNRThreshold: Int  // Nominal SNR decode threshold in dB

    public var baudRate: Double { JS8CallConstants.internalSampleRate / Double(nsps) }
    public var bandwidth: Double { 8.0 * baudRate }
    public var toneSpacing: Double { baudRate }
    public var txDuration: Double { Double(JS8CallConstants.NN * nsps) / JS8CallConstants.internalSampleRate + startDelay }
    public var ndown: Int { nsps / ndownsps }
    public var nfft1: Int { 2 * nsps }
    public var nstep: Int { nsps / 4 }
    public var costas: JS8CallCostasArrays { .forType(costasType) }
    /// Dedupe overlap in Hz
    public var dedupeHz: Double { JS8CallConstants.internalSampleRate / Double(nsps) * 0.64 }

    public static let normal = JS8CallSubmode(
        name: "Normal", id: 0, nsps: 1920, period: 15, startDelay: 0.5,
        ndownsps: 32, ndd: 100, jz: 62, costasType: .original, rxSNRThreshold: -24
    )
    public static let fast = JS8CallSubmode(
        name: "Fast", id: 1, nsps: 1200, period: 10, startDelay: 0.2,
        ndownsps: 20, ndd: 100, jz: 144, costasType: .modified, rxSNRThreshold: -22
    )
    public static let turbo = JS8CallSubmode(
        name: "Turbo", id: 2, nsps: 600, period: 6, startDelay: 0.1,
        ndownsps: 12, ndd: 120, jz: 172, costasType: .modified, rxSNRThreshold: -20
    )
    public static let slow = JS8CallSubmode(
        name: "Slow", id: 4, nsps: 3840, period: 30, startDelay: 0.5,
        ndownsps: 32, ndd: 90, jz: 32, costasType: .modified, rxSNRThreshold: -28
    )
    public static let ultra = JS8CallSubmode(
        name: "Ultra", id: 8, nsps: 384, period: 4, startDelay: 0.1,
        ndownsps: 12, ndd: 125, jz: 250, costasType: .modified, rxSNRThreshold: -18
    )

    public static let all: [JS8CallSubmode] = [.normal, .fast, .turbo, .slow, .ultra]
}

// MARK: - Configuration

public struct JS8CallConfiguration: Equatable, Sendable {
    public var submode: JS8CallSubmode
    public var carrierFrequency: Double   // Audio carrier frequency in Hz (default 1000)
    public var sampleRate: Double          // External audio sample rate (default 48000)
    public var decodeDepth: Int            // 1=BP only, 2=BP+subtraction, 3=BP+OSD+subtraction

    public var internalSampleRate: Double { JS8CallConstants.internalSampleRate }
    public var decimationFactor: Int { JS8CallConstants.decimationFactor }

    public init(
        submode: JS8CallSubmode = .normal,
        carrierFrequency: Double = 1000.0,
        sampleRate: Double = 48000.0,
        decodeDepth: Int = 3
    ) {
        self.submode = submode
        self.carrierFrequency = carrierFrequency
        self.sampleRate = sampleRate
        self.decodeDepth = decodeDepth
    }

    // Presets
    public static let normal  = JS8CallConfiguration(submode: .normal)
    public static let fast    = JS8CallConfiguration(submode: .fast)
    public static let turbo   = JS8CallConfiguration(submode: .turbo)
    public static let slow    = JS8CallConfiguration(submode: .slow)
    public static let ultra   = JS8CallConfiguration(submode: .ultra)
    public static let standard = normal

    // Factory methods
    public func withCarrierFrequency(_ freq: Double) -> JS8CallConfiguration {
        var c = self; c.carrierFrequency = freq; return c
    }
    public func withSampleRate(_ rate: Double) -> JS8CallConfiguration {
        var c = self; c.sampleRate = rate; return c
    }
    public func withSubmode(_ sub: JS8CallSubmode) -> JS8CallConfiguration {
        var c = self; c.submode = sub; return c
    }
    public func withDecodeDepth(_ depth: Int) -> JS8CallConfiguration {
        var c = self; c.decodeDepth = depth; return c
    }
}
