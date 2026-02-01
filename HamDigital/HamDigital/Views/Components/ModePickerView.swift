//
//  ModePickerView.swift
//  DigiModes
//

import SwiftUI

struct ModePickerView: View {
    @EnvironmentObject var viewModel: ChatViewModel

    var body: some View {
        Menu {
            ForEach(ModeConfig.allEnabledModes) { mode in
                Button {
                    viewModel.selectedMode = mode
                } label: {
                    HStack {
                        Text(mode.displayName)
                        if viewModel.selectedMode == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(viewModel.selectedMode.rawValue)
                Image(systemName: "chevron.down")
                    .font(.caption2)
            }
        }
    }
}

#Preview {
    ModePickerView()
        .environmentObject(ChatViewModel())
}
