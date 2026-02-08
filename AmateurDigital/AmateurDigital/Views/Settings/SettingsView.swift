//
//  SettingsView.swift
//  DigiModes
//

import SwiftUI

// MARK: - Squelch Level Presets

enum SquelchLevel: Double, CaseIterable, Identifiable {
    case off = 0.0
    case low = 0.05
    case medium = 0.15
    case high = 0.35
    case max = 0.60

    var id: Double { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .max: return "Max"
        }
    }

    /// Find the closest preset for a given value
    static func closest(to value: Double) -> SquelchLevel {
        allCases.min(by: { abs($0.rawValue - value) < abs($1.rawValue - value) }) ?? .off
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsManager.shared
    var chatViewModel: ChatViewModel?
    /// When set, only show settings for this specific mode (used when accessing from channel list)
    var filterMode: DigitalMode?

    /// Helper to determine if we should show a particular mode's settings
    private func shouldShowModeSettings(_ mode: DigitalMode) -> Bool {
        guard ModeConfig.isEnabled(mode) else { return false }
        // If filtering, only show the filtered mode
        if let filter = filterMode {
            return mode == filter || (filter.isPSKMode && mode == .psk31)
        }
        return true
    }

    /// Title based on whether we're filtering
    private var navigationTitle: String {
        if let mode = filterMode {
            return String(localized: "\(mode.displayName) Settings")
        }
        return String(localized: "Settings")
    }

    var body: some View {
        NavigationStack {
            Form {
                // Show station/location/audio sections only when not filtering
                if filterMode == nil {
                    Section("My Station") {
                        TextField("Callsign", text: $settings.callsign)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        TextField("Name", text: $settings.operatorName)
                    }

                    Section {
                        Toggle("Use GPS for Location", isOn: $settings.useGPSLocation)

                        if settings.useGPSLocation {
                            // GPS-derived values (read-only display)
                            HStack {
                                Text("Grid Square")
                                Spacer()
                                if settings.gpsGrid.isEmpty {
                                    Text(locationStatusText)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text(settings.gpsGrid)
                                        .foregroundColor(.secondary)
                                }
                            }

                            HStack {
                                Text("QTH")
                                Spacer()
                                if settings.gpsQTH.isEmpty {
                                    Text(locationStatusText)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text(settings.gpsQTH)
                                        .foregroundColor(.secondary)
                                }
                            }

                            if case .denied = settings.locationStatus {
                                Text("Location access denied. Enable in Settings app.")
                                    .font(.caption)
                                    .foregroundColor(.red)
                            }

                            Button("Update Location") {
                                settings.requestLocationUpdate()
                            }
                            .disabled(settings.locationStatus == .updating)
                        } else {
                            // Manual entry
                            TextField("Grid Square", text: $settings.grid)
                                .textInputAutocapitalization(.characters)
                            TextField("QTH (City, State)", text: $settings.qth)
                        }
                    } header: {
                        Text("Location")
                    } footer: {
                        if settings.useGPSLocation {
                            Text("Grid square and QTH are automatically determined from your location.")
                        } else {
                            Text("Enter your Maidenhead grid square (e.g., DM79lv) and location manually.")
                        }
                    }

                    Section {
                        NavigationLink {
                            AudioMeterView()
                        } label: {
                            Label("Input Level Meter", systemImage: "waveform")
                        }

                        VStack(alignment: .leading) {
                            HStack {
                                Text("TX Output Gain")
                                Spacer()
                                Text(String(format: "%.1fx", settings.outputGain))
                                    .foregroundColor(.secondary)
                            }
                            Slider(value: $settings.outputGain, in: 0.5...3.0, step: 0.1)
                        }

                        VStack(alignment: .leading) {
                            HStack {
                                Text("TX Preamble")
                                Spacer()
                                Text(settings.txPreambleMs == 0 ? "Off" : "\(settings.txPreambleMs) ms")
                                    .foregroundColor(.secondary)
                            }
                            Slider(
                                value: Binding(
                                    get: { Double(settings.txPreambleMs) },
                                    set: { settings.txPreambleMs = Int($0) }
                                ),
                                in: 0...500,
                                step: 50
                            )
                        }
                    } header: {
                        Text("Audio")
                    } footer: {
                        Text("Increase TX gain if VOX doesn't trigger. TX preamble sends idle data before transmission to allow VOX to key. Set to 0 if using hardware PTT.")
                    }
                }

                // Mode-specific settings
                if filterMode == nil {
                    // Full settings view - show all modes as navigation links
                    Section("Digital Modes") {
                        if shouldShowModeSettings(.rtty) {
                            NavigationLink {
                                RTTYSettingsView()
                            } label: {
                                Label("RTTY Settings", systemImage: "dot.radiowaves.left.and.right")
                            }
                        }

                        if shouldShowModeSettings(.psk31) {
                            NavigationLink {
                                PSK31SettingsView()
                            } label: {
                                Label("PSK Settings", systemImage: "waveform.path")
                            }
                        }

                        if shouldShowModeSettings(.olivia) {
                            NavigationLink {
                                Text("Olivia Settings - Coming Soon")
                                    .foregroundColor(.secondary)
                            } label: {
                                Label("Olivia Settings", systemImage: "waveform.circle")
                            }
                        }
                    }

                    Section {
                        Toggle(isOn: $settings.enablePSK31) {
                            Label("PSK31", systemImage: "waveform.path")
                        }
                        Toggle(isOn: $settings.enableBPSK63) {
                            Label("BPSK63", systemImage: "waveform.path")
                        }
                        Toggle(isOn: $settings.enableQPSK31) {
                            Label("QPSK31", systemImage: "waveform.path")
                        }
                        Toggle(isOn: $settings.enableQPSK63) {
                            Label("QPSK63", systemImage: "waveform.path")
                        }
                        Toggle(isOn: $settings.enableRattlegram) {
                            Label("Rattlegram", systemImage: "bolt.horizontal")
                        }
                    } header: {
                        HStack {
                            Text("Experimental Modes")
                            Text("BETA")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(4)
                        }
                    } footer: {
                        Text("These decoders are under development. Decode quality may be poor and transmissions may not be standards-compliant. Enable at your own risk.")
                    }

                    Section("Reference") {
                        NavigationLink {
                            FrequencyReferenceView(filterMode: nil)
                        } label: {
                            Label("Band Frequencies", systemImage: "list.bullet.rectangle")
                        }
                    }
                } else {
                    // Filtered view - show mode settings inline
                    if filterMode == .rtty {
                        rttySettingsInline
                    } else if filterMode?.isPSKMode == true {
                        pskSettingsInline
                    } else if filterMode == .olivia {
                        Section("Olivia Settings") {
                            Text("Coming Soon")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                if filterMode == nil {
                    Section("About") {
                        HStack {
                            Text("Version")
                            Spacer()
                            Text("1.1")
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    // MARK: - Inline Mode Settings

    @ViewBuilder
    private var rttySettingsInline: some View {
        Section("Baud Rate") {
            Picker("Baud Rate", selection: $settings.rttyBaudRate) {
                Text("45.45 Baud").tag(45.45)
                Text("50 Baud").tag(50.0)
                Text("75 Baud").tag(75.0)
            }
        }

        Section("Frequencies") {
            HStack {
                Text("Mark Frequency")
                Spacer()
                Text("\(Int(settings.rttyMarkFreq)) Hz")
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Shift")
                Spacer()
                Text("\(Int(settings.rttyShift)) Hz")
                    .foregroundColor(.secondary)
            }

            HStack {
                Text("Space Frequency")
                Spacer()
                Text("\(Int(settings.rttyMarkFreq - settings.rttyShift)) Hz")
                    .foregroundColor(.secondary)
            }
        }

        Section {
            Toggle("Invert Polarity", isOn: $settings.rttyPolarityInverted)

            VStack(alignment: .leading) {
                HStack {
                    Text("Frequency Offset")
                    Spacer()
                    Text("\(settings.rttyFrequencyOffset) Hz")
                        .foregroundColor(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(settings.rttyFrequencyOffset) },
                        set: { settings.rttyFrequencyOffset = Int($0) }
                    ),
                    in: -50...50,
                    step: 1
                )
            }
        } header: {
            Text("Decoder")
        } footer: {
            Text("These are global defaults. Individual channels can override these in the channel settings.")
        }

        Section {
            Picker("Squelch", selection: Binding(
                get: { SquelchLevel.closest(to: settings.rttySquelch) },
                set: { settings.rttySquelch = $0.rawValue }
            )) {
                ForEach(SquelchLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Squelch")
        } footer: {
            Text("Filters noise-induced false decodes. Higher values require stronger signals.")
        }

        Section {
            NavigationLink {
                FrequencyReferenceView(filterMode: .rtty)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Common RTTY Frequencies", systemImage: "list.bullet.rectangle")
                    CompactFrequencyReference(mode: .rtty)
                }
            }
        } header: {
            Text("Band Reference")
        }
    }

    @ViewBuilder
    private var pskSettingsInline: some View {
        Section {
            VStack(alignment: .leading) {
                HStack {
                    Text("Center Frequency")
                    Spacer()
                    Text("\(Int(settings.psk31CenterFreq)) Hz")
                        .foregroundColor(.secondary)
                }
                Slider(value: $settings.psk31CenterFreq, in: 500...2500, step: 50)
            }
        } header: {
            Text("Frequency")
        } footer: {
            Text("Audio frequency for transmit and single-channel receive.")
        }

        Section {
            Picker("Squelch", selection: Binding(
                get: { SquelchLevel.closest(to: settings.psk31Squelch) },
                set: { settings.psk31Squelch = $0.rawValue }
            )) {
                ForEach(SquelchLevel.allCases) { level in
                    Text(level.label).tag(level)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("Squelch")
        } footer: {
            Text("Filters noise-induced false decodes. Higher values require stronger signals.")
        }

        if let mode = filterMode {
            Section("Signal Parameters") {
                HStack {
                    Text("Baud Rate")
                    Spacer()
                    Text(mode.subtitle)
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Modulation")
                    Spacer()
                    Text(mode.rawValue.hasPrefix("Q") ? "QPSK" : "BPSK")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Encoding")
                    Spacer()
                    Text("Varicode")
                        .foregroundColor(.secondary)
                }
            }

            Section {
                NavigationLink {
                    FrequencyReferenceView(filterMode: mode)
                } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Common PSK Frequencies", systemImage: "list.bullet.rectangle")
                        CompactFrequencyReference(mode: mode)
                    }
                }
            } header: {
                Text("Band Reference")
            }
        }
    }

    private var locationStatusText: String {
        switch settings.locationStatus {
        case .unknown:
            return String(localized: "Unknown")
        case .denied:
            return String(localized: "Access Denied")
        case .updating:
            return String(localized: "Updating...")
        case .current:
            return "—"
        case .error(let message):
            return String(localized: "Error: \(message)")
        }
    }
}

// MARK: - Audio Meter View

struct AudioMeterView: View {
    @StateObject private var audioMeter = AudioMeterModel()
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        VStack(spacing: 24) {
            Text("Input Level")
                .font(.headline)

            // Level meter bar with noise floor indicator
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray5))

                    // Level indicator (dB-scaled so changes are visible)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(meterColor)
                        .frame(width: geometry.size.width * dbToPosition(audioMeter.displayDecibels))
                        .animation(.easeOut(duration: 0.15), value: audioMeter.displayDecibels)

                    // Noise floor threshold marker
                    if settings.noiseFloorThreshold > -60 {
                        let thresholdPosition = dbToPosition(settings.noiseFloorThreshold)
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: 2)
                            .offset(x: geometry.size.width * thresholdPosition - 1)

                        // Threshold zone (below threshold = suppressed)
                        Rectangle()
                            .fill(Color.orange.opacity(0.1))
                            .frame(width: geometry.size.width * thresholdPosition)
                    }

                    // Peak indicator
                    if audioMeter.peakDecibels > -55 {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2)
                            .offset(x: geometry.size.width * dbToPosition(audioMeter.peakDecibels) - 1)
                    }
                }
            }
            .frame(height: 32)
            .padding(.horizontal)

            // dB scale
            HStack {
                Text("-60")
                Spacer()
                Text("-40")
                Spacer()
                Text("-20")
                Spacer()
                Text("-10")
                Spacer()
                Text("0 dB")
            }
            .font(.caption2)
            .foregroundColor(.secondary)
            .padding(.horizontal)

            // Current level display
            Text(String(format: "%.1f dB", audioMeter.displayDecibels))
                .font(.system(.title, design: .monospaced))
                .foregroundColor(audioMeter.displayDecibels > -6 ? .red : .primary)

            // Noise floor section
            VStack(spacing: 12) {
                Divider()

                Text("Noise Floor Threshold")
                    .font(.headline)

                HStack {
                    Text("Current noise:")
                        .foregroundColor(.secondary)
                    Text(String(format: "%.1f dB", audioMeter.displayDecibels))
                        .font(.system(.body, design: .monospaced))
                }

                HStack {
                    Text("Threshold:")
                        .foregroundColor(.secondary)
                    Text(settings.noiseFloorThreshold <= -59 ? "Off" : String(format: "%.0f dB", settings.noiseFloorThreshold))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.orange)
                }

                // Set noise floor button - captures current level + small margin
                Button {
                    let margin = 3.0 // 3 dB above current noise
                    settings.noiseFloorThreshold = min(audioMeter.displayDecibels + margin, -3)
                } label: {
                    Label("Set Threshold to Current Level", systemImage: "hand.tap")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.orange)

                if settings.noiseFloorThreshold > -60 {
                    Button {
                        settings.noiseFloorThreshold = -60
                    } label: {
                        Label("Disable Threshold", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                }

                Text("With no signal on the radio, tap \"Set Threshold\" to capture the noise floor. Signals below this level will be ignored by decoders.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding()
        .navigationTitle("Input Level")
        .onAppear {
            audioMeter.startMonitoring()
        }
        .onDisappear {
            audioMeter.stopMonitoring()
        }
    }

    private var meterColor: Color {
        if audioMeter.displayDecibels > -3 {
            return .red
        } else if audioMeter.displayDecibels > -10 {
            return .yellow
        } else {
            return .green
        }
    }

    /// Convert dB value to 0.0-1.0 position (maps -60 to 0 dB)
    private func dbToPosition(_ db: Double) -> CGFloat {
        CGFloat(max(0, min(1, (db + 60) / 60)))
    }
}

// MARK: - Audio Meter Model

@MainActor
class AudioMeterModel: ObservableObject {
    // Raw values (updated frequently)
    private var rawLevel: CGFloat = 0
    private var rawDecibels: Double = -60

    // Smoothed display values (updated less frequently)
    @Published var displayLevel: CGFloat = 0
    @Published var displayDecibels: Double = -60
    @Published var peakLevel: CGFloat = 0
    @Published var peakDecibels: Double = -60

    private var isMonitoring = false
    private var sampleTask: Task<Void, Never>?
    private var displayTask: Task<Void, Never>?

    // Audio service for real input levels
    private let audioService = AudioService()

    // Smoothing parameters
    private let smoothingFactor: CGFloat = 0.3  // Higher = more responsive, lower = smoother

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // Start the audio service to get real input levels
        Task {
            do {
                try await audioService.start()
            } catch {
                print("[AudioMeterModel] Failed to start audio: \(error)")
            }
        }

        // Sample audio frequently (for accurate peak detection)
        sampleTask = Task {
            while isMonitoring {
                // Use real input level from AudioService
                let level = Double(audioService.inputLevel)

                rawLevel = CGFloat(level)
                rawDecibels = 20 * log10(max(level, 0.001))

                // Update peak immediately (peaks should be responsive)
                if rawLevel > peakLevel {
                    peakLevel = rawLevel
                }
                if rawDecibels > peakDecibels {
                    peakDecibels = rawDecibels
                }

                try? await Task.sleep(for: .milliseconds(30))
            }
        }

        // Update display values less frequently with smoothing
        displayTask = Task {
            while isMonitoring {
                // Exponential moving average for smooth display
                displayLevel = displayLevel + (rawLevel - displayLevel) * smoothingFactor
                displayDecibels = displayDecibels + (rawDecibels - displayDecibels) * Double(smoothingFactor)

                // Decay peak slowly
                peakLevel = max(0, peakLevel - 0.008)
                peakDecibels = max(-60, peakDecibels - 0.5)

                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stopMonitoring() {
        isMonitoring = false
        sampleTask?.cancel()
        displayTask?.cancel()
        sampleTask = nil
        displayTask = nil
        audioService.stop()
    }
}

// MARK: - RTTY Settings View

struct RTTYSettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        Form {
            Section("Baud Rate") {
                Picker("Baud Rate", selection: $settings.rttyBaudRate) {
                    Text("45.45 Baud").tag(45.45)
                    Text("50 Baud").tag(50.0)
                    Text("75 Baud").tag(75.0)
                }
            }

            Section("Frequencies") {
                HStack {
                    Text("Mark Frequency")
                    Spacer()
                    Text("\(Int(settings.rttyMarkFreq)) Hz")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Shift")
                    Spacer()
                    Text("\(Int(settings.rttyShift)) Hz")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Space Frequency")
                    Spacer()
                    Text("\(Int(settings.rttyMarkFreq - settings.rttyShift)) Hz")
                        .foregroundColor(.secondary)
                }
            }

            Section {
                Toggle("Invert Polarity", isOn: $settings.rttyPolarityInverted)

                VStack(alignment: .leading) {
                    HStack {
                        Text("Frequency Offset")
                        Spacer()
                        Text("\(settings.rttyFrequencyOffset) Hz")
                            .foregroundColor(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(settings.rttyFrequencyOffset) },
                            set: { settings.rttyFrequencyOffset = Int($0) }
                        ),
                        in: -50...50,
                        step: 1
                    )
                }
            } header: {
                Text("Decoder")
            } footer: {
                Text("These are global defaults. Individual channels can override these in the channel settings.")
            }

            Section {
                Picker("Squelch", selection: Binding(
                    get: { SquelchLevel.closest(to: settings.rttySquelch) },
                    set: { settings.rttySquelch = $0.rawValue }
                )) {
                    ForEach(SquelchLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Squelch")
            } footer: {
                Text("Filters noise-induced false decodes. Higher values require stronger signals.")
            }
        }
        .navigationTitle("RTTY Settings")
    }
}

// MARK: - PSK31 Settings View

struct PSK31SettingsView: View {
    @ObservedObject private var settings = SettingsManager.shared

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading) {
                    HStack {
                        Text("Center Frequency")
                        Spacer()
                        Text("\(Int(settings.psk31CenterFreq)) Hz")
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $settings.psk31CenterFreq, in: 500...2500, step: 50)
                }
            } header: {
                Text("Frequency")
            } footer: {
                Text("Audio frequency for transmit and single-channel receive. Multi-channel receive monitors a range of frequencies.")
            }

            Section {
                Picker("Squelch", selection: Binding(
                    get: { SquelchLevel.closest(to: settings.psk31Squelch) },
                    set: { settings.psk31Squelch = $0.rawValue }
                )) {
                    ForEach(SquelchLevel.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Squelch")
            } footer: {
                Text("Filters noise-induced false decodes. Higher values require stronger signals.")
            }

            Section("Signal Parameters") {
                HStack {
                    Text("Baud Rate")
                    Spacer()
                    Text("31.25 baud")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Modulation")
                    Spacer()
                    Text("BPSK")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Bandwidth")
                    Spacer()
                    Text("~31 Hz")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("Encoding")
                    Spacer()
                    Text("Varicode")
                        .foregroundColor(.secondary)
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("PSK31 is a narrow-band digital mode using phase-shift keying at 31.25 baud.")

                    Text("Unlike RTTY, PSK31 is case-sensitive and uses variable-length encoding where common characters require fewer bits.")

                    Text("The narrow bandwidth (~31 Hz) makes it excellent for weak-signal communication on crowded bands.")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            } header: {
                Text("About PSK31")
            }
        }
        .navigationTitle("PSK31 Settings")
    }
}

// MARK: - Frequency Reference Data

/// Amateur band with frequency range
struct AmateurBand: Identifiable {
    let id = UUID()
    let name: String           // e.g., "20m"
    let frequency: String      // e.g., "14 MHz"
    let rttyFreq: String?      // Calling frequency for RTTY
    let pskFreq: String?       // Calling frequency for PSK modes
    let oliviaFreq: String?    // Calling frequency for Olivia
    let notes: String?         // Additional notes
}

/// Common amateur band frequency reference
enum FrequencyReference {
    static let bands: [AmateurBand] = [
        AmateurBand(
            name: "160m",
            frequency: "1.8 MHz",
            rttyFreq: "1.800-1.810",
            pskFreq: "1.838",
            oliviaFreq: "1.838",
            notes: String(localized: "Night-time band, long-range")
        ),
        AmateurBand(
            name: "80m",
            frequency: "3.5 MHz",
            rttyFreq: "3.580-3.600",
            pskFreq: "3.580",
            oliviaFreq: "3.583",
            notes: String(localized: "Best at night, regional")
        ),
        AmateurBand(
            name: "40m",
            frequency: "7 MHz",
            rttyFreq: "7.080-7.100",
            pskFreq: "7.070",
            oliviaFreq: "7.073",
            notes: String(localized: "Day/night, very popular")
        ),
        AmateurBand(
            name: "30m",
            frequency: "10 MHz",
            rttyFreq: "10.140-10.150",
            pskFreq: "10.142",
            oliviaFreq: "10.145",
            notes: String(localized: "WARC band, no contests")
        ),
        AmateurBand(
            name: "20m",
            frequency: "14 MHz",
            rttyFreq: "14.080-14.099",
            pskFreq: "14.070",
            oliviaFreq: "14.073",
            notes: String(localized: "Primary DX band, daytime")
        ),
        AmateurBand(
            name: "17m",
            frequency: "18 MHz",
            rttyFreq: "18.100-18.109",
            pskFreq: "18.100",
            oliviaFreq: "18.103",
            notes: String(localized: "WARC band, daytime")
        ),
        AmateurBand(
            name: "15m",
            frequency: "21 MHz",
            rttyFreq: "21.080-21.100",
            pskFreq: "21.070",
            oliviaFreq: "21.073",
            notes: String(localized: "Daytime, solar-dependent")
        ),
        AmateurBand(
            name: "12m",
            frequency: "24 MHz",
            rttyFreq: "24.920-24.929",
            pskFreq: "24.920",
            oliviaFreq: "24.923",
            notes: String(localized: "WARC band, solar-dependent")
        ),
        AmateurBand(
            name: "10m",
            frequency: "28 MHz",
            rttyFreq: "28.080-28.100",
            pskFreq: "28.120",
            oliviaFreq: "28.123",
            notes: String(localized: "Daytime, solar maximum")
        ),
        AmateurBand(
            name: "6m",
            frequency: "50 MHz",
            rttyFreq: nil,
            pskFreq: "50.290",
            oliviaFreq: "50.293",
            notes: String(localized: "Sporadic E propagation")
        )
    ]

    /// Bands relevant for a specific mode
    static func bands(for mode: DigitalMode) -> [AmateurBand] {
        switch mode {
        case .rtty:
            return bands.filter { $0.rttyFreq != nil }
        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            return bands.filter { $0.pskFreq != nil }
        case .olivia:
            return bands.filter { $0.oliviaFreq != nil }
        case .rattlegram:
            return bands  // Rattlegram works on any band
        }
    }
}

// MARK: - Frequency Reference View

struct FrequencyReferenceView: View {
    var filterMode: DigitalMode?

    private var displayBands: [AmateurBand] {
        if let mode = filterMode {
            return FrequencyReference.bands(for: mode)
        }
        return FrequencyReference.bands
    }

    private var navigationTitle: String {
        if let mode = filterMode {
            return String(localized: "\(mode.displayName) Frequencies")
        }
        return String(localized: "Band Frequencies")
    }

    var body: some View {
        List {
            if filterMode == nil {
                Section {
                    Text("Common calling frequencies for digital modes on amateur HF bands. Frequencies shown in MHz.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            ForEach(displayBands) { band in
                Section {
                    BandFrequencyRow(band: band, filterMode: filterMode)
                } header: {
                    HStack {
                        Text(band.name)
                            .font(.headline)
                        Spacer()
                        Text(band.frequency)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                } footer: {
                    if let notes = band.notes {
                        Text(notes)
                    }
                }
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tips for Operating")
                        .font(.subheadline)
                        .fontWeight(.semibold)

                    tipRow(icon: "arrow.up.arrow.down", text: "USB mode on all HF bands")
                    tipRow(icon: "waveform", text: "Set radio dial to calling frequency, adjust audio tone to find activity")
                    tipRow(icon: "speaker.wave.2", text: "Keep audio levels moderate to avoid distortion")
                    tipRow(icon: "clock", text: "20m best during day, 40m/80m better at night")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }
        }
        .navigationTitle(navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func tipRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .frame(width: 16)
            Text(text)
        }
        .padding(.vertical, 2)
    }
}

struct BandFrequencyRow: View {
    let band: AmateurBand
    var filterMode: DigitalMode?

    var body: some View {
        if let mode = filterMode {
            // Show only the filtered mode's frequency
            HStack {
                Text("Calling Frequency")
                Spacer()
                Text(frequencyText(for: mode) ?? "—")
                    .foregroundColor(.secondary)
                    .font(.system(.body, design: .monospaced))
            }
        } else {
            // Show only enabled modes
            if ModeConfig.isEnabled(.rtty), let rttyFreq = band.rttyFreq {
                frequencyRow(mode: "RTTY", frequency: rttyFreq)
            }
            if ModeConfig.isEnabled(.psk31), let pskFreq = band.pskFreq {
                frequencyRow(mode: "PSK", frequency: pskFreq)
            }
            if ModeConfig.isEnabled(.olivia), let oliviaFreq = band.oliviaFreq {
                frequencyRow(mode: "Olivia", frequency: oliviaFreq)
            }
        }
    }

    private func frequencyText(for mode: DigitalMode) -> String? {
        switch mode {
        case .rtty:
            return band.rttyFreq
        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            return band.pskFreq
        case .olivia:
            return band.oliviaFreq
        case .rattlegram:
            return band.pskFreq  // Use PSK frequency as reference
        }
    }

    @ViewBuilder
    private func frequencyRow(mode: String, frequency: String) -> some View {
        HStack {
            Text(mode)
                .foregroundColor(.primary)
            Spacer()
            Text(frequency)
                .foregroundColor(.secondary)
                .font(.system(.body, design: .monospaced))
        }
    }
}

// MARK: - Compact Frequency Reference (for inline display)

struct CompactFrequencyReference: View {
    let mode: DigitalMode

    private var bands: [AmateurBand] {
        FrequencyReference.bands(for: mode)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(bands.prefix(5)) { band in
                HStack {
                    Text(band.name)
                        .frame(width: 40, alignment: .leading)
                        .foregroundColor(.secondary)
                    Text(frequencyText(for: band) ?? "—")
                        .font(.system(.caption, design: .monospaced))
                }
            }
            if bands.count > 5 {
                Text("+ \(bands.count - 5) more bands...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .font(.caption)
    }

    private func frequencyText(for band: AmateurBand) -> String? {
        switch mode {
        case .rtty:
            return band.rttyFreq
        case .psk31, .bpsk63, .qpsk31, .qpsk63:
            return band.pskFreq
        case .olivia:
            return band.oliviaFreq
        case .rattlegram:
            return band.pskFreq  // Use PSK frequency as reference
        }
    }
}

#Preview("Full Settings") {
    SettingsView(filterMode: nil)
}

#Preview("RTTY Settings") {
    SettingsView(filterMode: .rtty)
}

#Preview("PSK31 Settings") {
    SettingsView(filterMode: .psk31)
}

#Preview("Audio Meter") {
    NavigationStack {
        AudioMeterView()
    }
}

#Preview("Frequency Reference") {
    NavigationStack {
        FrequencyReferenceView(filterMode: nil)
    }
}

#Preview("PSK Frequency Reference") {
    NavigationStack {
        FrequencyReferenceView(filterMode: .psk31)
    }
}
