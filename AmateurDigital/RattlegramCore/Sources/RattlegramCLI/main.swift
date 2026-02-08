import Foundation
import RattlegramCore

// MARK: - WAV I/O

struct WAVHeader {
    var riffID: UInt32 = 0x46464952       // "RIFF"
    var fileSize: UInt32 = 0
    var waveID: UInt32 = 0x45564157       // "WAVE"
    var fmtID: UInt32 = 0x20746D66        // "fmt "
    var fmtSize: UInt32 = 16
    var audioFormat: UInt16 = 1           // PCM
    var numChannels: UInt16 = 1
    var sampleRate: UInt32 = 48000
    var byteRate: UInt32 = 96000          // sampleRate * numChannels * bitsPerSample/8
    var blockAlign: UInt16 = 2            // numChannels * bitsPerSample/8
    var bitsPerSample: UInt16 = 16
    var dataID: UInt32 = 0x61746164       // "data"
    var dataSize: UInt32 = 0
}

func writeWAV(samples: [Int16], sampleRate: Int, path: String) throws {
    var header = WAVHeader()
    header.sampleRate = UInt32(sampleRate)
    header.byteRate = UInt32(sampleRate) * 2
    header.dataSize = UInt32(samples.count * 2)
    header.fileSize = 36 + header.dataSize

    var data = Data()
    data.append(contentsOf: withUnsafeBytes(of: header.riffID) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: header.fileSize) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: header.waveID) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: header.fmtID) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: header.fmtSize) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: header.audioFormat) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: header.numChannels) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: header.sampleRate) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: header.byteRate) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: header.blockAlign) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: header.bitsPerSample) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: header.dataID) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: header.dataSize) { Array($0) })

    samples.withUnsafeBufferPointer { buf in
        data.append(UnsafeBufferPointer(
            start: UnsafeRawPointer(buf.baseAddress!).assumingMemoryBound(to: UInt8.self),
            count: buf.count * 2))
    }

    try data.write(to: URL(fileURLWithPath: path))
}

func readWAV(path: String) throws -> (samples: [Int16], sampleRate: Int) {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    guard data.count >= 44 else {
        throw NSError(domain: "WAV", code: 1, userInfo: [NSLocalizedDescriptionKey: "File too small for WAV header"])
    }

    // Parse header
    let sampleRate = data.withUnsafeBytes { ptr -> UInt32 in
        ptr.load(fromByteOffset: 24, as: UInt32.self)
    }
    let numChannels = data.withUnsafeBytes { ptr -> UInt16 in
        ptr.load(fromByteOffset: 22, as: UInt16.self)
    }
    let bitsPerSample = data.withUnsafeBytes { ptr -> UInt16 in
        ptr.load(fromByteOffset: 34, as: UInt16.self)
    }

    // Find "data" chunk
    var dataOffset = 12
    var dataSize: UInt32 = 0
    while dataOffset + 8 <= data.count {
        let chunkID = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(fromByteOffset: dataOffset, as: UInt32.self)
        }
        let chunkSize = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(fromByteOffset: dataOffset + 4, as: UInt32.self)
        }
        if chunkID == 0x61746164 { // "data"
            dataOffset += 8
            dataSize = chunkSize
            break
        }
        dataOffset += 8 + Int(chunkSize)
    }

    guard dataSize > 0 else {
        throw NSError(domain: "WAV", code: 2, userInfo: [NSLocalizedDescriptionKey: "No data chunk found"])
    }

    let bytesPerSample = Int(bitsPerSample) / 8
    let totalSamples = Int(dataSize) / bytesPerSample
    var samples = [Int16](repeating: 0, count: totalSamples)

    if bitsPerSample == 16 {
        data.withUnsafeBytes { ptr in
            let src = ptr.baseAddress!.advanced(by: dataOffset).assumingMemoryBound(to: Int16.self)
            for i in 0..<totalSamples {
                samples[i] = src[i]
            }
        }
    }

    // If stereo, mix to mono
    if numChannels == 2 {
        let monoCount = totalSamples / 2
        var mono = [Int16](repeating: 0, count: monoCount)
        for i in 0..<monoCount {
            mono[i] = Int16(clamping: (Int(samples[2*i]) + Int(samples[2*i+1])) / 2)
        }
        return (mono, Int(sampleRate))
    }

    return (samples, Int(sampleRate))
}

// MARK: - Encode

