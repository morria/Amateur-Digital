# Ham Digital

An iOS app that provides an iMessage-like interface for amateur radio digital modes (RTTY, PSK31, Olivia) using an external USB audio interface.

## Current Status: Functional Prototype

The app has a working UI with real audio transmission support. Ham Digital can generate and play RTTY audio signals through the device output. Reception (decoding) is not yet implemented.

## Getting Started

### Requirements

- Xcode 15.0+
- iOS 17.0+ device or simulator
- Apple Developer account (for device deployment)

### Setup

1. Open `DigiModes/DigiModes.xcodeproj` in Xcode
2. Select your development team in Signing & Capabilities
3. Build and run on simulator or device

### Building the Core Library (CLI)

The core logic (models, codecs) is in a Swift Package that can be built from the command line:

```bash
cd DigiModes/DigiModesCore
swift build
```

Tests require Xcode (XCTest isn't available in command line tools):
```bash
# In Xcode: Product → Test (⌘U)
# Or use xcodebuild if Xcode is installed
xcodebuild test -scheme DigiModesCore -destination 'platform=macOS'
```

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
- [ ] Input tap for reception

### Phase 3: RTTY Implementation (Partial)

- [x] Baudot (ITA2) encoding/decoding tables
- [x] FSK modulation (tone generation) - via DigiModesCore
- [x] Bit timing for transmission
- [ ] FSK demodulation (tone detection)
- [ ] Mark/Space frequency configuration UI
- [ ] Shift detection (170Hz, 425Hz, 850Hz)

### Phase 4: Message Handling (Partial)

- [x] TX queue management with transmit states
- [x] Visual feedback (queued/transmitting/sent/failed)
- [x] Compose button for new messages
- [ ] Character-by-character RX display
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

- [ ] Persistent settings (UserDefaults/SwiftData)
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
DigiModes/
├── DigiModes.xcodeproj/        # Xcode project (iOS app)
├── DigiModes/                  # iOS app source
│   ├── App/
│   │   └── HamDigitalApp.swift
│   ├── Models/                 # App-specific models
│   ├── Views/
│   │   ├── ContentView.swift
│   │   ├── Chat/
│   │   ├── Components/
│   │   └── Settings/
│   ├── ViewModels/
│   └── Services/
└── DigiModesCore/              # Swift Package (CLI buildable)
    ├── Package.swift
    ├── Sources/DigiModesCore/
    │   ├── Models/             # Message, DigitalMode, Station
    │   ├── Codecs/             # BaudotCodec (RTTY)
    │   └── Constants.swift
    └── Tests/DigiModesCoreTests/
```

---

## License

MIT License - See LICENSE file for details.

## Resources

- [RTTY on Wikipedia](https://en.wikipedia.org/wiki/Radioteletype)
- [PSK31 Specification](http://aintel.bi.ehu.es/psk31.html)
- [Olivia MFSK](https://en.wikipedia.org/wiki/Olivia_MFSK)
- [Apple AVAudioEngine Documentation](https://developer.apple.com/documentation/avfaudio/avaudioengine)
