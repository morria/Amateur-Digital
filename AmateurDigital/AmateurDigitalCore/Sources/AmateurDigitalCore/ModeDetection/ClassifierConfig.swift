//
//  ClassifierConfig.swift
//  AmateurDigitalCore
//
//  Configurable thresholds for the mode classifier.
//  Can be overridden via the MODE_CLASSIFIER_PARAMS environment variable
//  (JSON dict of parameter names to Float values) for Optuna optimization.
//

import Foundation

/// Configurable thresholds for mode classification.
/// Default values are hand-tuned from 15+ improvement cycles on 257 test signals.
/// Can be overridden via environment variable for automated optimization.
public struct ClassifierConfig {

    // MARK: - Signal Detection Gate
    public var signalPeakThresholdDB: Float = 12
    public var signalFlatnessMax: Float = 0.8
    public var signalPeakBWMax: Float = 100

    // MARK: - RTTY
    public var rttyBasePrior: Float = 0.05
    public var rttyFSKValleyBonus: Float = 0.55
    public var rttyFSKNoValleyBonus3Plus: Float = 0.40
    public var rttyFSKNoValleyCVMax: Float = 0.5
    public var rttyFSKNoValleyTransMin: Float = 5
    public var rttyFSKNoValleyTransMax: Float = 60
    public var rttyBWBonus: Float = 0.15
    public var rttyBWPenalty: Float = 0.15
    public var rttyPeakBWThreshold: Float = 25
    public var rttyPeakBWPenaltyMild: Float = 0.10
    public var rttyPeakBWPenaltySevere: Float = 0.20

    // MARK: - PSK
    public var pskNarrowPeakBonus: Float = 0.35
    public var pskBWMatchBonus: Float = 0.15
    public var pskMinPeakBW: Float = 22
    public var pskCWNarrowPenalty: Float = 0.15
    public var pskCVHighPenalty: Float = 0.25
    public var pskCVHighTransMax: Float = 20
    public var pskOOKPenalty: Float = 0.15
    public var pskFlatnessPenalty: Float = 0.15
    public var pskBaudRateBonus: Float = 0.20
    public var pskBaudRatePenalty: Float = 0.15

    // MARK: - CW
    public var cwNarrowPeakThreshold: Float = 22
    public var cwNarrowPeakBonus: Float = 0.45
    public var cwOOKBonus: Float = 0.35
    public var cwPartialCVMin: Float = 0.10
    public var cwChannelBroadenedCVMin: Float = 0.6
    public var cwChannelBroadenedBonus: Float = 0.35
    public var cwNoModulationPenalty: Float = 0.35
    public var cwBWBonus: Float = 0.10
    public var cwDutyCycleBonus: Float = 0.10

    // MARK: - JS8Call / FT8
    public var js8LowTransitionBonus: Float = 0.40
    public var js8MedTransitionBonus: Float = 0.15
    public var js8HighTransitionPenalty: Float = 0.15
    public var js8PeakBWMin: Float = 20
    public var js8PeakBWMax: Float = 70
    public var js8PeakBWBonus: Float = 0.15
    public var js8GFSKCVBonus: Float = 0.25
    public var js8FewPeaksBonus: Float = 0.10
    public var js8ManyPeaksPenalty: Float = 0.15
    public var js8BaudRateBonus: Float = 0.25
    public var ft8PriorBoost: Float = 0.03

    // MARK: - Noise
    public var noiseBasePrior: Float = 0.3
    public var noiseNoPeakBonus: Float = 0.50
    public var noiseBroadbandBonus: Float = 0.40
    public var noiseWidePeakBonus: Float = 0.20
    public var noiseWeakPeakBonus: Float = 0.15
    public var noiseCarrierBonus: Float = 0.50

    // MARK: - Loading

    /// Load from environment variable MODE_CLASSIFIER_PARAMS (JSON).
    /// Falls back to defaults for any missing keys.
    public static func fromEnvironment() -> ClassifierConfig {
        var config = ClassifierConfig()

        guard let jsonStr = ProcessInfo.processInfo.environment["MODE_CLASSIFIER_PARAMS"],
              let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Double] else {
            return config
        }

        // Map JSON keys to struct fields
        if let v = dict["signal_peak_threshold_db"] { config.signalPeakThresholdDB = Float(v) }
        if let v = dict["signal_flatness_max"] { config.signalFlatnessMax = Float(v) }
        if let v = dict["rtty_fsk_no_valley_bonus_3plus"] { config.rttyFSKNoValleyBonus3Plus = Float(v) }
        if let v = dict["rtty_fsk_no_valley_cv_max"] { config.rttyFSKNoValleyCVMax = Float(v) }
        if let v = dict["rtty_bw_penalty_wide"] { config.rttyBWPenalty = Float(v) }
        if let v = dict["rtty_peak_bw_threshold"] { config.rttyPeakBWThreshold = Float(v) }
        if let v = dict["psk_narrow_peak_bonus"] { config.pskNarrowPeakBonus = Float(v) }
        if let v = dict["psk_bw_match_bonus"] { config.pskBWMatchBonus = Float(v) }
        if let v = dict["psk_cv_high_penalty"] { config.pskCVHighPenalty = Float(v) }
        if let v = dict["psk_min_peak_bw"] { config.pskMinPeakBW = Float(v) }
        if let v = dict["psk_flatness_penalty"] { config.pskFlatnessPenalty = Float(v) }
        if let v = dict["cw_narrow_peak_bonus"] { config.cwNarrowPeakBonus = Float(v) }
        if let v = dict["cw_ook_bonus"] { config.cwOOKBonus = Float(v) }
        if let v = dict["cw_narrow_peak_threshold"] { config.cwNarrowPeakThreshold = Float(v) }
        if let v = dict["js8_low_transition_bonus"] { config.js8LowTransitionBonus = Float(v) }
        if let v = dict["js8_peak_bw_min"] { config.js8PeakBWMin = Float(v) }
        if let v = dict["js8_peak_bw_max"] { config.js8PeakBWMax = Float(v) }
        if let v = dict["js8_gfsk_cv_bonus"] { config.js8GFSKCVBonus = Float(v) }
        if let v = dict["js8_baud_rate_bonus"] { config.js8BaudRateBonus = Float(v) }
        if let v = dict["noise_weak_peak_bonus"] { config.noiseWeakPeakBonus = Float(v) }
        if let v = dict["noise_broadband_bonus"] { config.noiseBroadbandBonus = Float(v) }
        if let v = dict["ft8_prior_boost"] { config.ft8PriorBoost = Float(v) }

        return config
    }

    /// Default configuration with hand-tuned values.
    public static let `default` = ClassifierConfig()
}
