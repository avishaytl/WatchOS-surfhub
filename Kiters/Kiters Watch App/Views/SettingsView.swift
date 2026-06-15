//
//  SettingsView.swift
//  iSurf-Watch
//
//  App settings and preferences
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService
    @AppStorage("units") private var units: String = "metric"
    @AppStorage("appTheme") private var appTheme: String = "orange"
    @AppStorage("appLanguage") private var languageCode: String = "en"
    @AppStorage("detectionMode") private var detectionModeRaw: String = DetectionMode.standard.rawValue
    @AppStorage("autoLock") private var autoLock: Bool = true
    @AppStorage("hapticFeedback") private var hapticFeedback: Bool = true
    @AppStorage("metricsTopPadding") private var metricsTopPadding: Double = -1  // -1 = auto

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
            VStack(spacing: 16) {
                // Title
                Text(L("settings.title"))
                    .font(.title3)
                    .fontWeight(.bold)
                    .padding(.bottom, 8)

                // Account Section
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("account.section_title"))
                        .font(.caption)
                        .foregroundColor(.gray)
                        .textCase(.uppercase)

                    ZStack {
                        Color.clear
                        NavigationLink(destination: AccountView()) {
                            HStack {
                                Image(systemName: authService.isSignedIn
                                      ? "person.circle.fill" : "person.circle")
                                    .foregroundColor(authService.isSignedIn ? .green : .blue)
                                    .frame(width: 20)
                                Text(authService.isSignedIn
                                     ? authService.currentEmail : L("account.sign_in"))
                                    .font(.caption)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                                Spacer()
                                Image(systemName: languageCode == "he" ? "chevron.left" : "chevron.right")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 12)
                        }
                        .buttonStyle(.plain)
                    }
                    .overlay(
                        Rectangle()
                            .stroke(themeColor.opacity(0.3), lineWidth: 1)
                    )
                }

                Divider()

                // Theme Section
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("settings.app_theme"))
                        .font(.caption)
                        .foregroundColor(.gray)
                        .textCase(.uppercase)
                    
                    ZStack {
                        Color.clear
                        Picker("Theme", selection: $appTheme) {
                            HStack {
                                Circle()
                                    .fill(Color.blue)
                                    .frame(width: 12, height: 12)
                                Text(L("settings.theme.blue"))
                            }.tag("blue")
                            
                            HStack {
                                Circle()
                                    .fill(Color.cyan)
                                    .frame(width: 12, height: 12)
                                Text(L("settings.theme.cyan"))
                            }.tag("cyan")
                            
                            HStack {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 12, height: 12)
                                Text(L("settings.theme.green"))
                            }.tag("green")
                            
                            HStack {
                                Circle()
                                    .fill(Color.yellow)
                                    .frame(width: 12, height: 12)
                                Text(L("settings.theme.yellow"))
                            }.tag("yellow")
                            
                            HStack {
                                Circle()
                                    .fill(Color.orange)
                                    .frame(width: 12, height: 12)
                                Text(L("settings.theme.orange"))
                            }.tag("orange")
                            
                            HStack {
                                Circle()
                                    .fill(Color.red)
                                    .frame(width: 12, height: 12)
                                Text(L("settings.theme.red"))
                            }.tag("red")
                            
                            HStack {
                                Circle()
                                    .fill(Color.pink)
                                    .frame(width: 12, height: 12)
                                Text(L("settings.theme.pink"))
                            }.tag("pink")
                        }
                        .pickerStyle(.navigationLink)
                        .labelsHidden()
                        .buttonStyle(.plain)
                    }
                    .overlay(
                        Rectangle()
                            .stroke(themeColor.opacity(0.3), lineWidth: 1)
                    )
                }
                
                Divider()
                
                // Language Section
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("settings.language"))
                        .font(.caption)
                        .foregroundColor(.gray)
                        .textCase(.uppercase)
                    
                    ZStack {
                        Color.clear
                        Picker("Language", selection: $languageCode) {
                            Text(L("settings.language.english")).tag("en")
                            Text(L("settings.language.hebrew")).tag("he")
                        }
                        .pickerStyle(.navigationLink)
                        .labelsHidden()
                        .buttonStyle(.plain)
                    }
                    .overlay(
                        Rectangle()
                            .stroke(themeColor.opacity(0.3), lineWidth: 1)
                    )
                }
                
                Divider()
                
                // Units Section
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("settings.units"))
                        .font(.caption)
                        .foregroundColor(.gray)
                        .textCase(.uppercase)
                    
                    ZStack {
                        Color.clear
                        Picker("Units", selection: $units) {
                            Text(L("settings.units.metric")).tag("metric")
                            Text(L("settings.units.imperial")).tag("imperial")
                        }
                        .pickerStyle(.navigationLink)
                        .labelsHidden()
                        .buttonStyle(.plain)
                    }
                    .overlay(
                        Rectangle()
                            .stroke(themeColor.opacity(0.3), lineWidth: 1)
                    )
                }
                
                Divider()
                
                // Display & Feedback Section
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("settings.display_feedback"))
                        .font(.caption)
                        .foregroundColor(.gray)
                        .textCase(.uppercase)
                    
                    // Top Padding adjustment
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: "arrow.up.and.down.text.horizontal")
                                .foregroundColor(.cyan)
                                .frame(width: 20)
                            Text(L("settings.top_padding"))
                                .font(.caption)
                            Spacer()
                            Text(metricsTopPadding < 0
                                 ? L("settings.top_padding_auto")
                                 : "\(Int(metricsTopPadding)) pt")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundColor(themeColor)
                        }

                        HStack(spacing: 8) {
                            // Auto button
                            Button(action: { metricsTopPadding = -1 }) {
                                Text(L("settings.top_padding_auto"))
                                    .font(.system(size: 9, weight: .semibold))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(metricsTopPadding < 0 ? themeColor.opacity(0.3) : Color.white.opacity(0.08))
                                    .foregroundColor(metricsTopPadding < 0 ? themeColor : .gray)
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            // – button
                            Button(action: {
                                if metricsTopPadding < 0 { metricsTopPadding = 0 }
                                metricsTopPadding = max(0, metricsTopPadding - 1)
                            }) {
                                Image(systemName: "minus.circle")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            .buttonStyle(.plain)

                            // + button
                            Button(action: {
                                if metricsTopPadding < 0 { metricsTopPadding = 0 }
                                metricsTopPadding = min(40, metricsTopPadding + 1)
                            }) {
                                Image(systemName: "plus.circle")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            .buttonStyle(.plain)
                        }

                        if metricsTopPadding >= 0 {
                            Slider(value: $metricsTopPadding, in: 0...40, step: 1)
                                .tint(themeColor)
                        }

                        Text(L("settings.top_padding_help"))
                            .font(.system(size: 8))
                            .foregroundColor(.gray.opacity(0.7))
                    }
                    .padding(8)
                    .background(Color.white.opacity(0.05))
                    .cornerRadius(8)

                    Toggle(isOn: $autoLock) {
                        HStack {
                            Image(systemName: "drop.fill")
                                .foregroundColor(.blue)
                                .frame(width: 20)
                            Text(L("settings.water_lock"))
                                .font(.caption)
                        }
                    }
                    
                    Toggle(isOn: $hapticFeedback) {
                        HStack {
                            Image(systemName: "hand.tap.fill")
                                .foregroundColor(.orange)
                                .frame(width: 20)
                            Text(L("settings.haptic_feedback"))
                                .font(.caption)
                        }
                    }
                }
                
                Divider()
                
                // Data Management Section
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("settings.data"))
                        .font(.caption)
                        .foregroundColor(.gray)
                        .textCase(.uppercase)
                    
                    ZStack {
                        Color.clear
                        NavigationLink(destination: DataManagementView()) {
                            HStack {
                                Image(systemName: "externaldrive.fill")
                                    .foregroundColor(.white)
                                    .frame(width: 20)
                                Text(L("settings.manage_sessions"))
                                    .font(.caption)
                                Spacer()
                                Image(systemName: languageCode == "he" ? "chevron.left" : "chevron.right")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 12)
                        }
                        .buttonStyle(.plain)
                    }
                    .overlay(
                        Rectangle()
                            .stroke(themeColor.opacity(0.3), lineWidth: 1)
                    )

                    // Session Logs (CSV diagnostics)
                    ZStack {
                        Color.clear
                        NavigationLink(destination: SessionLogsView()) {
                            HStack {
                                Image(systemName: "doc.text.fill")
                                    .foregroundColor(.cyan)
                                    .frame(width: 20)
                                Text(L("settings.session_logs"))
                                    .font(.caption)
                                Spacer()
                                Image(systemName: languageCode == "he" ? "chevron.left" : "chevron.right")
                                    .font(.caption2)
                                    .foregroundColor(.gray)
                            }
                            .padding(.vertical, 12)
                            .padding(.horizontal, 12)
                        }
                        .buttonStyle(.plain)
                    }
                    .overlay(
                        Rectangle()
                            .stroke(themeColor.opacity(0.3), lineWidth: 1)
                    )
                }
                
                Divider()
                
                // About Section
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("settings.about"))
                        .font(.caption)
                        .foregroundColor(.gray)
                        .textCase(.uppercase)
                    
                    HStack {
                        Text(L("settings.version"))
                            .font(.caption)
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                    
                    HStack {
                        Text(L("settings.build"))
                            .font(.caption)
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1")
                            .font(.caption)
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding()
        }
        // .watchScrollTopShadow()
        .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Custom mode was removed from Settings — migrate any stored value to Standard.
            if detectionModeRaw == DetectionMode.custom.rawValue {
                detectionModeRaw = DetectionMode.standard.rawValue
            }
        }
    }
    
}

