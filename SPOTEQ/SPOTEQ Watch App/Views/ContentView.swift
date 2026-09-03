//
//  ContentView.swift
//  SPOTEQ
//
//  Main navigation view
//

import SwiftUI

struct ContentView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @EnvironmentObject var authService: AuthService
    @Environment(\.scenePhase) private var scenePhase
    @State private var showingSportSelection = false
    @State private var activeAlert: ContentAlert?

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
        .onChange(of: authService.isSignedIn) { _, isSignedIn in
            if isSignedIn {
                sessionManager.retryPendingCloudUploadsAfterSignIn()
            }
            presentNextAlertIfNeeded()
        }
        .onAppear {
            sessionManager.handleAppBecameActive()
            presentNextAlertIfNeeded()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                sessionManager.handleAppBecameActive()
                presentNextAlertIfNeeded()
            }
        }
        .onChange(of: sessionManager.pendingCloudUpload?.id) { _, _ in
            presentNextAlertIfNeeded()
        }
        .onChange(of: sessionManager.sessionNotice?.id) { _, _ in
            presentNextAlertIfNeeded()
        }
        .onChange(of: authService.launchNotice?.id) { _, _ in
            presentNextAlertIfNeeded()
        }
        .onChange(of: sessionManager.isRecording) { _, isRecording in
            if isRecording {
                activeAlert = nil
            } else {
                presentNextAlertIfNeeded()
            }
        }
        // One alert coordinator prevents SwiftUI from letting the last of
        // several competing `.alert` modifiers suppress the upload prompt.
        .alert(
            activeAlertTitle,
            isPresented: Binding(
                get: { activeAlert != nil },
                set: { isPresented in
                    if !isPresented {
                        dismissActiveAlert()
                    }
                }
            )
        ) {
            switch activeAlert {
            case .pendingUpload:
                Button(L("session.upload_now")) {
                    uploadPendingSession()
                }
                .disabled(!sessionManager.canUploadPendingSession)

                Button(L("session.keep_local"), role: .cancel) {
                    keepPendingSessionForLater()
                }

            case .sessionNotice:
                Button(L("common.ok"), role: .cancel) {
                    dismissSessionNotice()
                }

            case .authNotice:
                Button(L("common.ok"), role: .cancel) {
                    dismissAuthNotice()
                }

            case nil:
                EmptyView()
            }
        } message: {
            Text(activeAlertMessage)
        }
    }

    private var activeAlertTitle: String {
        switch activeAlert {
        case .pendingUpload:
            return L("session.upload_prompt_title")
        case .sessionNotice(let notice):
            return L(notice.titleKey)
        case .authNotice(let notice):
            return L(notice.titleKey)
        case nil:
            return ""
        }
    }

    private var activeAlertMessage: String {
        switch activeAlert {
        case .pendingUpload:
            return L(sessionManager.canUploadPendingSession
                     ? "session.upload_prompt_message"
                     : "session.upload_offline_message")
        case .sessionNotice(let notice):
            return L(notice.messageKey)
        case .authNotice(let notice):
            if let arg = notice.messageArg {
                return String(format: L(notice.messageKey), arg)
            }
            return L(notice.messageKey)
        case nil:
            return ""
        }
    }

    private func presentNextAlertIfNeeded() {
        guard activeAlert == nil, !sessionManager.isRecording else { return }

        // Notices that explain account/storage state come first. The durable
        // upload candidate remains queued and is presented immediately after.
        if let notice = sessionManager.sessionNotice {
            activeAlert = .sessionNotice(notice)
        } else if let notice = authService.launchNotice {
            activeAlert = .authNotice(notice)
        } else if let pending = sessionManager.pendingCloudUpload {
            activeAlert = .pendingUpload(pending)
        }
    }

    private func dismissActiveAlert() {
        guard let alert = activeAlert else { return }
        activeAlert = nil
        switch alert {
        case .pendingUpload:
            sessionManager.keepPendingSessionLocal()
        case .sessionNotice:
            sessionManager.sessionNotice = nil
        case .authNotice:
            authService.launchNotice = nil
        }
        presentNextAlertOnNextRunLoop()
    }

    private func uploadPendingSession() {
        if authService.isSignedIn {
            sessionManager.uploadPendingSessionToCloud()
        } else {
            sessionManager.notifySignInRequiredForUpload()
        }
        activeAlert = nil
        presentNextAlertOnNextRunLoop()
    }

    private func keepPendingSessionForLater() {
        sessionManager.keepPendingSessionLocal()
        activeAlert = nil
        presentNextAlertOnNextRunLoop()
    }

    private func dismissSessionNotice() {
        sessionManager.sessionNotice = nil
        activeAlert = nil
        presentNextAlertOnNextRunLoop()
    }

    private func dismissAuthNotice() {
        authService.launchNotice = nil
        activeAlert = nil
        presentNextAlertOnNextRunLoop()
    }

    private func presentNextAlertOnNextRunLoop() {
        DispatchQueue.main.async {
            presentNextAlertIfNeeded()
        }
    }
}

private enum ContentAlert {
    case pendingUpload(PendingSessionCloudUpload)
    case sessionNotice(SessionUserNotice)
    case authNotice(AuthLaunchNotice)
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(SessionManager())
            .environmentObject(AuthService())
    }
}
