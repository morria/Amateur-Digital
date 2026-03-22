//
//  FT8WaterfallBannerView.swift
//  AmateurDigital
//
//  Mini waterfall banner showing decoded FT8 stations as colored markers
//  positioned by audio frequency. CQ stations are highlighted green.
//  Tap a station to start a QSO.
//

import SwiftUI

/// A decoded FT8 station visible on the waterfall
struct FT8WaterfallStation: Identifiable, Equatable {
    let id: UUID
    let callsign: String
    let frequency: Int     // Audio frequency in Hz (200-3000)
    let snr: Int           // dB
    let isCQ: Bool         // True if this station is calling CQ

    init(
        id: UUID = UUID(),
        callsign: String,
        frequency: Int,
        snr: Int,
        isCQ: Bool = false
    ) {
        self.id = id
        self.callsign = callsign
        self.frequency = frequency
        self.snr = snr
        self.isCQ = isCQ
    }
}

struct FT8WaterfallBannerView: View {
    let stations: [FT8WaterfallStation]
    let onStationTapped: (FT8WaterfallStation) -> Void

    /// Frequency range for the waterfall display
    private let minFreq: Double = 200
    private let maxFreq: Double = 3000

    var body: some View {
        VStack(spacing: 0) {
            // Station markers
            GeometryReader { geo in
                ForEach(stations) { station in
                    stationMarker(station: station, totalWidth: geo.size.width)
                }
            }
            .frame(height: 28)

            // Frequency scale
            GeometryReader { geo in
                ZStack(alignment: .top) {
                    // Scale bar
                    Rectangle()
                        .fill(Color(.systemGray5))
                        .frame(height: 1)

                    // Tick marks and labels
                    ForEach([500, 1000, 1500, 2000, 2500], id: \.self) { freq in
                        VStack(spacing: 0) {
                            Rectangle()
                                .fill(Color(.systemGray4))
                                .frame(width: 1, height: 4)
                            Text("\(freq)")
                                .font(.system(size: 8, design: .monospaced))
                                .foregroundColor(Color(.systemGray3))
                        }
                        .position(
                            x: xPosition(for: freq, in: geo.size.width),
                            y: 8
                        )
                    }
                }
            }
            .frame(height: 16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("FT8 waterfall: \(stations.count) stations decoded")
    }

    // MARK: - Station Marker

    private func stationMarker(station: FT8WaterfallStation, totalWidth: CGFloat) -> some View {
        let x = xPosition(for: station.frequency, in: totalWidth)
        return Button {
            onStationTapped(station)
        } label: {
            VStack(spacing: 1) {
                Text(station.callsign)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(station.isCQ ? .green : .secondary)
                    .lineLimit(1)
                    .fixedSize()
                RoundedRectangle(cornerRadius: 1)
                    .fill(markerColor(for: station))
                    .frame(width: station.isCQ ? 12 : 8, height: 3)
                    .shadow(color: markerColor(for: station).opacity(0.6), radius: 2)
            }
        }
        .buttonStyle(.plain)
        .position(x: x, y: 14)
        .accessibilityLabel("\(station.callsign), \(String(format: "%+d", station.snr)) dB\(station.isCQ ? ", calling CQ" : "")")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Helpers

    private func xPosition(for frequency: Int, in width: CGFloat) -> CGFloat {
        let normalized = (Double(frequency) - minFreq) / (maxFreq - minFreq)
        return CGFloat(normalized) * width
    }

    private func markerColor(for station: FT8WaterfallStation) -> Color {
        if station.isCQ { return .green }
        return ft8SNRColor(station.snr)
    }
}

// MARK: - Sample Data

extension FT8WaterfallBannerView {
    static let sampleStations: [FT8WaterfallStation] = [
        FT8WaterfallStation(callsign: "K1ABC", frequency: 800, snr: -12, isCQ: true),
        FT8WaterfallStation(callsign: "W1AW", frequency: 1200, snr: -5),
        FT8WaterfallStation(callsign: "VE3XYZ", frequency: 1500, snr: -18, isCQ: true),
        FT8WaterfallStation(callsign: "JA1XX", frequency: 1900, snr: -8),
        FT8WaterfallStation(callsign: "G4ABC", frequency: 2200, snr: -22, isCQ: true),
        FT8WaterfallStation(callsign: "DL1ZZ", frequency: 2600, snr: 2),
    ]
}

// MARK: - Preview

#Preview {
    FT8WaterfallBannerView(stations: FT8WaterfallBannerView.sampleStations, onStationTapped: { _ in })
        .padding(.horizontal, 12)
}
