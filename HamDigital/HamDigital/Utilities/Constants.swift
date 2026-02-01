//
//  Constants.swift
//  DigiModes
//

import Foundation

enum AppConstants {
    // Audio settings
    static let defaultSampleRate: Double = 48000.0
    static let audioBufferSize: Int = 1024

    // RTTY defaults
    static let rttyBaudRate: Double = 45.45
    static let rttyMarkFrequency: Double = 2125.0
    static let rttyShift: Double = 170.0

    // PSK31 defaults
    static let psk31CenterFrequency: Double = 1000.0
    static let psk31BaudRate: Double = 31.25

    // Olivia defaults
    static let oliviaCenterFrequency: Double = 1500.0
    static let oliviaTones: Int = 8
    static let oliviaBandwidth: Double = 250.0

    // UI constants
    static let maxMessageLength: Int = 500
    static let chatBubbleCornerRadius: CGFloat = 18.0
}
