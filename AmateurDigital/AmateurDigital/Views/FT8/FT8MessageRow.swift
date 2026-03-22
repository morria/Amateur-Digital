//
//  FT8MessageRow.swift
//  AmateurDigital
//
//  Single FT8 exchange row — compact, showing time, direction, message, and SNR.
//  FT8-specific data types are also defined here.
//

import SwiftUI

// MARK: - FT8 Data Types

/// One FT8 message exchange (a single 15-second transmission)
struct FT8Exchange: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let message: String        // e.g. "CQ K1ABC FN31"
    let direction: Direction
    let snr: Int?              // dB, only for received messages
    let frequency: Int         // Audio frequency in Hz
    var transmitState: TransmitState

    enum Direction: Equatable {
        case rx
        case tx
    }

    enum TransmitState: Equatable {
        case none       // RX message, no TX state
        case queued     // Waiting for TX window
        case sending    // Currently transmitting
        case sent       // Transmission complete
        case cancelled  // User cancelled
    }

    init(
        id: UUID = UUID(),
        timestamp: Date,
        message: String,
        direction: Direction,
        snr: Int? = nil,
        frequency: Int = 1500,
        transmitState: TransmitState = .none
    ) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
        self.direction = direction
        self.snr = snr
        self.frequency = frequency
        self.transmitState = transmitState
    }
}

/// The steps in a standard FT8 QSO sequence
enum FT8QSOStep: Int, CaseIterable {
    case cq = 0        // CQ K1ABC FN31
    case reply          // K1ABC W1AW FN42
    case report         // W1AW K1ABC -15
    case rReport        // K1ABC W1AW R-12
    case rr73           // W1AW K1ABC RR73
    case seventy3       // K1ABC W1AW 73

    var label: String {
        switch self {
        case .cq:       return "CQ"
        case .reply:    return "Grid"
        case .report:   return "SNR"
        case .rReport:  return "R+SNR"
        case .rr73:     return "RR73"
        case .seventy3: return "73"
        }
    }
}

// MARK: - Shared SNR Color Helper

/// Returns an appropriate color for an FT8 signal-to-noise ratio value.
/// Green for strong (>= 0 dB), yellow for moderate, orange for weak, red for marginal.
func ft8SNRColor(_ snr: Int) -> Color {
    if snr >= 0 { return .green }
    if snr >= -10 { return .yellow }
    if snr >= -18 { return .orange }
    return .red
}

// MARK: - FT8 Message Row View

struct FT8MessageRow: View {
    let exchange: FT8Exchange

    private var isRX: Bool { exchange.direction == .rx }

    /// Static UTC time formatter — created once, reused across all rows
    private static let utcTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    private var timeString: String {
        Self.utcTimeFormatter.string(from: exchange.timestamp)
    }

    private var bubbleColor: Color {
        if isRX {
            return Color(.systemGray5)
        }
        switch exchange.transmitState {
        case .queued:    return Color(.systemGray4)
        case .sending:   return Color.orange
        case .sent:      return Color.accentColor
        case .cancelled: return Color(.systemGray4)
        case .none:      return Color.accentColor
        }
    }

    private var textColor: Color {
        isRX ? .primary : .white
    }

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if !isRX { Spacer(minLength: 32) }

            VStack(alignment: isRX ? .leading : .trailing, spacing: 3) {
                // Metadata line: direction badge, time, SNR/state
                HStack(spacing: 4) {
                    if isRX {
                        directionBadge
                        timeLabel
                        snrLabel
                    } else {
                        txStateLabel
                        timeLabel
                        directionBadge
                    }
                }

                // Message bubble
                Text(exchange.message)
                    .font(.system(.callout, design: .monospaced))
                    .fontWeight(.medium)
                    .foregroundColor(textColor)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(bubbleColor)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = exchange.message
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)

            if isRX { Spacer(minLength: 32) }
        }
    }

    // MARK: - Subviews

    private var directionBadge: some View {
        Text(isRX ? "RX" : "TX")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(isRX ? .green : .accentColor)
    }

    private var timeLabel: some View {
        Text(timeString)
            .font(.system(size: 10, design: .monospaced))
            .foregroundColor(.secondary)
    }

    @ViewBuilder
    private var snrLabel: some View {
        if let snr = exchange.snr {
            Text(String(format: "%+d dB", snr))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(ft8SNRColor(snr))
        }
    }

    @ViewBuilder
    private var txStateLabel: some View {
        switch exchange.transmitState {
        case .queued:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundColor(.secondary)
        case .sending:
            ProgressView()
                .scaleEffect(0.5)
        case .cancelled:
            Image(systemName: "xmark.circle")
                .font(.caption2)
                .foregroundColor(.secondary)
        default:
            EmptyView()
        }
    }

    // MARK: - Accessibility

    private var accessibilityText: String {
        let dir = isRX ? "Received" : "Transmitted"
        let snrText = exchange.snr.map { String(format: " at %+d dB", $0) } ?? ""
        return "\(dir) at \(timeString)\(snrText): \(exchange.message)"
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 12) {
        FT8MessageRow(exchange: FT8Exchange(timestamp: Date(), message: "CQ K1ABC FN31", direction: .rx, snr: -12))
        FT8MessageRow(exchange: FT8Exchange(timestamp: Date(), message: "K1ABC W1AW FN42", direction: .tx, transmitState: .sent))
        FT8MessageRow(exchange: FT8Exchange(timestamp: Date(), message: "W1AW K1ABC -15", direction: .rx, snr: -15))
        FT8MessageRow(exchange: FT8Exchange(timestamp: Date(), message: "K1ABC W1AW R-08", direction: .tx, transmitState: .queued))
    }
    .padding()
}
