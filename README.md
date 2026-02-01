# Ham Digital

An iOS app that provides an iMessage-like interface for amateur radio digital modes (RTTY, PSK31, Olivia) using an external USB audio interface.

## Current Status: Functional RTTY

The app supports full RTTY transmit and receive:
- **TX**: Type a message, tap send, and audio is generated and played through your device
- **RX**: The app continuously listens for RTTY signals and decodes them into messages
- **Multi-channel**: Monitors 8 frequencies simultaneously (1200-2600 Hz)
- **Squelch**: Adjustable squelch filters noise-induced false decodes
- **Debug mode**: Test decoding pipeline with WAV files (no radio needed)

## Getting Started

### Requirements

- Xcode 15.0+
- iOS 17.0+ device or simulator
- Apple Developer account (for device deployment)

### Setup

1. Open `HamDigital/DigiModes.xcodeproj` in Xcode
2. Select your development team in Signing & Capabilities
3. Build and run on simulator or device

### Building the Core Library (CLI)

The core logic (models, codecs) is in a Swift Package that can be built from the command line:

```bash
cd HamDigital/HamDigitalCore
swift build
```

Tests can be run from the command line:
```bash
cd HamDigital/HamDigitalCore && swift test
```

### Testing with Audio Files

Generate test RTTY audio files:

```bash
cd HamDigital/HamDigitalCore
swift run GenerateTestAudio
# Creates: /tmp/rtty_single_channel.wav (2125 Hz)
#          /tmp/rtty_multi_channel.wav (4 channels: 1500, 1700, 1900, 2100 Hz)
```

**Option 1: In-app Debug Mode (Recommended)**

1. Run the app in iOS Simulator
2. Go to Settings → Debug section
3. Tap "Play" on a test file to process it through the decoder
4. Decoded messages appear in the channel list

**Option 2: Over-the-air (requires audio hardware)**

```bash
afplay /tmp/rtty_single_channel.wav      # Play while app listens via mic
```

**Tip:** If decoding seems unreliable, lower the squelch in Settings → RTTY Settings.

---

## Development Roadmap

### Phase 1: Skeleton App ✅

- [x] SwiftUI project structure
- [x] iMessage-style chat interface
- [x] Message bubbles (RX gray/left, TX blue/right)
- [x] Mode picker (RTTY, PSK31, Olivia)
- [x] Settings screen with station info
- [x] Simulated QSO for demo/development
- [x] Swift Package for core logic (CLI buildable)
- [x] Baudot codec with unit tests

### Phase 2: Audio Interface ✅

- [x] AVAudioEngine setup for USB audio devices
- [x] Output buffer management for transmission
- [x] Sample rate handling (48kHz default)
- [x] Input tap for reception with mono conversion

### Phase 3: RTTY Implementation ✅

- [x] Baudot (ITA2) encoding/decoding tables
- [x] FSK modulation (tone generation) - via HamDigitalCore
- [x] Bit timing for transmission
- [x] FSK demodulation (tone detection)
- [x] Multi-channel simultaneous decoding (8 channels)
- [x] Mark/Space frequency configuration in Settings
- [x] Configurable baud rate and shift

### Phase 4: Message Handling ✅

- [x] TX queue management with transmit states
- [x] Visual feedback (queued/transmitting/sent/failed)
- [x] Compose button (bottom right, iMessage-style)
- [x] Stop transmission button
- [x] RX message display with auto-channel creation
- [x] Persistent settings via iCloud
- [x] Adjustable squelch to filter noise
- [x] Debug mode for testing with WAV files
- [ ] PTT control (via audio VOX)
- [ ] Message macros/templates

### Phase 5: PSK31 Implementation

- [ ] Varicode encoding/decoding
- [ ] BPSK modulation/demodulation
- [ ] Carrier phase tracking
- [ ] AFC (Automatic Frequency Control)

### Phase 6: Olivia Implementation

- [ ] MFSK tone generation
- [ ] Forward Error Correction (FEC)
- [ ] Interleaving/deinterleaving
- [ ] Multiple format support (8/250, 8/500, 16/500, etc.)

### Phase 7: Polish

- [x] Persistent settings (iCloud Key-Value Store + UserDefaults fallback)
- [ ] QSO log export (ADIF format)
- [ ] Dark mode optimization
- [ ] iPad layout support

---

## Technical Notes

### RTTY Specifications

- **Baud rate**: 45.45 baud (standard), also 50, 75, 100
- **Shift**: 170 Hz (standard), also 425, 850
- **Mark frequency**: 2125 Hz (standard)
- **Space frequency**: 1955 Hz (mark - shift)
- **Encoding**: 5-bit Baudot/ITA2 with LTRS/FIGS shift

### Audio Interface Requirements

The app uses an external USB audio interface connected to the iOS device:

```
┌─────────┐     ┌───────────────┐     ┌─────────┐
│  iPhone │────▶│ USB Audio I/F │────▶│  Radio  │
│         │◀────│               │◀────│         │
└─────────┘     └───────────────┘     └─────────┘
   SwiftUI         Line In/Out          AF In/Out
```

Compatible interfaces include:
- SignaLink USB
- RigBlaster Advantage
- DigiRig Mobile
- Any Class-Compliant USB audio interface

### Project Structure

```
HamDigital/
├── DigiModes.xcodeproj/        # Xcode project (iOS app)
├── HamDigital/                  # iOS app source
│   ├── App/
│   │   └── HamDigitalApp.swift
│   ├── Models/                 # Channel, Message, DigitalMode, Station
│   ├── Views/
│   │   ├── ContentView.swift
│   │   ├── Channels/           # ChannelListView, ChannelDetailView, ChannelRowView
│   │   ├── Chat/               # MessageBubbleView
│   │   ├── Components/         # ModePickerView
│   │   └── Settings/           # SettingsView
│   ├── ViewModels/             # ChatViewModel
│   ├── Services/               # AudioService, ModemService, SettingsManager, TestAudioLoader
│   └── Config/                 # ModeConfig
└── HamDigitalCore/              # Swift Package (CLI buildable)
    ├── Package.swift
    ├── Sources/
    │   ├── HamDigitalCore/
    │   │   ├── Models/         # RTTYConfiguration, RTTYChannel
    │   │   ├── Codecs/         # BaudotCodec
    │   │   └── Modems/         # RTTYModem, FSKDemodulator, MultiChannelRTTYDemodulator
    │   └── GenerateTestAudio/  # CLI tool for test audio files
    └── Tests/HamDigitalCoreTests/
```

---

## License

MIT License - See LICENSE file for details.

## Resources

- [RTTY on Wikipedia](https://en.wikipedia.org/wiki/Radioteletype)
- [PSK31 Specification](http://aintel.bi.ehu.es/psk31.html)
- [Olivia MFSK](https://en.wikipedia.org/wiki/Olivia_MFSK)
- [Apple AVAudioEngine Documentation](https://developer.apple.com/documentation/avfaudio/avaudioengine)
