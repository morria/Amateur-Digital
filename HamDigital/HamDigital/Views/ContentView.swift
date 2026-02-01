//
//  ContentView.swift
//  DigiModes
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var viewModel: ChatViewModel
    @State private var showingSettings = false
    @State private var navigateToCompose: Channel?

    var body: some View {
        NavigationStack {
            ChannelListView()
                .overlay(alignment: .bottomTrailing) {
                    // Compose button in bottom right (like iMessage)
                    Button {
                        navigateToCompose = viewModel.getOrCreateComposeChannel()
                    } label: {
                        Image(systemName: "square.and.pencil")
                            .font(.title2)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .frame(width: 56, height: 56)
                            .background(Color.blue)
                            .clipShape(Circle())
                            .shadow(radius: 4)
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        ModePickerView()
                    }

                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    SettingsView(chatViewModel: viewModel)
                }
                .navigationDestination(item: $navigateToCompose) { channel in
                    ChannelDetailView(channel: channel)
                }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(ChatViewModel())
}
