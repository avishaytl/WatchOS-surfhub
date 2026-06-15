//
//  ActiveSessionView.swift
//  iSurf-Watch
//
//  Real-time session tracking view
//

import SwiftUI

struct ActiveSessionView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @State private var selectedTab = 1  // Start at middle tab (metrics)
    @State private var showingEndConfirmation = false
    @AppStorage("appLanguage") private var languageCode: String = "en"
    @Environment(\.isLuminanceReduced) var isLuminanceReduced

    var body: some View {
        if isLuminanceReduced {
            // Ambient mode (screen dimmed / AOD): show a minimal always-on view.
            // The TimelineView drives periodic re-renders so the timer stays current
            // even when @Published updates are throttled by the OS in ambient mode.
            TimelineView(.periodic(from: Date(), by: 1)) { _ in
                AmbientSessionView()
            }
        } else {
            TabView(selection: $selectedTab) {
                // Tab 0 (Left): Controls - Stop/Pause
                ControlsView(showingEndConfirmation: $showingEndConfirmation)
                    .tag(0)

                // Tab 1 (Middle): Main metrics - DEFAULT
                MetricsView()
                    .tag(1)

                // Tab 2: Jump stats
                JumpStatsView()
                    .tag(2)

                // Tab 3 (Right): GPS Route tracker
                GPSRouteView()
                    .tag(3)
            }
            .tabViewStyle(.page)
            .navigationBarHidden(true)
            .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
            .onAppear {
                // Water Lock must be enabled while the session screen is foreground-active.
                sessionManager.enableWaterLockIfNeeded()
            }
            .alert(L("session.end_confirm"), isPresented: $showingEndConfirmation) {
                Button(L("session.cancel"), role: .cancel) { }
                Button(L("session.end"), role: .destructive) {
                    sessionManager.endSession()
                }
            } message: {
                Text(L("session.end_message"))
            }
        }
    }
}

// Minimal always-on display shown when the watch screen dims to ambient mode.
// Rules for ambient content (Apple HIG):
//   - Pure black background (avoids OLED bleed and saves power)
//   - White / grey text only — no colour fills, no gradients
//   - No animations
//   - Show only the 3 most important numbers
struct AmbientSessionView: View {
    @EnvironmentObject var sessionManager: SessionManager

