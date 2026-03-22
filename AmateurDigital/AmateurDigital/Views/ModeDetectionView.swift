//
//  ModeDetectionView.swift
//  AmateurDigital
//
//  Live mode detection view that listens to audio and shows ranked
//  mode likelihood with confidence bars and explanations.
//

import SwiftUI

#if canImport(AmateurDigitalCore)
import AmateurDigitalCore
#endif

struct ModeDetectionView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @Binding var navigationPath: NavigationPath
    @State private var expandedMode: String? = nil
    /// Frozen sort order while a row is expanded, so the list doesn't jump around
    @State private var frozenRankings: [ModeScore]? = nil
    @State private var frozenNoiseScore: NoiseScore? = nil

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                headerSection
                statusSection
                rankingsSection
                featuresSection
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 40)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Detect Mode")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            Task {
                await viewModel.startModeDetection()
            }
        }
        .onDisappear {
            viewModel.stopModeDetection()
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.15))
                    .frame(width: 72, height: 72)

                Image(systemName: statusIcon)
                    .font(.system(size: 32))
                    .foregroundStyle(statusColor.gradient)
                    .symbolEffect(.variableColor.iterative, isActive: viewModel.isModeDetectionActive)
            }

            Text(statusTitle)
                .font(.headline)
                .foregroundColor(.primary)

            Text(statusSubtitle)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 16)
    }

    private var statusColor: Color {
        guard let best = viewModel.modeDetectionResult?.bestMatch else { return .secondary }
        if best.confidence > 0.6 { return .green }
        if best.confidence > 0.3 { return .orange }
        return .secondary
    }

    private var statusIcon: String {
        if !viewModel.isListening { return "mic.slash" }
        if viewModel.modeDetectionResult == nil { return "waveform.badge.magnifyingglass" }
        guard let best = viewModel.modeDetectionResult?.bestMatch else { return "questionmark.circle" }
        if best.confidence > 0.3 { return "checkmark.circle" }
        return "questionmark.circle"
    }

    private var statusTitle: String {
        if !viewModel.isListening { return "Audio Not Active" }
        guard let result = viewModel.modeDetectionResult else { return "Listening..." }
        guard result.signalDetected, let best = result.bestMatch else { return "No Signal Detected" }
        return modeDisplayName(best.mode.rawValue)
    }

    private var statusSubtitle: String {
        if !viewModel.isListening { return "Start listening to detect modes" }
        guard let result = viewModel.modeDetectionResult else { return "Analyzing audio..." }
        guard result.signalDetected, let best = result.bestMatch else {
            return "Listening for digital mode signals"
        }
        let pct = Int(best.confidence * 100)
        return "\(pct)% confidence"
    }

    // MARK: - Status

    private var statusSection: some View {
        Group {
            if !viewModel.isListening {
                Button {
                    Task {
                        await viewModel.startModeDetection()
                    }
                } label: {
                    Label("Start Listening", systemImage: "mic")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    // MARK: - Rankings

    private var rankingsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Mode Rankings")
                .font(.headline)
                .padding(.leading, 4)

            if let result = viewModel.modeDetectionResult {
                // When a row is expanded, freeze the sort order so the list doesn't jump.
                let rankings = displayRankings(result: result)
                let displayNoise = displayNoiseScore(result: result)
                let noiseConf = displayNoise.confidence
                let noiseInsertIndex = rankings.firstIndex { $0.confidence < noiseConf } ?? rankings.count

                ForEach(Array(rankings.enumerated()), id: \.element.mode.rawValue) { index, score in
                    // Insert noise row at its ranked position
                    if index == noiseInsertIndex {
                        NoiseRankRow(
                            rank: noiseInsertIndex + 1,
                            noiseScore: displayNoise,
                            isExpanded: expandedMode == "_noise",
                            onTap: { toggleExpanded("_noise", result: result) }
                        )
                    }

                    // Use the LIVE score for this mode (updated confidence bar)
                    // but keep it in the FROZEN position
                    let liveScore = result.rankings.first { $0.mode == score.mode } ?? score
                    let currentRank = index >= noiseInsertIndex ? index + 2 : index + 1
                    ModeRankRow(
                        rank: currentRank,
                        score: liveScore,
                        isTop: currentRank == 1 && result.signalDetected,
                        isExpanded: expandedMode == score.mode.rawValue,
                        onTap: { toggleExpanded(score.mode.rawValue, result: result) },
                        onSelect: { selectMode(score.mode.rawValue) }
                    )
                }

                // Noise at the very end if it's the lowest
                if noiseInsertIndex >= rankings.count {
                    NoiseRankRow(
                        rank: rankings.count + 1,
                        noiseScore: displayNoise,
                        isExpanded: expandedMode == "_noise",
                        onTap: { toggleExpanded("_noise", result: result) }
                    )
                }
            } else {
                ForEach(0..<4, id: \.self) { _ in
                    PlaceholderRow()
                }
            }
        }
    }

    // MARK: - Features

    private var featuresSection: some View {
        Group {
            if let result = viewModel.modeDetectionResult, result.signalDetected {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Signal Details")
                        .font(.headline)
                        .padding(.leading, 4)

                    VStack(spacing: 0) {
                        featureRow("Bandwidth", "\(Int(result.features.occupiedBandwidth)) Hz")
                        Divider().padding(.leading, 16)
                        featureRow("Center Freq", "\(Int(result.features.occupiedCenter)) Hz")
                        Divider().padding(.leading, 16)
                        featureRow("Peaks", "\(result.features.peaks.count)")
                        Divider().padding(.leading, 16)
                        featureRow("Flatness", String(format: "%.3f", result.features.spectralFlatness))
                        Divider().padding(.leading, 16)
                        featureRow("FSK Pairs", "\(result.features.fskPairs.count)")
                        Divider().padding(.leading, 16)
                        featureRow("On-Off Keying", result.features.envelopeStats.hasOnOffKeying ? "Yes" : "No")
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(.systemBackground))
                    )
                }
            }
        }
    }

    private func featureRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.subheadline)
                .fontWeight(.medium)
                .fontDesign(.monospaced)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Frozen Sort Order

    private func displayRankings(result: ModeDetectionResult) -> [ModeScore] {
        if expandedMode != nil, let frozen = frozenRankings {
            return frozen
        }
        return result.rankings.filter { $0.confidence > 0.01 }
    }

    private func displayNoiseScore(result: ModeDetectionResult) -> NoiseScore {
        if expandedMode != nil, let frozen = frozenNoiseScore {
            return frozen
        }
        return result.noiseScore
    }

    // MARK: - Expand/Collapse

    private func toggleExpanded(_ key: String, result: ModeDetectionResult) {
        withAnimation(.easeInOut(duration: 0.2)) {
            if expandedMode == key {
                // Collapsing — unfreeze
                expandedMode = nil
                frozenRankings = nil
                frozenNoiseScore = nil
            } else {
                // Expanding — freeze the current sort order
                expandedMode = key
                frozenRankings = result.rankings.filter { $0.confidence > 0.01 }
                frozenNoiseScore = result.noiseScore
            }
        }
    }

    // MARK: - Mode Selection

    private func selectMode(_ rawValue: String) {
        guard let appMode = appDigitalMode(from: rawValue) else { return }
        viewModel.stopModeDetection()
        viewModel.selectedMode = appMode
        // Pop back to root, then push directly into the selected mode
        navigationPath.removeLast(navigationPath.count)
        navigationPath.append(appMode)
    }

    /// Map core library mode rawValue to app's DigitalMode
    private func appDigitalMode(from rawValue: String) -> DigitalMode? {
        DigitalMode.allCases.first { $0.rawValue == rawValue }
    }

    /// Map core library mode rawValue to display name
    private func modeDisplayName(_ rawValue: String) -> String {
        appDigitalMode(from: rawValue)?.displayName ?? rawValue
    }
}

