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
            Button(L("session.upload_now")) {
                if authService.isSignedIn {
                    sessionManager.uploadPendingSessionToCloud()
                } else {
                    sessionManager.notifySignInRequiredForUpload()
                }
            }
            Button(L("session.keep_local")) {
                sessionManager.keepPendingSessionLocal()
            }
            Button(L("session.discard"), role: .destructive) {
                sessionManager.discardPendingSession()
            }
        } message: {
            Text(L("session.upload_prompt_message"))
        }
        .alert(
            L(sessionManager.sessionNotice?.titleKey ?? "common.ok"),
            isPresented: Binding(
                get: { sessionManager.sessionNotice != nil && !sessionManager.isRecording },
                set: { isPresented in
                    if !isPresented {
                        sessionManager.sessionNotice = nil
                    }
                }
            )
        ) {
            Button(L("common.ok"), role: .cancel) {
                sessionManager.sessionNotice = nil
            }
        } message: {
            if let notice = sessionManager.sessionNotice {
                Text(L(notice.messageKey))
            }
        }
        .alert(
            L(authService.launchNotice?.titleKey ?? "common.ok"),
            isPresented: Binding(
                get: { authService.launchNotice != nil && !sessionManager.isRecording },
                set: { isPresented in
                    if !isPresented {
                        authService.launchNotice = nil
                    }
                }
            )
        ) {
            Button(L("common.ok"), role: .cancel) {
                authService.launchNotice = nil
            }
        } message: {
            if let notice = authService.launchNotice {
                if let arg = notice.messageArg {
                    Text(String(format: L(notice.messageKey), arg))
                } else {
                    Text(L(notice.messageKey))
                }
            }
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
