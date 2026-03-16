# Amateur Digital

iOS app for amateur radio digital modes with an iMessage-style chat interface. External USB soundcard connects between iPhone and radio for audio I/O.

**Supported modes**: RTTY, PSK31, BPSK63, QPSK31, QPSK63, CW, JS8Call, Rattlegram (Olivia planned)
**Website**: https://amateurdigital.app (GitHub Pages)

## Build & Test Commands

```bash
# AmateurDigitalCore — RTTY, PSK, CW, JS8Call modems
cd AmateurDigital/AmateurDigitalCore && swift build
cd AmateurDigital/AmateurDigitalCore && swift test     # 16 test files

# RattlegramCore — OFDM burst modem
cd AmateurDigital/RattlegramCore && swift build
cd AmateurDigital/RattlegramCore && swift test          # 14 test files, 68 tests

# iOS app (requires Xcode + signing)
xcodebuild -project AmateurDigital/AmateurDigital.xcodeproj \
  -scheme AmateurDigital \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  build
```

## CLI Tools & Benchmarks

```bash
# CW benchmark — 96+ tests across noise, fading, speed, jitter, AFC
cd AmateurDigital/AmateurDigitalCore && swift run CWBenchmark

# PSK benchmark — 69 tests across BPSK63, QPSK31, QPSK63
cd AmateurDigital/AmateurDigitalCore && swift run PSKBenchmark

# JS8Call benchmark
cd AmateurDigital/AmateurDigitalCore && swift run JS8Benchmark

# Decode any WAV file (auto-detects mode, parallel demodulation)
cd AmateurDigital/AmateurDigitalCore && swift run DecodeWAV <input.wav>

# Generate RTTY test audio → /tmp/rtty_single_channel.wav, /tmp/rtty_multi_channel.wav
cd AmateurDigital/AmateurDigitalCore && swift run GenerateTestAudio

# Rattlegram CLI — encode/decode WAV files
cd AmateurDigital/RattlegramCore && swift run RattlegramCLI encode --text "HELLO" --callsign TEST --output /tmp/test.wav
cd AmateurDigital/RattlegramCore && swift run RattlegramCLI decode --input /tmp/test.wav

# Rattlegram benchmark
cd AmateurDigital/RattlegramCore && swift run RattlegramBenchmark
```

## Architecture

### Three Swift Packages + iOS App

| Codebase | What | Buildable via CLI |
|----------|------|:-:|
| `AmateurDigital/AmateurDigital/` | iOS app (SwiftUI, 26 files) | No (Xcode) |
| `AmateurDigital/AmateurDigitalCore/` | RTTY/PSK/CW/JS8Call modems | Yes |
| `AmateurDigital/RattlegramCore/` | OFDM modem (Rattlegram) | Yes |
| `HamTextClassifierTraining/` | CoreML model — detects ham radio text | Python |
| `CallsignExtractorTraining/` | CoreML model — extracts callsigns | Python |

### Key Design Decisions
- iOS 17+ target, uses `ObservableObject` (not `@Observable`)
- Messages-style two-level navigation: Channel List → Channel Detail
- Channel = detected signal on a frequency, may have multiple participants
- Settings persist via iCloud Key-Value Store (NSUbiquitousKeyValueStore), falls back to UserDefaults
- Ham radio conventions: uppercase text, callsigns, RST reports

### File Organization

