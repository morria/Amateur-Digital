# Amateur Digital - Claude Development Notes

## Project Overview

Amateur Digital is an iOS app for amateur radio digital modes with an iMessage-style chat interface. Uses external USB soundcard connected between iPhone and radio for audio I/O.

**Supported modes**: RTTY, PSK31, BPSK63, QPSK31, QPSK63, Rattlegram (Olivia planned)

**Website**: https://amateurdigital.app (GitHub Pages)

## Build Commands

```bash
# Build Swift Package (AmateurDigitalCore)
cd AmateurDigital/AmateurDigitalCore && swift build

# Run AmateurDigitalCore tests
cd AmateurDigital/AmateurDigitalCore && swift test

# Build RattlegramCore
cd AmateurDigital/RattlegramCore && swift build

# Run RattlegramCore tests (68 tests, all passing)
cd AmateurDigital/RattlegramCore && swift test

# Rattlegram CLI tool
cd AmateurDigital/RattlegramCore && swift run RattlegramCLI encode --text "HELLO" --callsign TEST --output /tmp/test.wav
cd AmateurDigital/RattlegramCore && swift run RattlegramCLI decode --input /tmp/test.wav

# Build iOS app (requires Xcode)
xcodebuild -project AmateurDigital/AmateurDigital.xcodeproj \
  -scheme AmateurDigital \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  build

# Generate RTTY test audio files
cd AmateurDigital/AmateurDigitalCore && swift run GenerateTestAudio
# Outputs: /tmp/rtty_single_channel.wav, /tmp/rtty_multi_channel.wav
```

## Architecture

