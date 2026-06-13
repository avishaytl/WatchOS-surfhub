//
//  ContentView.swift
//  iSurf-Watch
//
//  Main navigation view
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var authService: AuthService
    @State private var showingSportSelection = false

    var body: some View {
        NavigationView {
            if !authService.isSignedIn {
                AccountView()
            } else if sessionManager.isRecording {
                ActiveSessionView()
            } else {
                HomeView(showingSportSelection: $showingSportSelection)
            }
        }
        .sheet(isPresented: $showingSportSelection) {
            SportSelectionView(isPresented: $showingSportSelection)
        }
        .alert(
            L("session.upload_prompt_title"),
            isPresented: Binding(
                get: { sessionManager.pendingCloudUpload != nil },
                set: { isPresented in
                    if !isPresented {
                        sessionManager.keepPendingSessionLocal()
                    }
                }
            )
        ) {
            Button(L("session.keep_local"), role: .cancel) {
                sessionManager.keepPendingSessionLocal()
            }
            Button(L("session.upload_now")) {
                sessionManager.uploadPendingSessionToCloud()
            }
        } message: {
            Text(L("session.upload_prompt_message"))
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(SessionManager())
            .environmentObject(AuthService())
    }
}
