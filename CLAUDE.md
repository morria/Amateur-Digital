# Ham Digital - Claude Development Notes

## Project Overview

Ham Digital is an iOS app for amateur radio digital modes (RTTY, PSK31, Olivia) with an iMessage-style chat interface. Uses external USB soundcard connected between iPhone and radio for audio I/O.

## Build Commands

```bash
# Build Swift Package (DigiModesCore)
cd DigiModes/DigiModesCore && swift build

# Build iOS app (requires Xcode)
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project DigiModes/DigiModes.xcodeproj \
  -scheme DigiModes \
  -destination 'id=5112B080-58D8-4BC7-8AB0-BB34ED2095F6' \
  build

# Run tests (requires Xcode, not just command line tools)
cd DigiModes/DigiModesCore && swift test
```

## Architecture

### Two Codebases
1. **DigiModes/** - iOS app (SwiftUI, requires Xcode)
2. **DigiModesCore/** - Swift Package with core logic (buildable via CLI)

### Key Design Decisions
- iOS 17+ target (uses `ObservableObject`, not `@Observable`)
- Messages-style two-level navigation: Channel List → Channel Detail
- Ham radio conventions: uppercase text, callsigns, RST reports
- Channel = detected signal on a frequency, may have multiple participants

### File Organization

```
DigiModes/
├── DigiModes/                    # iOS App
│   ├── Models/                   # Channel, Message, DigitalMode, Station
│   ├── Views/
│   │   ├── Channels/             # ChannelListView, ChannelDetailView, ChannelRowView
│   │   ├── Chat/                 # MessageBubbleView (deprecated: ChatView, MessageListView, MessageInputView)
│   │   ├── Components/           # ModePickerView
│   │   └── Settings/             # SettingsView with AudioMeterView
│   ├── ViewModels/               # ChatViewModel
│   └── Services/                 # AudioService (real audio), ModemService (bridges to DigiModesCore)
│
└── DigiModesCore/                # Swift Package
    ├── Sources/DigiModesCore/
    │   ├── Models/               # Same models, with `public` access
    │   └── Codecs/               # BaudotCodec (RTTY)
    └── Tests/
```

## Current State

### Completed
- UI skeleton with channel-based navigation
- Baudot/ITA2 codec with LTRS/FIGS shift handling
- Sample data for development (3 mock channels)
- Swipe-to-reveal timestamps gesture
- Channel list shows frequency offset from 1500 Hz center
- Compose button to create new transmissions
- Message transmit states (queued → transmitting → sent/failed)
- Visual feedback with color-coded bubbles and status indicators
- AudioService with AVAudioEngine for real audio output
- Integration with ModemService for RTTY encoding

### Next Steps (RTTY Implementation)
1. **Audio capture** - Install input tap on AVAudioEngine for RX audio
2. **FSK demodulation** - Route input samples to MultiChannelRTTYDemodulator
3. **Channel detection** - Create Channel objects from detected signals
4. **Real-time decode display** - Show characters as they're decoded

### Key Implementation Details

**Message TransmitState**
- `.queued` - Gray bubble, clock icon - message waiting in queue
- `.transmitting` - Orange bubble, spinner - audio being played
- `.sent` - Blue bubble, checkmark - transmission complete
- `.failed` - Red bubble, warning icon - transmission error

**AudioService**
- Uses AVAudioPlayerNode for playback
- Async `playBuffer()` method waits for completion
- Falls back to simulated delay if modem unavailable
- Handles sample rate conversion automatically

**Frequency Offset Display**
- Channel list shows offset from 1500 Hz center (e.g., "+125 Hz", "-50 Hz")
- Matches typical waterfall display conventions

### Technical Notes

**RTTY Parameters (standard)**
- Baud rate: 45.45 baud (22ms per bit)
- Shift: 170 Hz (mark=2125 Hz, space=2295 Hz)
- 5 bits per character (Baudot/ITA2)
- 1 start bit, 1.5 stop bits

**Baudot Codec**
- `BaudotCodec.encode(String) -> [UInt8]` - Text to 5-bit codes
- `BaudotCodec.decode([UInt8]) -> String` - 5-bit codes to text
- Handles LTRS (0x1F) and FIGS (0x1B) shift codes automatically

**iOS Audio Considerations**
- Need `NSMicrophoneUsageDescription` in Info.plist (already added)
- External soundcard appears as standard audio device
- Use AVAudioSession category `.playAndRecord` with `.allowBluetooth` option
- Sample rate: 48000 Hz typical for USB audio

## Conventions

- Ham radio text is UPPERCASE
- Callsigns follow ITU format (e.g., W1AW, K1ABC, N0CALL)
- Common abbreviations: CQ (calling), DE (from), K (over), 73 (best regards)
- RST = Readability, Signal strength, Tone (e.g., 599 = perfect)
