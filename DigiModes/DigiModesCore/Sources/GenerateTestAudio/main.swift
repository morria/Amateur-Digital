//
//  GenerateTestAudio
//  Generates RTTY test audio files for Ham Digital
//

import Foundation
import DigiModesCore

// MARK: - Audio File Generation

/// Write samples to a WAV file
func writeWAV(samples: [Float], sampleRate: Double, to path: String) throws {
    let url = URL(fileURLWithPath: path)

    // WAV header
    var header = Data()
    let dataSize = UInt32(samples.count * 2)  // 16-bit samples
    let fileSize = dataSize + 36

    // RIFF header
    header.append("RIFF".data(using: .ascii)!)
    header.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
    header.append("WAVE".data(using: .ascii)!)

    // fmt chunk
    header.append("fmt ".data(using: .ascii)!)
    header.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })  // chunk size
    header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // PCM format
    header.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })   // mono
    header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Array($0) })  // sample rate
    header.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate * 2).littleEndian) { Array($0) })  // byte rate
    header.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })   // block align
    header.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })  // bits per sample

    // data chunk
    header.append("data".data(using: .ascii)!)
    header.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })

    // Convert Float32 to Int16
    var audioData = Data()
    for sample in samples {
        let clamped = max(-1.0, min(1.0, sample))
        let int16 = Int16(clamped * 32767)
        audioData.append(contentsOf: withUnsafeBytes(of: int16.littleEndian) { Array($0) })
    }

    var fileData = header
    fileData.append(audioData)

    try fileData.write(to: url)
}

// MARK: - Single Channel Test

func generateSingleChannelTest() throws {
    print("=== Single Channel RTTY Test ===")

    let config = RTTYConfiguration.standard
    let modem = RTTYModem(configuration: config)

    let message = "RYRYRY CQ CQ CQ DE W1AW W1AW W1AW K"

    print("Configuration: \(config)")
    print("Message: \(message)")

    let samples = modem.encodeWithIdle(
        text: message,
        preambleMs: 500,
        postambleMs: 200
    )

    print("Generated \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / config.sampleRate)) seconds)")

    let outputPath = "/tmp/rtty_single_channel.wav"
    try writeWAV(samples: samples, sampleRate: config.sampleRate, to: outputPath)
    print("Written to: \(outputPath)")
    print()
}

// MARK: - Multi-Channel Test

func generateMultiChannelTest() throws {
    print("=== Multi-Channel RTTY Test (4 channels) ===")

    // Four different stations at different frequencies
    let channels: [(freq: Double, callsign: String, message: String)] = [
        (1500, "W1AW", "CQ CQ CQ DE W1AW W1AW W1AW K"),
        (1700, "K5ABC", "CQ CONTEST DE K5ABC K5ABC K"),
        (1900, "N0XYZ", "QSO DE N0XYZ N0XYZ PSE K"),
        (2100, "VE3TEST", "CQ DX DE VE3TEST VE3TEST K")
    ]

    let sampleRate = 48000.0
    var maxLength = 0
    var channelSamples: [[Float]] = []

    for (freq, callsign, message) in channels {
        let config = RTTYConfiguration(
            baudRate: 45.45,
            markFrequency: freq,
            shift: 170.0,
            sampleRate: sampleRate
        )
        let modem = RTTYModem(configuration: config)

        // Add some random delay (0-500ms) to make channels start at different times
        let delaySamples = Int(Double.random(in: 0...0.5) * sampleRate)
        var samples = [Float](repeating: 0, count: delaySamples)

        samples.append(contentsOf: modem.encodeWithIdle(
            text: message,
            preambleMs: 200,
            postambleMs: 100
        ))

        print("Channel \(Int(freq)) Hz (\(callsign)): \(samples.count) samples")
        channelSamples.append(samples)
        maxLength = max(maxLength, samples.count)
    }

    // Mix all channels together
    var mixed = [Float](repeating: 0, count: maxLength)
    for channel in channelSamples {
        for (i, sample) in channel.enumerated() {
            mixed[i] += sample * 0.25  // Scale down to prevent clipping
        }
    }

    print("Mixed audio: \(mixed.count) samples (\(String(format: "%.2f", Double(mixed.count) / sampleRate)) seconds)")

    let outputPath = "/tmp/rtty_multi_channel.wav"
    try writeWAV(samples: mixed, sampleRate: sampleRate, to: outputPath)
    print("Written to: \(outputPath)")
    print()
    print("Channels:")
    for (freq, callsign, _) in channels {
        print("  - \(Int(freq)) Hz: \(callsign)")
    }
    print()
}

// MARK: - Main

do {
    try generateSingleChannelTest()
    try generateMultiChannelTest()

    print("=== Playback Instructions ===")
    print("Play single channel:  afplay /tmp/rtty_single_channel.wav")
    print("Play multi-channel:   afplay /tmp/rtty_multi_channel.wav")
    print()
    print("To test with your phone:")
    print("1. Play the WAV file on your computer")
    print("2. Hold your phone near the speaker")
    print("3. The app should decode the RTTY signal")
} catch {
    print("Error: \(error)")
    exit(1)
}
