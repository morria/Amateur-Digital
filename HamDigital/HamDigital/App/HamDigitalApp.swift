//
//  HamDigitalApp.swift
//  Ham Digital
//
//  Amateur Radio Digital Modes Chat Application
//

import SwiftUI

@main
struct HamDigitalApp: App {
    @StateObject private var chatViewModel = ChatViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(chatViewModel)
        }
    }
}
