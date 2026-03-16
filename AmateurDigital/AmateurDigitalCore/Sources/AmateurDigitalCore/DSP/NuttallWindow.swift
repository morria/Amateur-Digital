//
//  NuttallWindow.swift
//  AmateurDigitalCore
//
//  Nuttall window function with -98 dB sidelobe suppression for JS8Call spectrogram.
//

import Foundation

public struct NuttallWindow {

    private static let a0 =  0.3635819
    private static let a1 = -0.4891775
    private static let a2 =  0.1365995
    private static let a3 = -0.0106411

    /// Generate a Nuttall window of the specified length.
    public static func generate(length n: Int) -> [Double] {
        guard n > 0 else { return [] }
        var win = [Double](repeating: 0, count: n)
        let twopi = 2.0 * Double.pi
        for i in 0..<n {
            let x = twopi * Double(i) / Double(n)
            win[i] = a0 + a1 * cos(x) + a2 * cos(2.0 * x) + a3 * cos(3.0 * x)
        }
        return win
    }

    /// Generate a normalized Nuttall window matching JS8Call's convention.
    /// The window is divided by its sum, then scaled by `nsps * 2.0 / 300.0`.
    public static func generateNormalized(length n: Int, nsps: Int) -> [Double] {
        var win = generate(length: n)
        let s = win.reduce(0, +)
        guard s > 0 else { return win }
        let scale = Double(nsps) * 2.0 / 300.0
        for i in 0..<n { win[i] = win[i] / s * scale }
        return win
    }
}