// MARK: - Mode Rank Row

struct ModeRankRow: View {
    let rank: Int
    let score: ModeScore
    let isTop: Bool
    let isExpanded: Bool
    let onTap: () -> Void
    let onSelect: () -> Void

    private var modeColor: Color {
        switch score.mode.rawValue {
        case "RTTY": return .orange
        case "PSK31": return .blue
        case "BPSK63": return .cyan
        case "QPSK31": return .purple
        case "QPSK63": return .indigo
        case "CW": return .yellow
        case "JS8Call": return .mint
        case "Olivia": return .green
        default: return .gray
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    // Rank number
                    Text("\(rank)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(isTop ? .white : .secondary)
                        .frame(width: 24, height: 24)
                        .background(isTop ? modeColor : Color(.systemGray5))
                        .clipShape(Circle())

                    // Mode name
                    VStack(alignment: .leading, spacing: 2) {
                        Text(score.mode.rawValue)
                            .font(.headline)
                            .foregroundColor(.primary)

                        Text("\(Int(score.confidence * 100))% confidence")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Confidence bar
                    ConfidenceBar(confidence: score.confidence, color: modeColor)
                        .frame(width: 80, height: 8)

                    // Chevron
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    // Explanation
                    Text(score.explanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    // Evidence items
                    ForEach(Array(score.evidence.enumerated()), id: \.offset) { _, evidence in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: evidence.impact > 0 ? "plus.circle.fill" : evidence.impact < 0 ? "minus.circle.fill" : "circle")
                                .font(.caption)
                                .foregroundColor(evidence.impact > 0 ? .green : evidence.impact < 0 ? .red : .secondary)
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(evidence.label)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Spacer()
                                    let sign = evidence.impact >= 0 ? "+" : ""
                                    Text("\(sign)\(Int(evidence.impact * 100))%")
                                        .font(.caption)
                                        .fontDesign(.monospaced)
                                        .foregroundColor(evidence.impact > 0 ? .green : evidence.impact < 0 ? .red : .secondary)
                                }
                                Text(evidence.detail)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    // Use this mode button
                    Button(action: onSelect) {
                        Text("Use \(score.mode.rawValue)")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(modeColor)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
                .shadow(color: isTop ? modeColor.opacity(0.2) : .clear, radius: 4, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isTop ? modeColor.opacity(0.3) : .clear, lineWidth: 1)
        )
    }
}

// MARK: - Confidence Bar

struct ConfidenceBar: View {
    let confidence: Float
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.systemGray5))

                RoundedRectangle(cornerRadius: 4)
                    .fill(color.gradient)
                    .frame(width: geo.size.width * CGFloat(confidence))
            }
        }
    }
}