```
.
├── CLAUDE.md
├── README.md
├── AppStoreMetadata.md
├── todo.md
├── website/                           # GitHub Pages site
├── .github/workflows/
│   ├── deploy-pages.yml               # Deploys website/ to GitHub Pages
│   └── test.yml                       # Runs AmateurDigitalCore tests (macOS 14, Xcode 15.4)
├── scripts/                           # Python analysis tools for RTTY/PSK signal processing
├── samples/                           # Test WAV files (~40 MB): RTTY and PSK at varying SNR
├── research/                          # Reference source code (~650 MB)
│   ├── fldigi/                        # Full fldigi source
│   ├── js8call/                       # Full JS8Call source
│   └── WSJT-X/                        # Full WSJT-X source (FT4/FT8 reference)
├── .reference/
│   ├── rattlegram/                    # C++ original (44 header-only files, Swift port basis)
│   └── fldigi-research.md             # Signal processing comparison & improvement roadmap
├── docs/presentation/                 # HTML reveal.js presentation on digital modes
│
├── HamTextClassifierTraining/         # ML: logistic regression on text statistics
│   ├── train_model.py
│   └── HamTextClassifier.mlmodel
├── CallsignExtractorTraining/         # ML: callsign extraction from decoded text
│   ├── train_model.py
│   └── CallsignModel.mlmodel
│
└── AmateurDigital/
    ├── AmateurDigital.xcodeproj
    ├── AmateurDigital/                # iOS App (26 Swift files)
    │   ├── AmateurDigitalApp.swift    # Entry point
    │   ├── Models/                    # Channel, Message, DigitalMode, Station
    │   ├── Views/
    │   │   ├── ContentView.swift, AdaptiveContentView.swift
    │   │   ├── PhoneNavigationView.swift, iPadNavigationView.swift
    │   │   ├── ModeSelectionView.swift # Card-based mode picker
    │   │   ├── Channels/              # ChannelListView, ChannelDetailView, ChannelRowView, ModeSidebarView
    │   │   ├── Chat/                  # ChatView, MessageBubbleView, MessageInputView, MessageListView
    │   │   ├── Components/            # ModePickerView
    │   │   └── Settings/              # SettingsView
    │   ├── ViewModels/                # ChatViewModel
    │   ├── Services/                  # AudioService, ModemService, SettingsManager
    │   ├── Config/                    # ModeConfig (enable/disable modes)
    │   ├── Utilities/                 # Constants
    │   └── Resources/                 # Localizable.xcstrings, PrivacyInfo.xcprivacy
    │
    ├── AmateurDigitalCore/            # Swift Package — HF digital modems
    │   ├── Package.swift              # iOS 16+ / macOS 13+
    │   ├── Sources/
    │   │   ├── AmateurDigitalCore/    # Library
    │   │   │   ├── Models/            # Channel, Message, DigitalMode, Station, Configurations
    │   │   │   ├── Codecs/            # BaudotCodec, VaricodeCodec, MorseCodec, JS8CallCodec, LDPC174_87
    │   │   │   ├── DSP/               # GoertzelFilter, SineGenerator, BandpassFilter, FFTProcessor, NuttallWindow
    │   │   │   └── Modems/            # RTTYModem, PSKModem, CWModem, JS8CallModem + modulators/demodulators
    │   │   ├── GenerateTestAudio/     # CLI: generate test WAV files
    │   │   ├── DecodeWAV/             # CLI: decode any WAV file
    │   │   ├── CWBenchmark/           # CLI: CW decoder benchmark
    │   │   ├── PSKBenchmark/          # CLI: PSK decoder benchmark
    │   │   └── JS8Benchmark/          # CLI: JS8Call decoder benchmark
    │   ├── Tests/                     # 16 test files
    │   └── PSK_RND_NOTES.md           # PSK R&D log: AFC, score history, optimization notes
    │
    └── RattlegramCore/                # Swift Package — OFDM burst modem
        ├── Package.swift              # iOS 16+ / macOS 13+
        ├── Sources/
        │   ├── RattlegramCore/        # Library (33 Swift files)
        │   │   ├── Encoder.swift      # OFDM encoder: text → Int16 audio samples
        │   │   ├── Decoder.swift      # OFDM decoder: Int16 audio samples → text
        │   │   ├── Math/              # Complex numbers, constants, utilities
        │   │   ├── DSP/               # FFT, Hilbert, BlockDC, Phasor, BipBuffer, SMA, PAPR, Delay, Window
        │   │   ├── Coding/            # CRC, MLS, Xorshift, BitManipulation, PSK, Base37
        │   │   ├── Polar/             # Polar encoder/decoder, list decoder, frozen bit tables, SIMD
        │   │   ├── BCH/               # BCH encoder, OSD decoder, generator matrix
        │   │   └── Sync/              # SchmidlCox correlator, TheilSen estimator, triggers
        │   ├── RattlegramCLI/         # CLI: encode/decode WAV files
        │   └── RattlegramBenchmark/   # CLI: performance benchmark
        └── Tests/                     # 14 test files, 68 tests
```

