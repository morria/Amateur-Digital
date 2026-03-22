//
//  FT8QSOView.swift
//  AmateurDigital
//
//  Main FT8 conversation view — replaces ChatView for FT8 mode.
//  Shows alternating TX/RX exchanges with auto-sequencing control.
//

import SwiftUI

// MARK: - View Model

@MainActor
class FT8QSOViewModel: ObservableObject {
    @Published var theirCallsign: String
    @Published var theirGrid: String
    @Published var theirSNR: Int?
    @Published var ourSNR: Int?
    @Published var exchanges: [FT8Exchange]
    @Published var currentStep: Int
    @Published var autoSequenceEnabled = true
    @Published var nextMessage: String?
    @Published var countdownSeconds = 0
    @Published var isCountingDown = false
    @Published var frequencyHz: Int
    @Published var bandLabel: String
    @Published var waterfallStations: [FT8WaterfallStation]
    @Published var qsoComplete = false

    let myCallsign: String
    let myGrid: String
    private var countdownTimer: Timer?

    init(theirCallsign: String, theirGrid: String, theirSNR: Int? = nil,
         ourSNR: Int? = nil, exchanges: [FT8Exchange] = [], currentStep: Int = 0,
         frequencyHz: Int = 1500, bandLabel: String = "14.074 MHz",
         myCallsign: String = "W1AW", myGrid: String = "FN42",
         waterfallStations: [FT8WaterfallStation] = []) {
        self.theirCallsign = theirCallsign; self.theirGrid = theirGrid
        self.theirSNR = theirSNR; self.ourSNR = ourSNR
        self.exchanges = exchanges; self.currentStep = currentStep
        self.frequencyHz = frequencyHz; self.bandLabel = bandLabel
        self.myCallsign = myCallsign; self.myGrid = myGrid
        self.waterfallStations = waterfallStations
        if currentStep >= FT8QSOStep.allCases.count {
            self.qsoComplete = true; self.nextMessage = nil
        } else {
            self.nextMessage = Self.formatMessage(step: currentStep, myCall: myCallsign,
                myGrid: myGrid, theirCall: theirCallsign, theirSNR: theirSNR, ourSNR: ourSNR)
        }
    }

    static func formatMessage(step: Int, myCall: String, myGrid: String,
                              theirCall: String, theirSNR: Int?, ourSNR: Int?) -> String? {
        guard let s = FT8QSOStep(rawValue: step) else { return nil }
        let snr = theirSNR.map { String(format: "%+d", $0) } ?? "-15"
        let rSnr = ourSNR.map { String(format: "R%+d", $0) } ?? "R-12"
        switch s {
        case .cq:       return "CQ \(myCall) \(myGrid)"
        case .reply:    return "\(theirCall) \(myCall) \(myGrid)"
        case .report:   return "\(myCall) \(theirCall) \(snr)"
        case .rReport:  return "\(theirCall) \(myCall) \(rSnr)"
        case .rr73:     return "\(myCall) \(theirCall) RR73"
        case .seventy3: return "\(theirCall) \(myCall) 73"
        }
    }

    func startCountdown(seconds: Int = 12) {
        countdownSeconds = seconds; isCountingDown = true
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.countdownSeconds > 0 { self.countdownSeconds -= 1 }
                else { self.sendNextMessage() }
            }
        }
    }

    func cancelCountdown() {
        countdownTimer?.invalidate(); countdownTimer = nil
        isCountingDown = false; countdownSeconds = 0
    }

    func sendNextMessage() {
        cancelCountdown()
        guard let msg = nextMessage else { return }
        exchanges.append(FT8Exchange(timestamp: Date(), message: msg,
            direction: .tx, frequency: frequencyHz, transmitState: .sent))
        currentStep += 1
        if currentStep >= FT8QSOStep.allCases.count {
            qsoComplete = true; nextMessage = nil
        } else {
            nextMessage = Self.formatMessage(step: currentStep, myCall: myCallsign,
                myGrid: myGrid, theirCall: theirCallsign, theirSNR: theirSNR, ourSNR: ourSNR)
        }
    }

    deinit { countdownTimer?.invalidate() }
}

