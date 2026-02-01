//
//  SettingsView.swift
//  DigiModes
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = SettingsManager.shared
    var chatViewModel: ChatViewModel?

    var body: some View {
        NavigationStack {
            Form {
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

                Section("Audio") {
                    NavigationLink {
                        AudioMeterView()
                    } label: {
                        Label("Input Level Meter", systemImage: "waveform")
                    }
                }

                Section("Digital Modes") {
                    if ModeConfig.isEnabled(.rtty) {
                        NavigationLink {
                            RTTYSettingsView()
                        } label: {
                            Label("RTTY Settings", systemImage: "dot.radiowaves.left.and.right")
                        }
                    }

                    if ModeConfig.isEnabled(.psk31) {
                        NavigationLink {
                            Text("PSK31 Settings - Coming Soon")
                                .foregroundColor(.secondary)
                        } label: {
                            Label("PSK31 Settings", systemImage: "waveform.path")
                        }
                    }

                    if ModeConfig.isEnabled(.olivia) {
                        NavigationLink {
                            Text("Olivia Settings - Coming Soon")
                                .foregroundColor(.secondary)
                        } label: {
                            Label("Olivia Settings", systemImage: "waveform.circle")
                        }
                    }
                }

                if let viewModel = chatViewModel {
                    Section {
                        DebugAudioTestView(chatViewModel: viewModel)
                    } header: {
                        Text("Debug")
                    } footer: {
                        Text("Test the decoding pipeline with pre-generated RTTY audio files.")
                    }
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
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

    private var locationStatusText: String {
        switch settings.locationStatus {
        case .unknown:
            return "Unknown"
        case .denied:
            return "Access Denied"
        case .updating:
            return "Updating..."
        case .current:
            return "—"
        case .error(let message):
            return "Error: \(message)"
        }
    }
}

// MARK: - Audio Meter View

struct AudioMeterView: View {
    @StateObject private var audioMeter = AudioMeterModel()

    var body: some View {
        VStack(spacing: 24) {
            Text("Input Level")
                .font(.headline)

            // Level meter bar
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemGray5))

                    // Level indicator
                    RoundedRectangle(cornerRadius: 4)
                        .fill(meterColor)
                        .frame(width: geometry.size.width * audioMeter.displayLevel)
                        .animation(.easeOut(duration: 0.15), value: audioMeter.displayLevel)

                    // Peak indicator
                    if audioMeter.peakLevel > 0.01 {
                        Rectangle()
                            .fill(Color.white)
                            .frame(width: 2)
                            .offset(x: geometry.size.width * audioMeter.peakLevel - 1)
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

            Spacer()

            // Instructions
            VStack(spacing: 8) {
                Text("Adjust your radio's audio output")
                    .font(.subheadline)
                Text("Aim for peaks around -12 to -6 dB")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

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

    private var isMonitoring = false
    private var sampleTask: Task<Void, Never>?
    private var displayTask: Task<Void, Never>?

    // Smoothing parameters
    private let smoothingFactor: CGFloat = 0.3  // Higher = more responsive, lower = smoother

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        // Sample audio frequently (for accurate peak detection)
        sampleTask = Task {
            while isMonitoring {
                // TODO: Replace with real AVAudioEngine input metering
                // For now, simulate audio levels for UI development
                let baseLevel = Double.random(in: 0.15...0.35)
                let noise = Double.random(in: -0.05...0.05)
                let level = min(1.0, max(0.0, baseLevel + noise))

                rawLevel = CGFloat(level)
                rawDecibels = 20 * log10(max(level, 0.001))

                // Update peak immediately (peaks should be responsive)
                if rawLevel > peakLevel {
                    peakLevel = rawLevel
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
                VStack(alignment: .leading) {
                    Text("Squelch: \(Int(settings.rttySquelch * 100))%")
                    Slider(value: $settings.rttySquelch, in: 0...1)
                }
            } header: {
                Text("Squelch")
            } footer: {
                Text("Filters noise-induced false decodes. Higher values require stronger signals.")
            }
        }
        .navigationTitle("RTTY Settings")
    }
}

// MARK: - Debug Audio Test View

struct DebugAudioTestView: View {
    @ObservedObject var chatViewModel: ChatViewModel
    @State private var customPath: String = "/tmp/rtty_single_channel.wav"

    private let testFiles = [
        ("Single Channel (2125 Hz)", "/tmp/rtty_single_channel.wav"),
        ("Multi Channel", "/tmp/rtty_multi_channel.wav")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Pre-defined test files (works in Simulator with host Mac files)
            ForEach(testFiles, id: \.1) { name, path in
                testFileRow(name: name, path: path)
            }

            Divider()

            // Custom path input
            VStack(alignment: .leading, spacing: 4) {
                Text("Custom Path")
                    .font(.caption)
                    .foregroundColor(.secondary)
                HStack {
                    TextField("Path to WAV file", text: $customPath)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button("Test") {
                        chatViewModel.processTestAudioFile(at: customPath)
                    }
                    .disabled(chatViewModel.isProcessingTestAudio || customPath.isEmpty)
                    .buttonStyle(.bordered)
                }
            }

            if chatViewModel.isProcessingTestAudio {
                ProgressView(value: chatViewModel.testAudioProgress) {
                    Text("Processing...")
                        .font(.caption)
                }
            }
        }
    }

    @ViewBuilder
    private func testFileRow(name: String, path: String) -> some View {
        HStack {
            VStack(alignment: .leading) {
                Text(name)
                Text(path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if fileExists(at: path) {
                Button("Play") {
                    chatViewModel.processTestAudioFile(at: path)
                }
                .disabled(chatViewModel.isProcessingTestAudio)
                .buttonStyle(.bordered)
            } else {
                Text("Not found")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private func fileExists(at path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

#Preview {
    SettingsView()
}

#Preview("Audio Meter") {
    NavigationStack {
        AudioMeterView()
    }
}