func encodeCommand(text: String, callSign: String, sampleRate: Int,
                    carrierFreq: Int, output: String, noiseSymbols: Int = 0,
                    fancy: Bool = false) throws {
    let encoder = Encoder(sampleRate: sampleRate)
    let payload = Array(text.utf8) + [0]
    var paddedPayload = [UInt8](repeating: 0, count: 170)
    for i in 0..<min(payload.count, 170) {
        paddedPayload[i] = payload[i]
    }

    encoder.configure(payload: paddedPayload, callSign: callSign,
                       carrierFrequency: carrierFreq, noiseSymbols: noiseSymbols,
                       fancyHeader: fancy)

    var allSamples = [Int16]()
    var audioBuffer = [Int16](repeating: 0, count: encoder.extendedLength)
    var symbolIdx = 0

    while encoder.produce(&audioBuffer) {
        let maxAbs = audioBuffer.map { abs(Int($0)) }.max() ?? 0
        print("  Symbol \(symbolIdx): peak=\(maxAbs) (\(String(format: "%.1f", Double(maxAbs)/327.67))%)")
        allSamples.append(contentsOf: audioBuffer)
        symbolIdx += 1
    }
    // Final silence
    let maxAbs = audioBuffer.map { abs(Int($0)) }.max() ?? 0
    print("  Symbol \(symbolIdx) (final): peak=\(maxAbs)")
    allSamples.append(contentsOf: audioBuffer)

    // Also test iOS Float roundtrip path
    let floatSamples = allSamples.map { Float($0) / 32768.0 }
    let reconverted = floatSamples.map { Int16(clamping: Int(($0 * 32768.0).rounded())) }
    var diffs = 0
    for i in 0..<allSamples.count {
        if allSamples[i] != reconverted[i] { diffs += 1 }
    }

    try writeWAV(samples: allSamples, sampleRate: sampleRate, path: output)
    print("Encoded \(text.count) bytes to \(output)")
    print("  Call sign: \(callSign)")
    print("  Sample rate: \(sampleRate) Hz")
    print("  Carrier: \(carrierFreq) Hz")
    print("  Noise symbols: \(noiseSymbols)")
    print("  Symbols: \(symbolIdx + 1)")
    print("  Samples: \(allSamples.count)")
    print("  Duration: \(String(format: "%.2f", Double(allSamples.count) / Double(sampleRate))) s")
    print("  Float roundtrip diffs: \(diffs)/\(allSamples.count)")
}

// MARK: - Decode

func decodeCommand(input: String, sampleRate: Int) throws {
    let (samples, fileSampleRate) = try readWAV(path: input)
    let rate = fileSampleRate > 0 ? fileSampleRate : sampleRate

    let decoder = Decoder(sampleRate: rate)
    let extLen = decoder.extendedLength

    var offset = 0
    var synced = false
    var decoded = false

    while offset + extLen <= samples.count {
        let chunk = Array(samples[offset..<(offset + extLen)])
        let ready = decoder.feed(chunk, sampleCount: extLen)
        offset += extLen

        if ready {
            let status = decoder.process()
            switch status {
            case .sync:
                let info = decoder.staged()
                print("Sync detected!")
                print("  CFO: \(String(format: "%.1f", info.cfo)) Hz")
                print("  Mode: \(info.mode)")
                print("  Call sign: \(info.callSign)")
                synced = true
            case .done:
                var payload = [UInt8](repeating: 0, count: 170)
                let result = decoder.fetch(&payload)
                if result >= 0 {
                    // Find null terminator
                    var len = 0
                    while len < 170 && payload[len] != 0 { len += 1 }
                    let text = String(bytes: payload[0..<len], encoding: .utf8) ?? "<binary data>"
                    print("Decoded: \(text)")
                    print("  Bit flips: \(result)")
                    decoded = true
                } else {
                    print("Decode failed (polar decoder returned \(result))")
                }
            case .ping:
                let info = decoder.staged()
                print("Ping from: \(info.callSign)")
            case .nope:
                print("Unsupported mode")
            case .fail:
                break
            default:
                break
            }
        }
    }

    if !synced {
        print("No sync detected in \(input)")
    } else if !decoded {
        print("Sync found but decode incomplete")
    }
}

// MARK: - Main

func printUsage() {
    print("""
    Usage:
      RattlegramCLI encode --text <message> --callsign <CALL> [options] --output <file.wav>
      RattlegramCLI decode --input <file.wav> [--rate <sampleRate>]

    Encode options:
      --text <message>      Text to encode (up to 170 bytes)
      --callsign <CALL>     Callsign (up to 9 chars)
      --rate <Hz>           Sample rate (default: 48000)
      --carrier <Hz>        Carrier frequency (default: 1500)
      --output <file.wav>   Output WAV file

    Decode options:
      --input <file.wav>    Input WAV file
      --rate <Hz>           Override sample rate (default: from WAV header)
    """)
}

let args = CommandLine.arguments.dropFirst()
guard let command = args.first else {
    printUsage()
    exit(1)
}

func getArg(_ flag: String) -> String? {
    let argsArray = Array(args)
    guard let idx = argsArray.firstIndex(of: flag), idx + 1 < argsArray.count else { return nil }
    return argsArray[idx + 1]
}

do {
    switch command {
    case "encode":
        guard let text = getArg("--text"),
              let callSign = getArg("--callsign"),
              let output = getArg("--output") else {
            print("Error: --text, --callsign, and --output are required")
            printUsage()
            exit(1)
        }
        let rate = Int(getArg("--rate") ?? "48000") ?? 48000
        let carrier = Int(getArg("--carrier") ?? "1500") ?? 1500
        let noise = Int(getArg("--noise") ?? "0") ?? 0
        let fancy = Array(args).contains("--fancy")
        try encodeCommand(text: text, callSign: callSign, sampleRate: rate,
                           carrierFreq: carrier, output: output,
                           noiseSymbols: noise, fancy: fancy)

    case "decode":
        guard let input = getArg("--input") else {
            print("Error: --input is required")
            printUsage()
            exit(1)
        }
        let rate = Int(getArg("--rate") ?? "0") ?? 0
        try decodeCommand(input: input, sampleRate: rate)

    default:
        print("Unknown command: \(command)")
        printUsage()
        exit(1)
    }
} catch {
    print("Error: \(error.localizedDescription)")
    exit(1)
}