// MARK: - FT8 QSO View

struct FT8QSOView: View {
    @ObservedObject var viewModel: FT8QSOViewModel

    var body: some View {
        VStack(spacing: 0) {
            if !viewModel.waterfallStations.isEmpty {
                FT8WaterfallBannerView(stations: viewModel.waterfallStations, onStationTapped: { _ in })
                    .padding(.horizontal, 12).padding(.top, 4)
            }

            FT8QSOStatusView(currentStep: viewModel.currentStep)
                .padding(.horizontal, 16).padding(.vertical, 6)

            Divider()
            exchangeList
            Divider()
            controlPanel
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { toolbarHeader }
        }
    }

    // MARK: - Toolbar

    private var toolbarHeader: some View {
        VStack(spacing: 1) {
            HStack(spacing: 6) {
                Text(viewModel.theirCallsign).font(.headline)
                if let snr = viewModel.theirSNR {
                    Text(String(format: "%+d dB", snr))
                        .font(.caption).fontWeight(.semibold).monospacedDigit()
                        .foregroundColor(ft8SNRColor(snr))
                }
            }
            HStack(spacing: 8) {
                Text(viewModel.theirGrid)
                Text(viewModel.bandLabel)
                Text("\(viewModel.frequencyHz) Hz")
            }
            .font(.caption2).foregroundColor(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("QSO with \(viewModel.theirCallsign)")
    }

    // MARK: - Exchange List

    private var exchangeList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(viewModel.exchanges) { ex in
                        FT8MessageRow(exchange: ex).id(ex.id)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.9, anchor: ex.direction == .tx ? .bottomTrailing : .bottomLeading).combined(with: .opacity),
                                removal: .opacity))
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .animation(.spring(response: 0.35, dampingFraction: 0.75), value: viewModel.exchanges.count)
            }
            .onChange(of: viewModel.exchanges.count) { _, _ in
                if let last = viewModel.exchanges.last {
                    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    // MARK: - Control Panel

    private var controlPanel: some View {
        VStack(spacing: 8) {
            if viewModel.qsoComplete {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill").font(.title3).foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("QSO Complete").font(.subheadline).fontWeight(.semibold)
                        Text("\(viewModel.theirCallsign) logged at \(viewModel.bandLabel)")
                            .font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                }
                .padding(12).background(Color.green.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            } else if let nextMsg = viewModel.nextMessage {
                VStack(spacing: 8) {
                    // Next message + auto-sequence toggle
                    HStack(spacing: 8) {
                        Text("NEXT").font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundColor(.accentColor).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.accentColor.opacity(0.12)).clipShape(Capsule())
                        Text(nextMsg).font(.system(.callout, design: .monospaced)).fontWeight(.medium).lineLimit(1)
                        Spacer()
                        Button { viewModel.autoSequenceEnabled.toggle() } label: {
                            Image(systemName: viewModel.autoSequenceEnabled ? "bolt.fill" : "bolt.slash")
                                .font(.caption).foregroundColor(viewModel.autoSequenceEnabled ? .accentColor : .secondary)
                                .frame(width: 28, height: 28).background(Color(.systemGray6)).clipShape(Circle())
                        }
                        .accessibilityLabel(viewModel.autoSequenceEnabled ? "Auto-sequence on" : "Auto-sequence off")
                    }

                    // Action row: countdown or send button
                    HStack {
                        if viewModel.isCountingDown {
                            countdownView
                            Spacer()
                            Button { viewModel.cancelCountdown() } label: {
                                Text("Cancel").font(.subheadline).fontWeight(.semibold).foregroundColor(.primary)
                                    .padding(.horizontal, 20).padding(.vertical, 9)
                                    .background(Color(.systemGray5)).clipShape(Capsule())
                            }
                        } else {
                            Spacer()
                            Button { viewModel.sendNextMessage() } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 16))
                                    Text("Send Now").fontWeight(.semibold)
                                }
                                .font(.subheadline).foregroundColor(.white)
                                .padding(.horizontal, 20).padding(.vertical, 9)
                                .background(Color.accentColor).clipShape(Capsule())
                            }
                        }
                    }
                }
                .padding(12).background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: - Countdown

    private var countdownView: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color(.systemGray4), lineWidth: 2.5)
                Circle().trim(from: 0, to: CGFloat(viewModel.countdownSeconds) / 15.0)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: viewModel.countdownSeconds)
            }
            .frame(width: 24, height: 24)
            Text("TX in \(viewModel.countdownSeconds)s")
                .font(.system(.subheadline, design: .monospaced)).fontWeight(.semibold)
                .monospacedDigit().foregroundColor(.accentColor)
        }
    }
}

