//
//  SPOTEQApp.swift
//  SPOTEQ Watch App
//
//  Created by avishay portal on 24/02/2026.
//

import SwiftUI

@main
struct SPOTEQ_Watch_AppApp: App {
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var authService = AuthService()
    @State private var showingSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                // ContentView is mounted from the first frame and the launch
                // permission work runs on its own schedule — the splash only
                // sits ON TOP. Gating the app behind it instead would push
                // every one of those into a cold start after the fade.
                ContentView()
                    .environmentObject(sessionManager)
                    .environmentObject(authService)
                    .task {
                        // Dispatch to a background thread so the permission
                        // queries never block the main thread / home screen render.
                        await sessionManager.requestPermissionsOnLaunch()
                    }

                if showingSplash {
                    SplashView()
                        .transition(.opacity)
                        .zIndex(1)
                        // A permission sheet can appear during the hold; the
                        // splash must not swallow the taps that answer it.
                        .allowsHitTesting(false)
                }
            }
            .task {
                try? await Task.sleep(for: .seconds(SplashView.totalSec))
                withAnimation(.easeInOut(duration: 0.28)) { showingSplash = false }
            }
        }
    }
}