## Audio Pipeline

```
Radio ↔ USB Soundcard ↔ iPhone

AudioService (AVAudioEngine)
  ├── Input tap (4096 samples, stereo→mono, 48kHz)
  │   └── onAudioInput callback → ModemService
  └── Player node (TX audio output)

ModemService
  ├── RTTY: MultiChannelRTTYDemodulator (8 channels, 1200-2600 Hz, 200 Hz spacing)
  ├── PSK:  MultiChannelPSKDemodulator
  ├── CW:   CWDemodulator (adaptive 5-60 WPM, AFC ±250 Hz)
  ├── JS8:  JS8CallDemodulator (8-GFSK, LDPC decoding)
  └── Rattlegram: Decoder (OFDM, feeds Int16 samples continuously)
      └── Float↔Int16 conversion at boundary

Decoded text → ModemServiceDelegate → ChatViewModel → UI
```

**Sample format boundary**: AudioService uses `[Float]`. RattlegramCore uses `[Int16]`. ModemService converts at the boundary: `Float * 32768 → Int16` (RX), `Int16 / 32768 → Float` (TX).

## Message TransmitState
- `.queued` → Gray bubble, waiting in queue
- `.transmitting` → Orange bubble, audio playing
- `.sent` → Blue bubble, transmission complete
- `.failed` → Red bubble, error or cancelled

## Modem Parameters

| Mode | Baud | BW | Center Freq | Error Correction | Sample Rate |
|------|------|----|-------------|-----------------|-------------|
| RTTY | 45.45 (default) | ~250 Hz | Mark 2125 Hz, 170 Hz shift | None | 48000 |
| PSK31 | 31.25 | ~60 Hz | 1000 Hz | None (BPSK) / Viterbi (QPSK) | 48000 |
| BPSK63 | 62.5 | ~125 Hz | 1000 Hz | None | 48000 |
| QPSK31 | 31.25 | ~60 Hz | 1000 Hz | Viterbi | 48000 |
| QPSK63 | 62.5 | ~125 Hz | 1000 Hz | Viterbi | 48000 |
| CW | 5-60 WPM adaptive | ~100 Hz | 700 Hz | None | 48000 |
| JS8Call | 6.25 (8-GFSK) | ~50 Hz | Variable | LDPC | 48000 |
| Rattlegram | N/A (OFDM) | ~1600 Hz | 1500 Hz | Polar + CRC-32 | 48000 |

**CW specifics**: Goertzel block ~10ms (480 samples), AFC range ±250 Hz in 25 Hz steps, rise/fall 5ms raised-cosine, dash:dot ratio 3.0 (handles 2.5-4.0). Benchmark: 96.3/100.

## Codec APIs

```swift
// Baudot (RTTY) — 5-bit ITA2, uppercase only, LTRS/FIGS shift codes
BaudotCodec.encode(String) -> [UInt8]
BaudotCodec.decode([UInt8]) -> String

// Varicode (PSK) — variable-length, common chars = fewer bits
VaricodeCodec.encode(String) -> [Bool]
VaricodeCodec.decode([Bool]) -> String

// Morse (CW)
MorseCodec.encode(Character) -> String   // e.g. ".-"
MorseCodec.decode(String) -> Character?
```

## RattlegramCore API

