# Amateur Digital - Claude Development Notes

## Project Overview

Amateur Digital is an iOS app for amateur radio digital modes with an iMessage-style chat interface. Uses external USB soundcard connected between iPhone and radio for audio I/O.

**Supported modes**: RTTY, PSK31, BPSK63, QPSK31, QPSK63 (Olivia planned)

**Website**: https://amateurdigital.app (GitHub Pages)

## Build Commands

```bash
# Build Swift Package (AmateurDigitalCore)
cd AmateurDigital/AmateurDigitalCore && swift build

# Run AmateurDigitalCore tests
cd AmateurDigital/AmateurDigitalCore && swift test

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

### Two Codebases
1. **AmateurDigital/** - iOS app (SwiftUI, requires Xcode)
2. **AmateurDigitalCore/** - Swift Package with core logic (buildable via CLI)

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
    └── AmateurDigitalCore/            # Swift Package
        ├── Sources/
        │   ├── AmateurDigitalCore/    # Library
        │   │   ├── Models/            # Channel, Message, DigitalMode, Station, Configurations
        │   │   ├── Codecs/            # BaudotCodec, VaricodeCodec
        │   │   ├── DSP/               # GoertzelFilter, SineGenerator
        │   │   └── Modems/            # RTTYModem, PSKModem, FSK/PSK modulators & demodulators
        │   └── GenerateTestAudio/     # CLI tool to generate test WAV files
        └── Tests/
```

## Current State

### Completed
- **RTTY**: Full TX/RX with multi-channel demodulator (8 channels)
- **PSK**: Full TX/RX for PSK31, BPSK63, QPSK31, QPSK63 with multi-channel demodulator
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

## Conventions

- Ham radio text is UPPERCASE
- Callsigns follow ITU format (e.g., W1AW, K1ABC, N0CALL)
- Common abbreviations: CQ (calling), DE (from), K (over), 73 (best regards)
- RST = Readability, Signal strength, Tone (e.g., 599 = perfect)