    var body: some View {
        VStack(spacing: 6) {
            Text(formatDuration(sessionManager.duration))
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()

            Text(formatHeight(sessionManager.currentSession?.jumps.last?.height ?? 0) + "m")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            HStack(spacing: 16) {
                Text(formatSpeed(sessionManager.maxSpeed))
                    .font(.system(size: 14, design: .rounded))
                    .foregroundColor(.gray)
                Text(formatDistance(sessionManager.distance))
                    .font(.system(size: 14, design: .rounded))
                    .foregroundColor(.gray)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let h = Int(d) / 3600; let m = (Int(d) % 3600) / 60; let s = Int(d) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%02d:%02d", m, s)
    }
    private func formatHeight(_ v: Double) -> String { String(format: "%.1f", v) }
    private func formatSpeed(_ v: Double) -> String { String(format: "%.0f km/h", v * 3.6) }
    private func formatDistance(_ v: Double) -> String { String(format: "%.2f km", v / 1000) }
}

struct MetricsView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @AppStorage("appTheme") private var appTheme: String = "orange"
    @AppStorage("appLanguage") private var languageCode: String = "en"
    @AppStorage("metricsTopPadding") private var metricsTopPaddingStored: Double = -1  // -1 = auto
    @Environment(\.isLuminanceReduced) var isLuminanceReduced
    @State private var gpsPulse = false
    
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
    
    // Dynamic top padding based on screen size
    // You can fine-tune these values for each device
    // User can override via Settings → Display & Feedback → Top Padding
    private var topPadding: CGFloat {
        if metricsTopPaddingStored >= 0 {
            return CGFloat(metricsTopPaddingStored)
        }
        return autoTopPadding
    }

    private var autoTopPadding: CGFloat {
        let b = WKInterfaceDevice.current().screenBounds
        let w = Int(b.width.rounded())
        let h = Int(b.height.rounded())
        
        // Log screen dimensions
        // print("📱 Screen Size: \(w) × \(h) pt")
        // print("📏 Exact bounds: \(b.width) × \(b.height) pt")

        // Helper: match either orientation (just in case)
        func isSize(_ aW: Int, _ aH: Int) -> Bool {
            (w == aW && h == aH) || (w == aH && h == aW)
        }

        // --- Apple Watch (legacy) ---
        // 38mm (Series 0–3 small): 136×170 pt
        if isSize(136, 170) { return 0 } // TODO tune

        // 42mm (Series 0–3 large): 156×195 pt
        if isSize(156, 195) { return 0 } // TODO tune

        // --- Apple Watch (Series 4–6 + SE 1/2/3) ---
        // 40mm: 162×197 pt
        if isSize(162, 197) { return 0 } // TODO tune

        // 44mm: 184×224 pt
        if isSize(184, 224) { return 0 } // TODO tune

        // --- Apple Watch (Series 7–9) ---
        // 41mm: 176×215 pt
        if isSize(176, 215) { return 0 } // TODO tune

        // 45mm: 198×242 pt
        if isSize(198, 242) { return 0 } // TODO tune

        // --- Apple Watch Ultra (Ultra 1/2) ---
        // 49mm: 205×251 pt
        if isSize(205, 251) { return 17 } // TODO tune

        // --- Apple Watch Ultra (Ultra 3) ---
        // 49mm: 205×251 pt
        if isSize(211, 257) { return 18 } // TODO tune

        // --- Apple Watch Series 10 / 11 (new sizes) ---
        // Apple reports pixels:
        // 42mm: 374×446 px  -> often maps near ~187×223 pt
        // 46mm: 416×496 px  -> often maps near ~208×248 pt
        //
        // BUT some environments report different bounds; include both.
        //
        // Your measured bounds:
        if isSize(187, 234) { return 0 } // 42mm (your device/sim)
        if isSize(205, 257) { return 16 } // 46mm (your device/sim)

        // Common “pixels/2” derived bounds (fallback matches):
        if isSize(187, 223) { return 0 } // 42mm (374×446 / 2)
        if isSize(208, 248) { return 16 } // 46mm (416×496 / 2)

        // --- Fallback ---
        // Keep something reasonable if a new size appears
        if h < 200 { return 0 }
        if h < 230 { return 0 }
        return 0
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Top row: Timer and GPS status aligned with watch clock
            HStack(alignment: .center, spacing: 0) {
                // Timer + GPS indicator - left side (always LTR)
                HStack(spacing: 4) {
                    Text(formatDuration(sessionManager.duration))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .monospacedDigit()

                    // GPS tracker indicator - inline with timer
                    GPSTrackerIndicator(
                        signalQuality: sessionManager.gpsSignalQuality,
                        pointCount: sessionManager.gpsPointCount,
                        isActive: sessionManager.isGPSActive,
                        gpsPulse: $gpsPulse
                    )

                    // Jump state indicator
                    JumpStateIndicator(state: sessionManager.jumpDetectionState)
                }
                .environment(\.layoutDirection, .leftToRight)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.top, topPadding)
            .environment(\.layoutDirection, .leftToRight)
                
            // Second row: Last Jump Height | BPM | Max Jump Height
            HStack(spacing: 6) {
                CompactMetric(
                    icon: "arrow.up.forward",
                    value: formatHeight(sessionManager.currentSession?.jumps.last?.height ?? 0),
                    label: L("session.last"),
                    iconColor: sessionManager.jumpCount > 0 ? themeColor : .white
                )
                
                CompactMetric(
                    icon: "heart.fill",
                    value: sessionManager.heartRate > 0 ? "\(Int(sessionManager.heartRate))" : "--",
                    label: L("session.bpm"),
                    iconColor: sessionManager.heartRate > 0 ? .red : .white
                )
                
                CompactMetric(
                    icon: "arrow.up",
                    value: formatHeight(sessionManager.currentSession?.jumps.max(by: { $0.height < $1.height })?.height ?? 0),
                    label: L("session.max"),
                    iconColor: .white
                )
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
            
            // Main row: Last Jump Height (large yellow) - FLEXIBLE HEIGHT
            VStack(spacing: 0) {
                Spacer()
                let lastJump = sessionManager.currentSession?.jumps.last
                Text(formatHeight(lastJump?.height ?? 0))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .foregroundColor(themeColor)
                    .shadow(color: themeColor.opacity(0.5), radius: 8, x: 0, y: 0)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0, green: 0, blue: 0).opacity(0.95),
                        Color(red: 0, green: 0, blue: 0)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(themeColor.opacity(0.3), lineWidth: 1.5)
            )
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
            
            // Bottom row: Max Distance | Max Airtime | Max Speed - ANCHORED TO BOTTOM
            HStack(spacing: 6) {
                CompactMetric(
                    icon: "location.circle",
                    value: formatDistance(sessionManager.distance),
                    label: L("session.distance"),
                    // unit: "km",
                    iconColor: .white
                )
                
                CompactMetric(
                    icon: "timer.circle",
                    value: formatAirtime(sessionManager.currentSession?.jumps.max(by: { $0.airtime < $1.airtime })?.airtime ?? 0),
                    label: L("session.airtime"),
                    // unit: "s",
                    iconColor: .white
                )
                
                CompactMetric(
                    icon: "speedometer",
                    value: formatSpeed(sessionManager.maxSpeed),
                    label: L("session.speed"),
                    // unit: "km/h",
                    iconColor: .white
                )
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
            .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
        }
        .edgesIgnoringSafeArea(.all)
    }
    
    private func formatDuration(_ duration: TimeInterval) -> String {
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        let seconds = Int(duration) % 60
        
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }
    
    private func formatSpeed(_ speed: Double) -> String {
        let kmh = speed * 3.6
        return String(format: "%.1f", kmh)
    }
    
    private func formatDistance(_ distance: Double) -> String {
        let km = distance / 1000.0
        return String(format: "%.2f", km)
    }
    
    private func formatHeight(_ height: Double) -> String {
        return String(format: "%.1f", height)
    }
    
    private func formatAirtime(_ airtime: Double) -> String {
        return String(format: "%.1f", airtime)
    }
}


// GPS Tracker Indicator - shows live GPS signal quality and recording status
struct GPSTrackerIndicator: View {
    let signalQuality: GPSSignalQuality
    let pointCount: Int
    let isActive: Bool
    @Binding var gpsPulse: Bool
    @Environment(\.isLuminanceReduced) var isLuminanceReduced
    