**Encoder** — text to audio:
```swift
let encoder = Encoder(sampleRate: 48000)
var payload = [UInt8](repeating: 0, count: 170)
let bytes = Array("HELLO WORLD".utf8)
for i in 0..<bytes.count { payload[i] = bytes[i] }
encoder.configure(payload: payload, callSign: "W1AW", carrierFrequency: 1500)

var buf = [Int16](repeating: 0, count: encoder.extendedLength)
var allSamples = [Int16]()
while encoder.produce(&buf) { allSamples.append(contentsOf: buf) }
allSamples.append(contentsOf: buf)  // final silence symbol
// Total: ~69120 samples = 1.44 seconds at 48kHz
```

**Decoder** — audio to text:
```swift
let decoder = Decoder(sampleRate: 48000)
// Feed audio continuously. Any chunk size. Decoder buffers internally.
let ready = decoder.feed(int16Samples, sampleCount: count)
if ready {
    switch decoder.process() {
    case .sync:  let info = decoder.staged()  // .cfo, .mode, .callSign
    case .done:
        var payload = [UInt8](repeating: 0, count: 170)
        let flips = decoder.fetch(&payload)  // flips = corrected bit errors
        if flips >= 0 { /* success — decode payload as UTF-8 */ }
    case .ping:  let info = decoder.staged()  // mode 0, no payload
    case .fail:  break  // preamble CRC failed
    default:     break
    }
}
// Decoder is stateful. After .done it auto-resets and looks for next transmission.
```

**Modes**: 14 (≤170 bytes, weakest FEC), 15 (≤128 bytes), 16 (≤85 bytes, strongest FEC)

## Rattlegram iOS Integration Guide

The RattlegramCore library is complete and tested. Integration into the iOS app requires:

1. **Package dependency** — already added to xcodeproj as local package
2. **DigitalMode** — add `.rattlegram` case in `Models/DigitalMode.swift`
3. **ModeConfig** — add `.rattlegram` to `enabledModes` in `Config/ModeConfig.swift`
4. **ModemService** — main work:
   - RX: convert Float→Int16, feed to decoder, handle `.done` status, emit complete message
   - TX: configure encoder, produce Int16 symbols, convert to Float
   - Decoder is long-lived (create once, feed continuously, auto-resets after each decode)
5. **UI** — rattlegram messages appear all at once (not character-by-character), show callsign from header, show bit-flip count as quality indicator, 170-byte compose limit

## ML Models

Two CoreML models integrated into the iOS app:

- **HamTextClassifier** — logistic regression on text statistics (length, char ratios, entropy, n-grams). Detects ham radio text patterns (callsigns, RST reports, grid locators, CQ/DE/73).
- **CallsignExtractor** — extracts ITU-format callsigns from decoded text.

Training code in `HamTextClassifierTraining/` and `CallsignExtractorTraining/` (Python).

## CI/CD

- `.github/workflows/test.yml` — runs `swift build && swift test` on AmateurDigitalCore (macOS 14, Xcode 15.4) on push to main or PRs
- `.github/workflows/deploy-pages.yml` — deploys `website/` to GitHub Pages on push to main

## Reference Material

- `.reference/rattlegram/` — C++ original (44 header-only files). Swift port is bit-identical.
- `.reference/fldigi-research.md` — detailed signal processing comparison and improvement roadmap with estimated SNR gains
- `research/` — full source of fldigi, JS8Call, WSJT-X for algorithm reference
- `AmateurDigital/AmateurDigitalCore/PSK_RND_NOTES.md` — PSK R&D log with AFC implementation notes and score history
- `samples/` — RTTY and PSK WAV files at varying SNR levels for testing

## Conventions

- Ham radio text is UPPERCASE
- Callsigns follow ITU format (e.g., W1AW, K1ABC, N0CALL)
- Common abbreviations: CQ (calling), DE (from), K (over), 73 (best regards), RST (readability/signal/tone)
