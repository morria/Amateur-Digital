//
//  GFSKConfig.swift
//  AmateurDigitalCore
//
//  Configuration for 8-GFSK modulation shared by FT8, JS8Call, and related modes.
//  These modes all use the same physical layer: 8-tone GFSK with Costas sync arrays,
//  LDPC(174,91) error correction, and 79-symbol transmissions.
//

import Foundation

// MARK: - Costas Sync Array

/// A set of three 7-element Costas arrays used for synchronization in 8-GFSK modes.
/// The arrays are inserted at symbol positions [0-6], [36-42], and [72-78] to form
/// the characteristic 7+29+7+29+7 sync/data/sync/data/sync frame structure.
public struct GFSKCostasArrays: Sendable, Equatable {
    /// Beginning sync array (symbols 0-6)
    public let a: [Int]
    /// Middle sync array (symbols 36-42)
    public let b: [Int]
    /// End sync array (symbols 72-78)
    public let c: [Int]

    public init(a: [Int], b: [Int], c: [Int]) {
        self.a = a
        self.b = b
        self.c = c
    }

    /// FT8 Costas arrays: [3,1,4,0,6,5,2] at all three positions.
    public static let ft8 = GFSKCostasArrays(
        a: [3, 1, 4, 0, 6, 5, 2],
        b: [3, 1, 4, 0, 6, 5, 2],
        c: [3, 1, 4, 0, 6, 5, 2]
    )

    /// JS8Call "original" Costas arrays (Normal submode).
    public static let js8Original = GFSKCostasArrays(
        a: [4, 2, 5, 6, 1, 3, 0],
        b: [4, 2, 5, 6, 1, 3, 0],
        c: [4, 2, 5, 6, 1, 3, 0]
    )

    /// JS8Call "modified" Costas arrays (Fast, Turbo, Slow, Ultra submodes).
    public static let js8Modified = GFSKCostasArrays(
        a: [0, 6, 2, 3, 5, 4, 1],
        b: [1, 5, 0, 2, 3, 6, 4],
        c: [2, 5, 0, 6, 4, 1, 3]
    )
}

// MARK: - GFSK Configuration

/// Configuration for an 8-GFSK modem (shared physical layer for FT8, JS8Call, FT4, etc.).
///
/// All modes in this family share the same structure:
/// - 8-tone GFSK modulation (tones 0-7)
/// - 79 symbols per transmission: 7 sync + 29 data + 7 sync + 29 data + 7 sync
/// - 174-bit LDPC codeword mapped to 58 data symbols (3 bits each)
/// - Costas 7x7 sync arrays for time/frequency synchronization
///
/// What differs between modes is the Costas arrays, symbol rate (samples per symbol),
/// and the message packing/CRC above the physical layer.
public struct GFSKConfig: Sendable, Equatable {

    /// External audio sample rate (typically 48000 Hz).
    public let sampleRate: Double

    /// Internal processing sample rate (typically 12000 Hz).
    public let internalRate: Double

    /// Tone spacing in Hz. Equal to the baud rate (internalRate / samplesPerSymbol).
    public let toneSpacing: Double

    /// Samples per symbol at the internal rate.
    public let samplesPerSymbol: Int

    /// Costas sync arrays for this mode.
    public let costasArrays: GFSKCostasArrays

    /// Total number of channel symbols per transmission (always 79).
    public let symbolCount: Int

    /// Number of data symbols per transmission (always 58).
    public let dataSymbolCount: Int

    /// Number of sync symbols per transmission (always 21 = 3 x 7).
    public let syncSymbolCount: Int

    /// LDPC codeword length (always 174).
    public let codewordLength: Int

    /// Carrier frequency in Hz (audio frequency of tone 0).
    public let carrierFrequency: Double

    /// Decimation factor from external to internal rate.
    public var decimationFactor: Int {
        Int(sampleRate / internalRate)
    }

    /// Quarter-symbol step size in samples (at internal rate).
    public var quarterSymbolSamples: Int {
        samplesPerSymbol / 4
    }

    /// Baud rate in symbols per second.
    public var baudRate: Double {
        internalRate / Double(samplesPerSymbol)
    }

    /// Bandwidth in Hz (8 tones * tone spacing).
    public var bandwidth: Double {
        8.0 * toneSpacing
    }

    public init(
        sampleRate: Double = 48000.0,
        internalRate: Double = 12000.0,
        toneSpacing: Double = 6.25,
        samplesPerSymbol: Int = 1920,
        costasArrays: GFSKCostasArrays = .ft8,
        symbolCount: Int = 79,
        dataSymbolCount: Int = 58,
        syncSymbolCount: Int = 21,
        codewordLength: Int = 174,
        carrierFrequency: Double = 1500.0
    ) {
        self.sampleRate = sampleRate
        self.internalRate = internalRate
        self.toneSpacing = toneSpacing
        self.samplesPerSymbol = samplesPerSymbol
        self.costasArrays = costasArrays
        self.symbolCount = symbolCount
        self.dataSymbolCount = dataSymbolCount
        self.syncSymbolCount = syncSymbolCount
        self.codewordLength = codewordLength
        self.carrierFrequency = carrierFrequency
    }

    /// Create a new config with a different carrier frequency.
    public func withCarrierFrequency(_ freq: Double) -> GFSKConfig {
        GFSKConfig(
            sampleRate: sampleRate,
            internalRate: internalRate,
            toneSpacing: toneSpacing,
            samplesPerSymbol: samplesPerSymbol,
            costasArrays: costasArrays,
            symbolCount: symbolCount,
            dataSymbolCount: dataSymbolCount,
            syncSymbolCount: syncSymbolCount,
            codewordLength: codewordLength,
            carrierFrequency: freq
        )
    }

    /// Create a new config with different Costas arrays.
    public func withCostasArrays(_ arrays: GFSKCostasArrays) -> GFSKConfig {
        GFSKConfig(
            sampleRate: sampleRate,
            internalRate: internalRate,
            toneSpacing: toneSpacing,
            samplesPerSymbol: samplesPerSymbol,
            costasArrays: arrays,
            symbolCount: symbolCount,
            dataSymbolCount: dataSymbolCount,
            syncSymbolCount: syncSymbolCount,
            codewordLength: codewordLength,
            carrierFrequency: carrierFrequency
        )
    }

    // MARK: - Presets

    /// Standard FT8 configuration: 6.25 baud, 1920 sps at 12 kHz.
    public static let ft8 = GFSKConfig(
        sampleRate: 48000.0,
        internalRate: 12000.0,
        toneSpacing: 6.25,
        samplesPerSymbol: 1920,
        costasArrays: .ft8,
        carrierFrequency: 1500.0
    )

    /// JS8Call Normal submode configuration.
    public static let js8Normal = GFSKConfig(
        sampleRate: 48000.0,
        internalRate: 12000.0,
        toneSpacing: 6.25,
        samplesPerSymbol: 1920,
        costasArrays: .js8Original,
        carrierFrequency: 1000.0
    )
}
