//
//  KitersApp.swift
//  Kiters Watch App
//
//  Created by avishay portal on 24/02/2026.
//

import SwiftUI

@main
struct Kiters_Watch_AppApp: App {
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var authService = AuthService()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sessionManager)
                .environmentObject(authService)
                .task {
                    // Dispatch to a background thread so the permission
                    // queries never block the main thread / home screen render.
                    await sessionManager.requestPermissionsOnLaunch()
                }
        }
    }
}