struct DataManagementView: View {
    @State private var sessions: [Session] = []
    @State private var showingDeleteAlert = false
    @AppStorage("appLanguage") private var languageCode: String = "en"
    private let storageManager = StorageManager()
    
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                Text(L("data.title"))
                    .font(.headline)
                
                // Storage info
                VStack(alignment: .leading, spacing: 8) {
                    Text(String(format: L("data.sessions_count"), sessions.count))
                        .font(.caption)
                    
                    let totalJumps = sessions.reduce(0) { $0 + $1.jumps.count }
                    Text(String(format: L("data.total_jumps"), totalJumps))
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(Color(.darkGray).opacity(0.3))
                .cornerRadius(8)
                
                // Delete all button
                Button(action: {
                    showingDeleteAlert = true
                }) {
                    HStack {
                        Image(systemName: "trash.fill")
                        Text(L("data.delete_all"))
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.red)
                    .foregroundColor(.white)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding()
        }
        .watchScrollTopShadow()
        .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
        .onAppear {
            sessions = storageManager.loadAllSessions()
        }
        .alert(L("data.delete_confirm"), isPresented: $showingDeleteAlert) {
            Button(L("session.cancel"), role: .cancel) { }
            Button(L("data.delete"), role: .destructive) {
                deleteAllSessions()
            }
        } message: {
            Text(L("data.delete_message"))
        }
    }
    
    private func deleteAllSessions() {
        storageManager.clearAllSessions()
        sessions = []
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        NavigationView {
            SettingsView()
        }
    }
}
