# Ham Digital - Claude Development Notes

## Project Overview

Ham Digital is an iOS app for amateur radio digital modes (RTTY, PSK31, Olivia) with an iMessage-style chat interface. Uses external USB soundcard connected between iPhone and radio for audio I/O.

## Build Commands

```bash
# Build Swift Package (HamDigitalCore)
cd HamDigital/HamDigitalCore && swift build

# Run HamDigitalCore tests
cd HamDigital/HamDigitalCore && swift test

# Build iOS app (requires Xcode)
xcodebuild -project HamDigital/DigiModes.xcodeproj \
  -scheme DigiModes \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro' \
  build

# Generate RTTY test audio files
cd HamDigital/HamDigitalCore && swift run GenerateTestAudio
# Outputs: /tmp/rtty_single_channel.wav, /tmp/rtty_multi_channel.wav
```

## Architecture

### Two Codebases
1. **HamDigital/** - iOS app (SwiftUI, requires Xcode)
2. **HamDigitalCore/** - Swift Package with core logic (buildable via CLI)

### Key Design Decisions
- iOS 17+ target (uses `ObservableObject`, not `@Observable`)
- Messages-style two-level navigation: Channel List → Channel Detail
- Ham radio conventions: uppercase text, callsigns, RST reports
- Channel = detected signal on a frequency, may have multiple participants
- Settings persist via iCloud Key-Value Store (NSUbiquitousKeyValueStore)

### File Organization

```
HamDigital/
├── HamDigital/                    # iOS App
│   ├── Models/                   # Channel, Message, DigitalMode, Station
│   ├── Views/
│   │   ├── Channels/             # ChannelListView, ChannelDetailView, ChannelRowView
│   │   ├── Chat/                 # MessageBubbleView
│   │   ├── Components/           # ModePickerView
│   │   └── Settings/             # SettingsView with AudioMeterView
│   ├── ViewModels/               # ChatViewModel
│   ├── Services/                 # AudioService, ModemService, SettingsManager
│   └── Config/                   # ModeConfig (enable/disable modes)
│
└── HamDigitalCore/                # Swift Package
    ├── Sources/
    │   ├── HamDigitalCore/        # Library
    │   │   ├── Models/           # RTTYConfiguration, RTTYChannel
    │   │   ├── Codecs/           # BaudotCodec
    │   │   └── Modems/           # RTTYModem, FSKDemodulator, MultiChannelRTTYDemodulator
    │   └── GenerateTestAudio/    # CLI tool to generate test WAV files
    └── Tests/
```

## Current State

### Completed
- Full RTTY TX: encode text → FSK audio → play through device
- Full RTTY RX: audio input tap → multi-channel demodulator → decoded text
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
- `ModemService`: bridges to HamDigitalCore's MultiChannelRTTYDemodulator
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

**Baudot Codec**
- `BaudotCodec.encode(String) -> [UInt8]` - Text to 5-bit codes
- `BaudotCodec.decode([UInt8]) -> String` - 5-bit codes to text
- Handles LTRS (0x1F) and FIGS (0x1B) shift codes automatically

**iOS Audio**
- `AVAudioSession.Category.playAndRecord` with `.allowBluetoothA2DP`
- Input tap: 4096 sample buffer, converts stereo to mono
- nonisolated input handler for Sendable compliance

## Conventions

- Ham radio text is UPPERCASE
- Callsigns follow ITU format (e.g., W1AW, K1ABC, N0CALL)
- Common abbreviations: CQ (calling), DE (from), K (over), 73 (best regards)
- RST = Readability, Signal strength, Tone (e.g., 599 = perfect)
