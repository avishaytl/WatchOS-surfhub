//
//  HomeView.swift
//  iSurf-Watch
//
//  Home screen with start button and recent sessions
//

import SwiftUI

struct HomeView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @Binding var showingSportSelection: Bool
    @State private var sessions: [Session] = []
    @State private var showingSettings = false
    @State private var showingPermissionAlert = false
    @State private var waitingForPermission = false
    @State private var gpsPulse = false
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appTheme") private var appTheme: String = "orange"
    @AppStorage("appLanguage") private var languageCode: String = "en"

    private let storageManager = StorageManager()

    /// Localized one-word GPS signal status for the Home indicator.
    private var gpsStatusText: String {
        switch sessionManager.gpsSignalQuality {
        case .none:   return L("gps.signal_none")
        case .weak:   return L("gps.signal_weak")
        case .fair:   return L("gps.signal_fair")
        case .good:   return L("gps.signal_good")
        case .strong: return L("gps.signal_strong")
        }
    }
    
    private var themeColor: Color {
        switch appTheme {
        case "yellow": return .yellow
        case "green":  return .green
        case "red":    return .red
        case "orange": return .orange
        case "cyan":   return .cyan
        case "pink":   return .pink
        default:       return .orange
        }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // GPS status — live while Home is foregrounded (GPS prewarm).
                // Mirrors the indicator shown during an active session so the
                // user can confirm a fix before starting.
                HStack(spacing: 6) {
                    GPSTrackerIndicator(
                        signalQuality: sessionManager.gpsSignalQuality,
                        pointCount: sessionManager.gpsPointCount,
                        isActive: sessionManager.isGPSActive,
                        gpsPulse: $gpsPulse
                    )
                    Text(gpsStatusText)
                        .font(.caption2)
                        .foregroundColor(.gray)
                    Spacer()
                    if sessionManager.lastGPSAccuracy > 0 {
                        Text("±\(Int(sessionManager.lastGPSAccuracy))m")
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundColor(.gray)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 4)

                // Start Session Button
                Button(action: {
                    handleStartTapped()
                }) {
                    VStack(spacing: 8) {
                        if waitingForPermission {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            Text(L("permissions.waiting"))
                                .font(.caption)
                        } else {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 40))
                            Text(L("home.start_session"))
                                .font(.headline)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(waitingForPermission ? Color.gray : themeColor)
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                .disabled(waitingForPermission)
                
                // Settings button
                NavigationLink(destination: SettingsView()) {
                    HStack {
                        Image(systemName: "gear")
                            .font(.system(size: 18))
                        Text(L("home.settings"))
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.gray.opacity(0.3))
                    .foregroundColor(.white)
                    .cornerRadius(12)
                }
                .buttonStyle(.plain)
                
                // Recent sessions
                if !sessions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("home.recent_sessions"))
                            .font(.caption)
                            .foregroundColor(.gray)
                        
                        ForEach(sessions.prefix(3)) { session in
                            NavigationLink(destination: SessionDetailView(session: session)) {
                                SessionRowView(session: session)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding()
        }
        // .watchScrollTopShadow()
        .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
        .onAppear {
            loadSessions()
            sessionManager.prewarmGPS()
        }
        .onDisappear {
            sessionManager.stopGPSPrewarm()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:   sessionManager.prewarmGPS()
            case .background, .inactive: sessionManager.stopGPSPrewarm()
            @unknown default: break
            }
        }
        .onChange(of: sessionManager.locationAuthStatus) { oldStatus, newStatus in
            guard waitingForPermission else { return }
            if newStatus == .authorizedWhenInUse || newStatus == .authorizedAlways {
                // Permission granted! Start session
                waitingForPermission = false
                showingSportSelection = true
            } else if newStatus == .denied || newStatus == .restricted {
                // Permission denied
                waitingForPermission = false
                showingPermissionAlert = true
            }
        }
        .alert(L("permissions.denied.title"), isPresented: $showingPermissionAlert) {
            Button(L("common.ok"), role: .cancel) { }
        } message: {
            Text(L("permissions.denied.message"))
        }
    }
    
    private func handleStartTapped() {
        guard !waitingForPermission else { return }

        // Location improves the session, but it should never block recording.
        // If permission is still undecided, ask for it and continue into sport
        // selection; denied/restricted users can still record from motion data.
        if sessionManager.isLocationNotDetermined {
            sessionManager.requestLocationPermission()
        }
        showingSportSelection = true
    }
    
    private func loadSessions() {
        sessions = storageManager.loadAllSessions()
    }
}

struct SessionRowView: View {
    let session: Session
    @AppStorage("appLanguage") private var languageCode: String = "en"
    
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Top row: Sport name and jumps count
            HStack {
                Text(sportDisplayName)
                    .font(.caption2)
                    .foregroundColor(.gray)
                
                Spacer()
                
                HStack(spacing: 3) {
                    Text("\(session.jumps.count)")
                        .font(.caption)
                        .fontWeight(.bold)
                    Text(L("session.jumps"))
                        .font(.caption2)
                        .foregroundColor(.gray)
                        .textCase(.lowercase)
                }
            }
            
            // Bottom row: Date and duration
            HStack {
                Text(formatDate(session.startTime))
                    .font(.caption)
                    .fontWeight(.medium)
                
                Spacer()
                
                Text(formatDuration(session.duration))
                    .font(.caption)
                    .foregroundColor(.gray)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background(Color.clear)
        .overlay(
            Rectangle()
                .strokeBorder(Color.gray.opacity(0.3), lineWidth: 1)
        )
        .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
    }
    
    private var sportDisplayName: String {
        switch session.sport {
        case .kiteboarding: return L("sport.kitesurfing")
        // case .windsurfing: return L("sport.windsurfing")
        // case .wingfoiling: return L("sport.wingfoiling")
        // case .surfing: return L("sport.surfing")
        }
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }
}

struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView(showingSportSelection: .constant(false))
            .environmentObject(SessionManager())
    }
}
