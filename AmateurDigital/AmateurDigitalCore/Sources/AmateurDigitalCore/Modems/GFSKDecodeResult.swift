//
//  GFSKDecodeResult.swift
//  AmateurDigitalCore
//
//  Result of decoding a single 8-GFSK transmission (FT8, JS8Call, etc.).
//  Contains the raw decoded bits and signal quality metrics.
//  Protocol-specific message unpacking (FT8 vs JS8Call) is done by the caller.
//

import Foundation

/// Result from successfully decoding one 8-GFSK transmission through the
/// shared physical layer (sync search -> symbol extraction -> LDPC decode).
public struct GFSKDecodeResult: Sendable, Equatable {

    /// 87 decoded information bits from LDPC(174,87).
    /// The caller interprets these according to the protocol:
    /// - JS8Call: 72 payload + 3 frame type + 12 CRC
    /// - FT8: 77 message + 14 CRC (packed differently)
    public let messageBits: [UInt8]

    /// Estimated SNR in dB, derived from sync correlation strength.
    public let snr: Double

    /// Time offset in seconds from the start of the audio buffer.
    public let timeOffset: Double

    /// Carrier frequency in Hz where the signal was found.
    public let frequency: Double

    /// Number of hard bit errors corrected by the LDPC decoder.
    public let ldpcHardErrors: Int

    /// Distance metric from the LDPC decoder (0 for BP, weighted for OSD).
    public let ldpcDistance: Double

    /// Number of LDPC iterations used (BP) or decode pass index.
    public let decodePass: Int

    /// Sync correlation strength (higher = stronger signal).
    public let syncStrength: Double

    /// Quality metric: 1.0 = perfect, 0.0 = marginal decode.
    /// Computed as 1.0 - (hardErrors + distance) / 60.0, clamped to [0, 1].
    public var quality: Double {
        let hd = Double(ldpcHardErrors) + ldpcDistance
        return max(0, min(1, 1.0 - hd / 60.0))
    }
}
