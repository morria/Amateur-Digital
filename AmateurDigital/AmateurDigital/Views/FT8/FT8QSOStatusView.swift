//
//  FT8QSOStatusView.swift
//  AmateurDigital
//
//  Horizontal progress indicator showing position in the FT8 QSO sequence.
//  Completed steps show a checkmark, the current step is highlighted, future
//  steps are dimmed.
//

import SwiftUI

struct FT8QSOStatusView: View {
    /// Current step index (0-based). Steps before this are complete.
    let currentStep: Int

    private let steps = FT8QSOStep.allCases
    private let circleSize: CGFloat = 16

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                // Step circle + label
                VStack(spacing: 2) {
                    stepIcon(for: index)
                        .frame(width: circleSize, height: circleSize)
                    Text(step.label)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundColor(labelColor(for: index))
                        .fixedSize()
                }
                .frame(minWidth: 32)

                // Connector line between steps
                if index < steps.count - 1 {
                    connectorLine(completed: index < currentStep)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Step Icons

    @ViewBuilder
    private func stepIcon(for index: Int) -> some View {
        if index < currentStep {
            // Completed
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: circleSize))
                .foregroundColor(.accentColor)
        } else if index == currentStep {
            // Current — filled circle with pulse ring
            ZStack {
                Circle()
                    .fill(Color.accentColor)
                Circle()
                    .stroke(Color.accentColor.opacity(0.3), lineWidth: 2)
                    .frame(width: circleSize + 4, height: circleSize + 4)
            }
        } else {
            // Future — hollow circle
            Circle()
                .stroke(Color(.systemGray4), lineWidth: 1.5)
        }
    }

    // MARK: - Connector

    private func connectorLine(completed: Bool) -> some View {
        Rectangle()
            .fill(completed ? Color.accentColor : Color(.systemGray4))
            .frame(height: 2)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Helpers

    private func labelColor(for index: Int) -> Color {
        if index < currentStep { return .accentColor }
        if index == currentStep { return .primary }
        return Color(.systemGray3)
    }

    private var accessibilityText: String {
        if currentStep >= steps.count {
            return "QSO complete, all \(steps.count) steps finished"
        }
        return "QSO progress: step \(currentStep + 1) of \(steps.count), \(steps[currentStep].label)"
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 20) {
        FT8QSOStatusView(currentStep: 0)
        FT8QSOStatusView(currentStep: 3)
        FT8QSOStatusView(currentStep: 6)
    }
    .padding()
}