    private var signalColor: Color {
        switch signalQuality {
        case .none:   return .red
        case .weak:   return .orange
        case .fair:   return .yellow
        case .good:   return .green
        case .strong: return .green
        }
    }
    
    var body: some View {
        HStack(spacing: 3) {
            // Pulsing GPS icon — animation is disabled in ambient mode (reduces power)
            Image(systemName: signalQuality.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(signalColor)
                .opacity(gpsPulse ? 1.0 : 0.4)
                .animation(
                    isLuminanceReduced ? .none
                        : .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                    value: gpsPulse
                )
                .onAppear { if !isLuminanceReduced { gpsPulse = true } }
            
            // Point counter (compact)
            if isActive && pointCount > 0 {
                Text("\(pointCount)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundColor(signalColor.opacity(0.8))
                    .monospacedDigit()
            }
        }
    }
}

// Compact metric card for new layout
struct CompactMetric: View {
    let icon: String
    let value: String
    var label: String? = nil
    var unit: String? = nil
    var iconColor: Color = .white
    
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .monospacedDigit()

            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(iconColor)
                
                if let label = label {
                    Text(label)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.gray)
                }
                
                if let unit = unit {
                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundColor(.gray.opacity(0.7))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.3))
        .cornerRadius(8)
    }
}

// Jump Detail Box for 2x2 Grid
struct JumpDetailBox: View {
    let icon: String
    let label: String
    let value: String
    var sublabel: String? = nil
    
    var body: some View {
        VStack(alignment: .center, spacing: 6) {
            // Icon and label row
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                
                Text(label)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white.opacity(0.95))
            }
            
            // Value
            Text(value)
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
            
            // Optional sublabel
            if let sublabel = sublabel {
                Text(sublabel)
                    .font(.system(size: 8, weight: .regular))
                    .foregroundColor(.gray.opacity(0.8))
                    .padding(.top, -2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 70)
        .padding(.vertical, 12)
        .padding(.horizontal, 8)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.26, green: 0.19, blue: 0.13).opacity(0.95),
                    Color(red: 0.22, green: 0.16, blue: 0.11)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            Rectangle()
                .stroke(Color.black.opacity(0.3), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 2, x: 0, y: 1)
    }
}

struct MetricCard: View {
    let label: String
    let value: String
    let unit: String
    