// MARK: - Noise Rank Row

struct NoiseRankRow: View {
    let rank: Int
    let noiseScore: NoiseScore
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    Text("\(rank)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(noiseScore.confidence > 0.5 ? .white : .secondary)
                        .frame(width: 24, height: 24)
                        .background(noiseScore.confidence > 0.5 ? Color.gray : Color(.systemGray5))
                        .clipShape(Circle())

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Noise / No Signal")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Text("\(Int(noiseScore.confidence * 100))% confidence")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    ConfidenceBar(confidence: noiseScore.confidence, color: .gray)
                        .frame(width: 80, height: 8)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(noiseScore.explanation)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(Array(noiseScore.evidence.enumerated()), id: \.offset) { _, evidence in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: evidence.impact > 0 ? "plus.circle.fill" : evidence.impact < 0 ? "minus.circle.fill" : "circle")
                                .font(.caption)
                                .foregroundColor(evidence.impact > 0 ? .green : evidence.impact < 0 ? .red : .secondary)
                                .frame(width: 16)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(evidence.label)
                                        .font(.caption)
                                        .fontWeight(.medium)
                                    Spacer()
                                    let sign = evidence.impact >= 0 ? "+" : ""
                                    Text("\(sign)\(Int(evidence.impact * 100))%")
                                        .font(.caption)
                                        .fontDesign(.monospaced)
                                        .foregroundColor(evidence.impact > 0 ? .green : evidence.impact < 0 ? .red : .secondary)
                                }
                                Text(evidence.detail)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
        )
    }
}

// MARK: - Placeholder Row

struct PlaceholderRow: View {
    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(Color(.systemGray5))
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.systemGray5))
                    .frame(width: 80, height: 14)
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color(.systemGray6))
                    .frame(width: 60, height: 10)
            }

            Spacer()

            RoundedRectangle(cornerRadius: 4)
                .fill(Color(.systemGray5))
                .frame(width: 80, height: 8)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
        )
        .redacted(reason: .placeholder)
    }
}
