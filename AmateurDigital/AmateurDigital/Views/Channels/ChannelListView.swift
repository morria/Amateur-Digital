//
//  ChannelListView.swift
//  DigiModes
//
//  List of all detected channels with navigation to detail
//

import SwiftUI

struct ChannelListView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var channelForSettings: Channel?

    var body: some View {
        let visibleChannels = viewModel.channels.filter { $0.hasContent }
        Group {
            if visibleChannels.isEmpty {
                VStack(spacing: 16) {
                    if viewModel.isListening {
                        // Actively listening
                        viewModel.selectedMode.iconImage
                            .font(.system(size: 48))
                            .foregroundColor(viewModel.selectedMode.color)
                        Text("Listening...")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text("No signals decoded yet. Monitoring for \(viewModel.selectedMode.displayName) transmissions.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                    } else if let error = viewModel.audioError {
                        // Audio error
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)
                        Text("Audio Error")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text(error)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 40)
                        Button("Retry") {
                            Task {
                                await viewModel.startAudioService()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 8)
                    } else {
                        // Not listening yet
                        viewModel.selectedMode.iconImage
                            .font(.system(size: 48))
                            .foregroundColor(viewModel.selectedMode.color.opacity(0.5))
                        Text("Starting...")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text("Initializing \(viewModel.selectedMode.displayName) decoder...")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(visibleChannels.sorted { $0.frequency < $1.frequency }) { channel in
                        NavigationLink(value: channel) {
                            ChannelRowView(channel: channel)
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                viewModel.deleteChannel(channel)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                channelForSettings = channel
                            } label: {
                                Label("Settings", systemImage: "slider.horizontal.3")
                            }
                            .tint(.gray)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .sheet(item: $channelForSettings) { channel in
            ChannelSettingsSheet(channel: channel, viewModel: viewModel)
                .id(channel.id) // Force recreation to ensure onAppear fires
        }
    }
}

// MARK: - Channel Settings Sheet

struct ChannelSettingsSheet: View {
    let channelID: UUID
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject private var settings = SettingsManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var squelch: Double = 0
    @State private var baudRate: Double = 45.45
    @State private var polarityInverted: Bool = false
    @State private var frequencyOffset: Double = 0
    @State private var cwWPM: Double = 20.0
    @State private var cwToneFrequency: Double = 700.0

    /// Look up current channel from viewModel to get live data
    private var channel: Channel? {
        viewModel.channels.first { $0.id == channelID }
    }

    /// Whether to show RTTY-specific settings
    private var isRTTY: Bool {
        viewModel.selectedMode == .rtty
    }

    /// Whether to show CW-specific settings
    private var isCW: Bool {
        viewModel.selectedMode == .cw
    }

    /// Whether baud rate differs from global setting
    private var baudRateOverridden: Bool {
        baudRate != settings.rttyBaudRate
    }

    /// Whether polarity differs from global setting
    private var polarityOverridden: Bool {
        polarityInverted != settings.rttyPolarityInverted
    }

    /// Whether frequency offset differs from global setting
    private var offsetOverridden: Bool {
        Int(frequencyOffset) != settings.rttyFrequencyOffset
    }

    init(channel: Channel, viewModel: ChatViewModel) {
        self.channelID = channel.id
        self.viewModel = viewModel
    }

    var body: some View {
        NavigationStack {
            if let channel = channel {
                Form {
                    Section {
                        HStack {
                            Text("Frequency")
                            Spacer()
                            Text(channel.frequencyOffsetDisplay)
                                .foregroundColor(.secondary)
                        }

                        if let callsign = channel.callsign {
                            HStack {
                                Text("Callsign")
                                Spacer()
                                Text(callsign)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }

                    Section {
                        Picker("Squelch", selection: Binding(
                            get: { SquelchLevel.closest(to: squelch / 100.0) },
                            set: { level in
                                squelch = level.rawValue * 100.0
                                saveSquelch(Int(level.rawValue * 100.0))
                            }
                        )) {
                            ForEach(SquelchLevel.allCases) { level in
                                Text(level.label).tag(level)
                            }
                        }
                        .pickerStyle(.segmented)
                    } header: {
                        Text("Signal Threshold")
                    } footer: {
                        Text("Higher values require stronger signals before decoding. Off decodes all signals.")
                    }

                    if isRTTY {
                        Section {
                            Picker("Baud Rate", selection: $baudRate) {
                                Text("45.45").tag(45.45)
                                Text("50").tag(50.0)
                                Text("75").tag(75.0)
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: baudRate) { _, newValue in
                                viewModel.setChannelBaudRate(newValue, for: channelID)
                            }

                            if baudRateOverridden {
                                Button("Reset to Global") {
                                    baudRate = settings.rttyBaudRate
                                    viewModel.setChannelBaudRate(settings.rttyBaudRate, for: channelID)
                                }
                                .font(.caption)
                            }
                        } header: {
                            HStack {
                                Text("Baud Rate")
                                if baudRateOverridden {
                                    Text("overridden")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                        } footer: {
                            Text("45.45 is standard amateur RTTY. 50 baud is common in Europe. Global default: \(settings.rttyBaudRate == 45.45 ? "45.45" : "\(Int(settings.rttyBaudRate))") baud.")
                        }

                        Section {
                            Toggle("Invert Polarity", isOn: $polarityInverted)
                                .onChange(of: polarityInverted) { _, newValue in
                                    viewModel.setChannelPolarity(inverted: newValue, for: channelID)
                                }

                            if polarityOverridden {
                                Button("Reset to Global") {
                                    polarityInverted = settings.rttyPolarityInverted
                                    viewModel.setChannelPolarity(inverted: settings.rttyPolarityInverted, for: channelID)
                                }
                                .font(.caption)
                            }
                        } header: {
                            HStack {
                                Text("Polarity")
                                if polarityOverridden {
                                    Text("overridden")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                        } footer: {
                            Text("Swap mark and space tones. Try this if you see garbled text from a station.")
                        }

                        Section {
                            HStack {
                                Text("\(Int(frequencyOffset)) Hz")
                                    .monospacedDigit()
                                    .frame(width: 56, alignment: .trailing)
                                Slider(value: $frequencyOffset, in: -50...50, step: 1)
                                    .onChange(of: frequencyOffset) { _, newValue in
                                        viewModel.setChannelFrequencyOffset(Int(newValue), for: channelID)
                                    }
                                Button("Reset") {
                                    frequencyOffset = Double(settings.rttyFrequencyOffset)
                                    viewModel.setChannelFrequencyOffset(settings.rttyFrequencyOffset, for: channelID)
                                }
                                .buttonStyle(.borderless)
                                .disabled(!offsetOverridden)
                            }
                        } header: {
                            HStack {
                                Text("Frequency Offset")
                                if offsetOverridden {
                                    Text("overridden")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                        } footer: {
                            Text("Fine-tune the receive frequency to improve decoding. Global default: \(settings.rttyFrequencyOffset) Hz.")
                        }
                    }

                    if isCW {
                        Section {
                            VStack(alignment: .leading) {
                                HStack {
                                    Text("TX Speed")
                                    Spacer()
                                    Text("\(Int(cwWPM)) WPM")
                                        .foregroundColor(.secondary)
                                }
                                Slider(value: $cwWPM, in: 5...45, step: 1)
                                    .onChange(of: cwWPM) { _, newValue in
                                        saveCWWPM(newValue)
                                    }
                            }

                            if cwWPM != settings.cwWPM {
                                Button("Reset to Global (\(Int(settings.cwWPM)) WPM)") {
                                    cwWPM = settings.cwWPM
                                    saveCWWPM(settings.cwWPM)
                                }
                                .font(.caption)
                            }
                        } header: {
                            HStack {
                                Text("CW Speed")
                                if cwWPM != settings.cwWPM {
                                    Text("overridden")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                        } footer: {
                            Text("TX speed for this conversation. RX adapts automatically to the sender's speed.")
                        }

                        Section {
                            VStack(alignment: .leading) {
                                HStack {
                                    Text("Tone Frequency")
                                    Spacer()
                                    Text("\(Int(cwToneFrequency)) Hz")
                                        .foregroundColor(.secondary)
                                }
                                Slider(value: $cwToneFrequency, in: 400...1200, step: 50)
                                    .onChange(of: cwToneFrequency) { _, newValue in
                                        saveCWToneFrequency(newValue)
                                    }
                            }

                            if cwToneFrequency != settings.cwToneFrequency {
                                Button("Reset to Global (\(Int(settings.cwToneFrequency)) Hz)") {
                                    cwToneFrequency = settings.cwToneFrequency
                                    saveCWToneFrequency(settings.cwToneFrequency)
                                }
                                .font(.caption)
                            }
                        } header: {
                            HStack {
                                Text("Tone Frequency")
                                if cwToneFrequency != settings.cwToneFrequency {
                                    Text("overridden")
                                        .font(.caption2)
                                        .foregroundColor(.orange)
                                }
                            }
                        } footer: {
                            Text("CW sidetone frequency. AFC tracks ±200 Hz from this setting.")
                        }
                    }
                }
                .navigationTitle("Channel Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            } else {
                ContentUnavailableView("Channel Not Found", systemImage: "exclamationmark.triangle")
            }
        }
        .presentationDetents([(isRTTY || isCW) ? .large : .medium])
        .onAppear {
            // Load current values when sheet appears
            if let channel = channel {
                squelch = Double(channel.squelch)
                baudRate = channel.rttyBaudRate
                polarityInverted = channel.polarityInverted
                frequencyOffset = Double(channel.frequencyOffset)
                cwWPM = channel.cwWPM
                cwToneFrequency = channel.cwToneFrequency
                print("[ChannelSettings] Loaded settings for channel \(channelID)")
            }
        }
    }

    private func saveSquelch(_ value: Int) {
        if let index = viewModel.channels.firstIndex(where: { $0.id == channelID }) {
            viewModel.channels[index].squelch = value
        }
    }

    private func saveCWWPM(_ value: Double) {
        if let index = viewModel.channels.firstIndex(where: { $0.id == channelID }) {
            viewModel.channels[index].cwWPM = value
        }
    }

    private func saveCWToneFrequency(_ value: Double) {
        if let index = viewModel.channels.firstIndex(where: { $0.id == channelID }) {
            viewModel.channels[index].cwToneFrequency = value
        }
    }
}

#Preview {
    NavigationStack {
        ChannelListView()
            .environmentObject(ChatViewModel())
    }
}