    var body: some View {
        VStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(Color(red: 1.0, green: 0.65, blue: 0.45))
                .tracking(0.5)
            
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.4), radius: 2, x: 0, y: 1)
                
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.gray.opacity(0.9))
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .padding(.horizontal, 10)
        .background(
            LinearGradient(
                gradient: Gradient(colors: [
                    Color(red: 0.26, green: 0.19, blue: 0.13).opacity(0.95),
                    Color(red: 0.22, green: 0.16, blue: 0.11)
                ]),
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(
                    LinearGradient(
                        gradient: Gradient(colors: [
                            Color(red: 1.0, green: 0.60, blue: 0.30).opacity(0.6),
                            Color(red: 1.0, green: 0.50, blue: 0.20).opacity(0.4)
                        ]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
        )
        .cornerRadius(10)
        .shadow(color: Color.orange.opacity(0.2), radius: 6, x: 0, y: 2)
        .shadow(color: Color.black.opacity(0.5), radius: 8, x: 0, y: 4)
    }
}

struct JumpStatsView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @AppStorage("appLanguage") private var languageCode: String = "en"
    
    var body: some View {
        VStack(spacing: 12) {
            if sessionManager.jumpCount > 0 {
                let bestJump = sessionManager.currentSession?.jumps.max(by: { $0.height < $1.height })
                
                if let jump = bestJump {
                    VStack(spacing: 8) {
                        Text(L("session.best_jump"))
                            .font(.caption)
                            .foregroundColor(.yellow)
                        
                        Text(String(format: "%.2f m", jump.height))
                            .font(.system(size: 32, weight: .bold))
                        
                        Text(String(format: L("session.airtime_value"), jump.airtime))
                            .font(.caption)
                            .foregroundColor(.gray)
                        
                        if jump.rotations > 0 {
                            let rotationKey = jump.rotations == 1 ? "session.rotation_single" : "session.rotation_plural"
                            Text(String(format: L(rotationKey), jump.rotations))
                                .font(.caption)
                                .foregroundColor(.blue)
                        }
                    }
                    .padding()
                    .background(Color(.darkGray))
                    .cornerRadius(12)
                }
                
                Text(String(format: L("session.total_jumps"), sessionManager.jumpCount))
                    .font(.caption)
                    .foregroundColor(.gray)
                
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "figure.jumprope")
                        .font(.system(size: 40))
                        .foregroundColor(.gray)
                    
                    Text(L("session.no_jumps"))
                        .font(.caption)
                        .foregroundColor(.gray)
                    
                    Text(L("session.get_air"))
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .padding()
            }
        }
        .padding()
        .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
    }
}

struct GPSRouteView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @AppStorage("appLanguage") private var languageCode: String = "en"
    @State private var trackingPulse = false
    
    private var signalColor: Color {
        switch sessionManager.gpsSignalQuality {
        case .none:   return .red
        case .weak:   return .orange
        case .fair:   return .yellow
        case .good:   return .green
        case .strong: return .green
        }
    }
    
    var body: some View {
        VStack(spacing: 8) {
            // GPS tracking header with signal status
            HStack(spacing: 6) {
                // Pulsing recording dot
                Circle()
                    .fill(sessionManager.isGPSActive ? Color.red : Color.gray)
                    .frame(width: 8, height: 8)
                    .opacity(trackingPulse ? 1.0 : 0.3)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: trackingPulse)
                    .onAppear { trackingPulse = true }
                
                Text(L("gps.tracking"))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                
                Spacer()
                
                // Signal quality badge
                HStack(spacing: 3) {
                    Image(systemName: sessionManager.gpsSignalQuality.icon)
                        .font(.system(size: 11))
                        .foregroundColor(signalColor)
                    Text(L("gps.signal_\(sessionManager.gpsSignalQuality.rawValue)"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(signalColor)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(signalColor.opacity(0.15))
                .cornerRadius(8)
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
            
            // Route stats grid
            VStack(spacing: 6) {
                // Row 1: Distance and Speed
                HStack(spacing: 6) {
                    GPSStatCard(
                        icon: "point.bottomleft.forward.to.arrowtriangle.uturn.scurvepath",
                        label: L("gps.route_distance"),
                        value: formatDistance(sessionManager.distance),
                        unit: L("units.kilometers")
                    )
                    GPSStatCard(
                        icon: "speedometer",
                        label: L("gps.current_speed"),
                        value: formatSpeed(sessionManager.currentSpeed),
                        unit: L("units.kmh")
                    )
                }
                
                // Row 2: Points and Accuracy
                HStack(spacing: 6) {
                    GPSStatCard(
                        icon: "mappin.and.ellipse",
                        label: L("gps.points"),
                        value: "\(sessionManager.gpsPointCount)",
                        unit: L("gps.pts")
                    )
                    GPSStatCard(
                        icon: "target",
                        label: L("gps.accuracy"),
                        value: sessionManager.lastGPSAccuracy > 0 ? String(format: "%.0f", sessionManager.lastGPSAccuracy) : "--",
                        unit: L("units.meters")
                    )
                }
                
                // Row 3: Max Speed and Avg Speed
                HStack(spacing: 6) {
                    GPSStatCard(
                        icon: "gauge.with.dots.needle.67percent",
                        label: L("gps.max_speed"),
                        value: formatSpeed(sessionManager.maxSpeed),
                        unit: L("units.kmh")
                    )
                    GPSStatCard(
                        icon: "gauge.with.dots.needle.33percent",
                        label: L("gps.avg_speed"),
                        value: formatSpeed(sessionManager.currentSession?.avgSpeed ?? 0),
                        unit: L("units.kmh")
                    )
                }
            }
            .padding(.horizontal, 6)
            
            Spacer()
        }
        .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
    }
    
    private func formatDistance(_ distance: Double) -> String {
        let km = distance / 1000.0
        return String(format: "%.2f", km)
    }
    
    private func formatSpeed(_ speed: Double) -> String {
        let kmh = speed * 3.6
        return String(format: "%.1f", kmh)
    }
}

struct GPSStatCard: View {
    let icon: String
    let label: String
    let value: String
    let unit: String
    
    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundColor(.cyan.opacity(0.8))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.gray)
            }
            
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .monospacedDigit()
                Text(unit)
                    .font(.system(size: 8))
                    .foregroundColor(.gray.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .padding(.horizontal, 4)
        .background(Color.cyan.opacity(0.08))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.cyan.opacity(0.15), lineWidth: 0.5)
        )
    }
}