### Three Codebases
1. **AmateurDigital/** - iOS app (SwiftUI, requires Xcode)
2. **AmateurDigitalCore/** - Swift Package with RTTY/PSK modems (buildable via CLI)
3. **RattlegramCore/** - Swift Package with OFDM modem for rattlegram mode (buildable via CLI)

### Key Design Decisions
- iOS 17+ target (uses `ObservableObject`, not `@Observable`)
- Messages-style two-level navigation: Channel List → Channel Detail
- Ham radio conventions: uppercase text, callsigns, RST reports
- Channel = detected signal on a frequency, may have multiple participants
- Settings persist via iCloud Key-Value Store (NSUbiquitousKeyValueStore)

### File Organization

```
.
├── website/                           # GitHub Pages website
│   ├── index.html
│   └── app-icon.png
├── .github/workflows/
│   └── deploy-pages.yml               # GitHub Pages deployment
│
└── AmateurDigital/
    ├── AmateurDigital/                # iOS App
    │   ├── Models/                    # Channel, Message, DigitalMode, Station
    │   ├── Views/
    │   │   ├── ModeSelectionView.swift # Entry point - mode selection cards
    │   │   ├── Channels/              # ChannelListView, ChannelDetailView, ChannelRowView
    │   │   ├── Chat/                  # ChatView, MessageBubbleView, MessageInputView
    │   │   ├── Components/            # ModePickerView
    │   │   └── Settings/              # SettingsView with AudioMeterView
    │   ├── ViewModels/                # ChatViewModel
    │   ├── Services/                  # AudioService, ModemService, SettingsManager
    │   └── Config/                    # ModeConfig (enable/disable modes)
    │
    ├── AmateurDigitalCore/            # Swift Package (RTTY/PSK)
    │   ├── Sources/
    │   │   ├── AmateurDigitalCore/    # Library
    │   │   │   ├── Models/            # Channel, Message, DigitalMode, Station, Configurations
    │   │   │   ├── Codecs/            # BaudotCodec, VaricodeCodec
    │   │   │   ├── DSP/               # GoertzelFilter, SineGenerator
    │   │   │   └── Modems/            # RTTYModem, PSKModem, FSK/PSK modulators & demodulators
    │   │   └── GenerateTestAudio/     # CLI tool to generate test WAV files
    │   └── Tests/
    │
    └── RattlegramCore/                # Swift Package (OFDM/Rattlegram)
        ├── Package.swift              # iOS 16+ / macOS 13+
        ├── Sources/
        │   ├── RattlegramCore/        # Library (33 Swift files)
        │   │   ├── Math/              # Complex numbers, constants, utilities
        │   │   ├── DSP/               # FFT, Hilbert, BlockDC, Phasor, BipBuffer, SMA, PAPR
        │   │   ├── Coding/            # CRC, MLS, Xorshift, BitManipulation, PSK, Base37
        │   │   ├── Polar/             # Polar encoder/decoder, list decoder, frozen bit tables
        │   │   ├── BCH/               # BCH encoder, OSD decoder, generator matrix
        │   │   ├── Sync/              # SchmidlCox correlator, TheilSen estimator, triggers
        │   │   ├── Encoder.swift      # OFDM encoder: text → Int16 audio samples
        │   │   └── Decoder.swift      # OFDM decoder: Int16 audio samples → text
        │   └── RattlegramCLI/         # CLI tool: encode/decode WAV files
        │       └── main.swift
        └── Tests/                     # 68 tests (all passing)
```

## Current State

### Completed
- **RTTY**: Full TX/RX with multi-channel demodulator (8 channels)
- **PSK**: Full TX/RX for PSK31, BPSK63, QPSK31, QPSK63 with multi-channel demodulator
- **Rattlegram**: OFDM burst mode library complete (RattlegramCore). Not yet integrated into iOS app — see integration guide below.
- **Mode Selection UI**: Card-based mode picker as app entry point
- **Website**: GitHub Pages deployment with app landing page
- iMessage-style channel navigation with compose button (bottom right)
- Message transmit states with visual feedback (queued/transmitting/sent/failed)
- Stop button cancels in-progress transmissions
- Persistent settings via iCloud (baud rate, mark freq, shift)
- Swipe-to-reveal timestamps
- "Listening..." empty state when monitoring for signals

### Key Implementation Details

**Audio Pipeline**
- `AudioService`: AVAudioEngine with input tap and player node
- `onAudioInput` callback routes samples to ModemService
- `ModemService`: bridges to AmateurDigitalCore's MultiChannelRTTYDemodulator
- Decoded characters delivered via `ModemServiceDelegate`

**Message TransmitState**
- `.queued` - Gray bubble - message waiting in queue
- `.transmitting` - Orange bubble - audio being played
- `.sent` - Blue bubble - transmission complete
- `.failed` - Red bubble - transmission error or cancelled

**Settings (SettingsManager)**
- Callsign, grid locator, RTTY baud rate, mark frequency, shift
- Synced via NSUbiquitousKeyValueStore (iCloud)
- Falls back to UserDefaults if iCloud unavailable

**Multi-Channel Decoding**
- `MultiChannelRTTYDemodulator` monitors 8 frequencies (1200-2600 Hz, 200 Hz spacing)
- Each channel has independent FSK demodulator
- Characters grouped into messages with 2-second timeout

### Technical Notes

**RTTY Parameters (configurable)**
- Baud rate: 45.45 baud (default), also 50, 75, 100
- Shift: 170 Hz (default)
- Mark frequency: 2125 Hz (default)
- Sample rate: 48000 Hz

**PSK Parameters**
- PSK31: BPSK, 31.25 baud
- BPSK63: BPSK, 62.5 baud
- QPSK31: QPSK, 31.25 baud (2 bits/symbol)
- QPSK63: QPSK, 62.5 baud (2 bits/symbol)
- Center frequency: 1000 Hz (default)
- Sample rate: 48000 Hz

**Baudot Codec (RTTY)**
- `BaudotCodec.encode(String) -> [UInt8]` - Text to 5-bit codes
- `BaudotCodec.decode([UInt8]) -> String` - 5-bit codes to text
- Handles LTRS (0x1F) and FIGS (0x1B) shift codes automatically

**Varicode Codec (PSK)**
- `VaricodeCodec.encode(String) -> [Bool]` - Text to variable-length bits
- `VaricodeCodec.decode([Bool]) -> String` - Bits to text
- Variable-length encoding (common chars = fewer bits)

**iOS Audio**
- `AVAudioSession.Category.playAndRecord` with `.allowBluetoothA2DP`
- Input tap: 4096 sample buffer, converts stereo to mono
- nonisolated input handler for Sendable compliance

## RattlegramCore — Integration Guide

### What It Does

Rattlegram transmits up to 170 bytes of UTF-8 text over audio in ~1 second using OFDM with polar error correction codes. Ported from the C++ Android app [rattlegram](https://github.com/aicodix/rattlegram) (44 header-only files). The Swift port is bit-identical to the C++ version. 68/68 tests pass including encode→decode round-trips.

### How It Differs From RTTY/PSK

| Aspect | RTTY/PSK | Rattlegram |
|--------|----------|------------|
| Sample format | `[Float]` | `[Int16]` |
| Decoding | Character-by-character via delegate | Complete messages via `fetch()` |
| Encoding | Returns `[Float]` array | Iterative `produce()` calls returning `[Int16]` |
| TX duration | Depends on text length + baud | Fixed ~1 second burst |
| Max message | Unlimited streaming | 170 bytes per burst |
| Error correction | None (RTTY) / Viterbi (PSK) | Polar codes with CRC-32 |
| Sync | Tone/phase detect | Schmidl-Cox OFDM correlator |

### Public API

**Encoder** — text to audio:
```swift
import RattlegramCore

let encoder = Encoder(sampleRate: 48000)

// Payload: up to 170 bytes of UTF-8, null-padded
var payload = [UInt8](repeating: 0, count: 170)
let bytes = Array("HELLO WORLD".utf8)
for i in 0..<bytes.count { payload[i] = bytes[i] }

encoder.configure(
    payload: payload,
    callSign: "W1AW",           // up to 9 chars
    carrierFrequency: 1500,     // Hz (audio carrier within the audio band)
    noiseSymbols: 0,            // optional noise preamble
    fancyHeader: false          // optional ASCII art callsign
)

// Produce audio one symbol at a time (extendedLength samples each)
var buf = [Int16](repeating: 0, count: encoder.extendedLength)
var allSamples = [Int16]()
while encoder.produce(&buf) {
    allSamples.append(contentsOf: buf)
}
allSamples.append(contentsOf: buf)  // final (silence) symbol
```

**Decoder** — audio to text:
```swift
let decoder = Decoder(sampleRate: 48000)

// Feed audio continuously. Can be any chunk size.
// The decoder buffers internally and returns true when a symbol is ready.
let ready = decoder.feed(int16Samples, sampleCount: count)

if ready {
    let status = decoder.process()
    switch status {
    case .sync:
        let info = decoder.staged()
        // info.cfo — carrier frequency offset in Hz
        // info.mode — 14 (170 bytes), 15 (128 bytes), or 16 (85 bytes)
        // info.callSign — sender's callsign
    case .done:
        var payload = [UInt8](repeating: 0, count: 170)
        let flips = decoder.fetch(&payload)
        if flips >= 0 {
            // flips = number of corrected bit errors
            let text = String(bytes: payload.prefix(while: { $0 != 0 }), encoding: .utf8)
        }
    case .ping:
        let info = decoder.staged()
        // Received a ping (mode 0, no payload) from info.callSign
    case .nope:
        break // unsupported mode
    case .fail:
        break // preamble CRC failed (noise / different protocol)
    default:
        break
    }
}
```

**Key constants** (at 48kHz sample rate):
- `encoder.extendedLength` = 8640 samples per symbol
- `encoder.symbolLength` = 7680
- Total TX = ~69120 samples = 1.44 seconds
- Modes: 16 (≤85 bytes, strongest FEC), 15 (≤128 bytes), 14 (≤170 bytes, weakest FEC)

### Integration Into the iOS App

#### Step 1: Add Package Dependency

In Xcode, add `AmateurDigital/RattlegramCore` as a local Swift Package reference (same pattern as AmateurDigitalCore). Add the `RattlegramCore` product to the app target's Frameworks.

#### Step 2: Add `.rattlegram` to DigitalMode

In `AmateurDigital/Models/DigitalMode.swift`, add a new case:
```swift
case rattlegram = "Rattlegram"
```
With properties:
- `displayName`: "Rattlegram"
- `subtitle`: "OFDM 170B/1s"
- `description`: "OFDM burst mode with polar codes. Sends up to 170 bytes in ~1 second."
- `centerFrequency`: 1500.0
- `isPSKMode`: false
- `iconName`: "bolt.horizontal" (or similar)
- `color`: .teal

#### Step 3: Enable in ModeConfig

In `AmateurDigital/Config/ModeConfig.swift`, add `.rattlegram` to `enabledModes`.

#### Step 4: Add Rattlegram to ModemService

The main integration work. In `ModemService.swift`:

**Float ↔ Int16 conversion** — AudioService delivers `[Float]`, rattlegram expects `[Int16]`:
```swift
// RX: Float → Int16
let int16Samples = floatSamples.map { Int16(clamping: Int(($0 * 32768.0).rounded())) }

// TX: Int16 → Float
let floatSamples = int16Samples.map { Float($0) / 32768.0 }
```

**RX (decoding)** — Add to `processRxSamples()`:
```swift
case .rattlegram:
    let int16 = samples.map { Int16(clamping: Int(($0 * 32768.0).rounded())) }
    if rattlegramDecoder.feed(int16, sampleCount: int16.count) {
        let status = rattlegramDecoder.process()
        // Handle .sync, .done, .ping, .fail
        // On .done: fetch payload, emit as a complete message
    }
```

**TX (encoding)** — Add to `encodeTxSamples()`:
```swift
case .rattlegram:
    let encoder = Encoder(sampleRate: 48000)
    var payload = [UInt8](repeating: 0, count: 170)
    let bytes = Array(text.utf8)
    for i in 0..<min(bytes.count, 170) { payload[i] = bytes[i] }
    encoder.configure(payload: payload, callSign: settings.callSign)
    var allSamples = [Float]()
    var buf = [Int16](repeating: 0, count: encoder.extendedLength)
    while encoder.produce(&buf) {
        allSamples.append(contentsOf: buf.map { Float($0) / 32768.0 })
    }
    allSamples.append(contentsOf: buf.map { Float($0) / 32768.0 })
    return allSamples
```

**Message delivery** — Unlike RTTY/PSK which emit character-by-character via `ModemServiceDelegate`, rattlegram delivers complete messages. Two options:
1. **Emit all characters at once**: Loop through decoded text and call `delegate?.modemService(didDecode:)` for each character. Simple, fits existing pattern.
2. **Add a new delegate method**: `modemService(_:didDecodeMessage:fromCallSign:onChannel:)`. Cleaner but requires delegate protocol changes.

Option 1 is recommended for minimal integration effort.

**Decoder lifecycle** — The Decoder is stateful. Create one instance and keep feeding it samples continuously. It runs the SchmidlCox correlator on every sample looking for sync. When it finds a transmission, it automatically decodes through to `.done`. After `.done`, it resets and starts looking for the next transmission. No explicit reset needed.

#### Step 5: UI Considerations

- Rattlegram messages are complete bursts, not streaming characters. The chat bubble should appear all at once after decode, not character-by-character.
- Show the sender's callsign (from `decoder.staged().callSign`) in the message metadata.
- Show bit flips count as a signal quality indicator (0 = perfect, higher = noisier).
- TX is fast (~1 second). The transmit state can go from `.queued` → `.transmitting` → `.sent` quickly.
- Consider showing a "170 byte limit" indicator on the compose view when in rattlegram mode.

### Potential Tuning Needed

1. **Carrier frequency**: Default 1500 Hz works for most radio setups. May want to make configurable in settings if users have narrow audio passband filters.
2. **No AGC**: The decoder normalizes power internally (SchmidlCox uses power ratios, not absolute levels). Should work with typical soundcard input levels. If real-world testing shows issues with very quiet or loud signals, add a simple AGC before the Float→Int16 conversion.
3. **Continuous decode**: The decoder looks for sync continuously. When no signal is present, `feed()` returns `true` periodically (every `extendedLength` samples) and `process()` returns `.okay` (no sync found). This is normal and lightweight.

### Reference

The C++ original is at `.reference/rattlegram/app/src/main/cpp/` (44 header-only files). The Swift port matches it exactly. Key files for understanding the protocol:
- `encoder.hh` / `Encoder.swift` — OFDM frame structure
- `decoder.hh` / `Decoder.swift` — Decode state machine
- `schmidl_cox.hh` / `Sync/SchmidlCox.swift` — Sync detection
- `polar.hh` / `Polar/PolarCodec.swift` — Error correction wrapper

## Conventions

- Ham radio text is UPPERCASE
- Callsigns follow ITU format (e.g., W1AW, K1ABC, N0CALL)
- Common abbreviations: CQ (calling), DE (from), K (over), 73 (best regards)
- RST = Readability, Signal strength, Tone (e.g., 599 = perfect)
