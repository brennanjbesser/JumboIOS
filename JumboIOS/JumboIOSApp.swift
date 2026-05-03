//
//  JumboIOSApp.swift
//  JumboIOS
//
//  Created by Brennan Besser on 1/28/26.
//

import SwiftUI

@main
struct JumboIOSApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Hide scroll indicators globally — must run before views are created
        UIScrollView.appearance().showsVerticalScrollIndicator = false
        UIScrollView.appearance().showsHorizontalScrollIndicator = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    NotificationService.shared.requestPermission()
                    LiveScoreService.shared.start()
                }
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                LiveScoreService.shared.resume()
                // Force-resubscribe any active realtime chat channels.
                // Catches the case where the WebSocket dropped silently
                // while backgrounded; the per-channel status watcher
                // handles drops while the app is foregrounded.
                Task { @MainActor in
                    await RemoteChatService.shared.reconnectAllChannels()
                }
            case .background, .inactive:
                LiveScoreService.shared.pause()
            @unknown default:
                break
            }
        }
    }
}