struct ControlsView: View {
    @EnvironmentObject var sessionManager: SessionManager
    @Binding var showingEndConfirmation: Bool
    @AppStorage("appLanguage") private var languageCode: String = "en"
    
    var body: some View {
        VStack(spacing: 16) {
            // Text("Session Controls")
            //     .font(.headline)
            
            // Pause/Resume button
            Button(action: {
                if sessionManager.isPaused {
                    sessionManager.resumeSession()
                } else {
                    sessionManager.pauseSession()
                }
            }) {
                VStack(spacing: 8) {
                    Image(systemName: sessionManager.isPaused ? "play.circle.fill" : "pause.circle.fill")
                        .font(.system(size: 40))
                    Text(sessionManager.isPaused ? L("session.resume") : L("session.pause"))
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(sessionManager.isPaused ? Color.green : Color.orange)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
            
            // End button
            Button(action: {
                showingEndConfirmation = true
            }) {
                VStack(spacing: 8) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 40))
                    Text(L("session.end"))
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.red)
                .foregroundColor(.white)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
        }
        .padding()
        .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
    }
}

// Jump State Indicator — shows real-time state machine status
struct JumpStateIndicator: View {
    let state: JumpDetector.JumpState
    @State private var pulse = false

    /// In dev mode, show expanded indicator with state label
    private var isDevMode: Bool { JumpDetectionConfig.shared.devMode }

    private var stateColor: Color {
        switch state {
        case .idle:     return .gray
        case .riding:   return .green
        case .airborne: return .cyan
        case .cooldown: return .gray
        }
    }

    private var isActive: Bool {
        state == .airborne
    }

    var body: some View {
        if isDevMode {
            // Expanded dev indicator — state label visible
            HStack(spacing: 2) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 6, height: 6)
                Text(state.rawValue.prefix(3))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundColor(stateColor)
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(stateColor.opacity(0.15))
            .cornerRadius(4)
            .opacity(isActive ? (pulse ? 1.0 : 0.3) : 0.9)
            .animation(isActive ? .easeInOut(duration: 0.4).repeatForever(autoreverses: true) : .default, value: pulse)
            .onChange(of: state) { _, newState in
                pulse = false
                if newState == .airborne {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        pulse = true
                    }
                }
            }
            .onAppear {
                if isActive { pulse = true }
            }
        } else {
            // Normal compact dot
            Circle()
                .fill(stateColor)
                .frame(width: 6, height: 6)
                .opacity(isActive ? (pulse ? 1.0 : 0.3) : 0.6)
                .animation(isActive ? .easeInOut(duration: 0.4).repeatForever(autoreverses: true) : .default, value: pulse)
                .onChange(of: state) { _, newState in
                    pulse = false
                    if newState == .airborne {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                            pulse = true
                        }
                    }
                }
                .onAppear {
                    if isActive { pulse = true }
                }
        }
    }
}

struct ActiveSessionView_Previews: PreviewProvider {
    static var previews: some View {
        ActiveSessionView()
            .environmentObject(SessionManager())
    }
}
