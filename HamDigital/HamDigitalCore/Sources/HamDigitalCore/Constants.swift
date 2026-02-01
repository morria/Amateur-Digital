//
//  Constants.swift
//  DigiModesCore
//

import Foundation

public enum AppConstants {
    // Audio settings
    public static let defaultSampleRate: Double = 48000.0
    public static let audioBufferSize: Int = 1024

    // RTTY defaults
    public static let rttyBaudRate: Double = 45.45
    public static let rttyMarkFrequency: Double = 2125.0
    public static let rttyShift: Double = 170.0

    // PSK31 defaults
    public static let psk31CenterFrequency: Double = 1000.0
    public static let psk31BaudRate: Double = 31.25

    // Olivia defaults
    public static let oliviaCenterFrequency: Double = 1500.0
    public static let oliviaTones: Int = 8
    public static let oliviaBandwidth: Double = 250.0

    // UI constants
    public static let maxMessageLength: Int = 500
    public static let chatBubbleCornerRadius: CGFloat = 18.0
}