// MARK: - Sample Data & Previews

extension FT8QSOViewModel {
    @MainActor static var sampleMidQSO: FT8QSOViewModel {
        let t = Date().addingTimeInterval(-90)
        return FT8QSOViewModel(
            theirCallsign: "K1ABC", theirGrid: "FN31", theirSNR: -15, ourSNR: -12,
            exchanges: [
                FT8Exchange(timestamp: t, message: "CQ K1ABC FN31", direction: .rx, snr: -12),
                FT8Exchange(timestamp: t.addingTimeInterval(15), message: "K1ABC W1AW FN42", direction: .tx, transmitState: .sent),
                FT8Exchange(timestamp: t.addingTimeInterval(30), message: "W1AW K1ABC -15", direction: .rx, snr: -15),
            ],
            currentStep: 3, waterfallStations: FT8WaterfallBannerView.sampleStations)
    }

    @MainActor static var sampleCompleteQSO: FT8QSOViewModel {
        let t = Date().addingTimeInterval(-150)
        return FT8QSOViewModel(
            theirCallsign: "VE3XYZ", theirGrid: "EN82", theirSNR: -8, ourSNR: -5,
            exchanges: [
                FT8Exchange(timestamp: t, message: "CQ VE3XYZ EN82", direction: .rx, snr: -8),
                FT8Exchange(timestamp: t.addingTimeInterval(15), message: "VE3XYZ W1AW FN42", direction: .tx, transmitState: .sent),
                FT8Exchange(timestamp: t.addingTimeInterval(30), message: "W1AW VE3XYZ -08", direction: .rx, snr: -8),
                FT8Exchange(timestamp: t.addingTimeInterval(45), message: "VE3XYZ W1AW R-05", direction: .tx, transmitState: .sent),
                FT8Exchange(timestamp: t.addingTimeInterval(60), message: "W1AW VE3XYZ RR73", direction: .rx, snr: -7),
                FT8Exchange(timestamp: t.addingTimeInterval(75), message: "VE3XYZ W1AW 73", direction: .tx, transmitState: .sent),
            ],
            currentStep: 6)
    }

    @MainActor static var sampleCountdownQSO: FT8QSOViewModel {
        let t = Date().addingTimeInterval(-30)
        let vm = FT8QSOViewModel(
            theirCallsign: "JA1XX", theirGrid: "PM95", theirSNR: -18, ourSNR: -16,
            exchanges: [
                FT8Exchange(timestamp: t, message: "CQ JA1XX PM95", direction: .rx, snr: -18),
                FT8Exchange(timestamp: t.addingTimeInterval(15), message: "JA1XX W1AW FN42", direction: .tx, transmitState: .sent),
                FT8Exchange(timestamp: t.addingTimeInterval(30), message: "W1AW JA1XX -18", direction: .rx, snr: -18),
            ],
            currentStep: 3, frequencyHz: 1900)
        vm.isCountingDown = true; vm.countdownSeconds = 8
        return vm
    }
}

#Preview("Mid-QSO") { NavigationStack { FT8QSOView(viewModel: .sampleMidQSO) } }
#Preview("Complete") { NavigationStack { FT8QSOView(viewModel: .sampleCompleteQSO) } }
#Preview("Countdown") { NavigationStack { FT8QSOView(viewModel: .sampleCountdownQSO) } }
