//
//  SettingsView.swift
//  iSurf-Watch
//
//  App settings and preferences
//

import SwiftUI
import CoreMotion

struct SettingsView: View {
    @EnvironmentObject var authService: AuthService
    @AppStorage("units") private var units: String = "metric"
    @AppStorage("appTheme") private var appTheme: String = "orange"
    @AppStorage("appLanguage") private var languageCode: String = "en"
    @AppStorage("detectionMode") private var detectionModeRaw: String = DetectionMode.standard.rawValue
    @AppStorage("detectionEngine") private var detectionEngineRaw: String = DetectionEngine.v11Buffered.rawValue
    @AppStorage(V13Settings.minCountedHeightM) private var v13MinCountedHeightM = 1.0
    @AppStorage(V13Settings.absoluteAltitudeSampleIntervalSec) private var v13AbsoluteAltitudeSampleIntervalSec = 0.5
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

    private func v13CountedHeightLabel(_ metres: Double) -> String {
        if units == "imperial" {
            return String(format: "%.1f ft", metres * 3.28084)
        }
        return String(format: "%.1f m", metres)
    }

    private func absoluteAltitudeIntervalLabel(_ seconds: Double) -> String {
        String(format: seconds == 1 ? "%.0f s" : "%.2g s", seconds)
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

                    ZStack {
                        Color.clear
                        NavigationLink(destination: AbsoluteAltitudeSensorView()) {
                            HStack {
                                Image(systemName: "barometer")
                                    .foregroundColor(.cyan)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(L("settings.absolute_altitude"))
                                        .font(.caption)
                                    Text(L("settings.absolute_altitude_hint"))
                                        .font(.system(size: 8))
                                        .foregroundColor(.gray)
                                        .lineLimit(2)
                                }
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
                
                // Jump Detection Engine Section
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("settings.engine.section"))
                        .font(.caption)
                        .foregroundColor(.gray)
                        .textCase(.uppercase)

                    ZStack {
                        Color.clear
                        Picker(L("settings.engine.section"), selection: $detectionEngineRaw) {
                            // The sensor recorder is not a detection engine —
                            // it is launched from its own Home button.
                            ForEach(DetectionEngine.allCases.filter { $0 != .sensorRecorder }, id: \.self) { engine in
                                HStack {
                                    Image(systemName: engine.icon)
                                        .frame(width: 16)
                                    Text(engine.displayName)
                                }
                                .tag(engine.rawValue)
                            }
                        }
                        .pickerStyle(.navigationLink)
                        .labelsHidden()
                        .buttonStyle(.plain)
                    }
                    .overlay(
                        Rectangle()
                            .stroke(themeColor.opacity(0.3), lineWidth: 1)
                    )

                    // Shared 1/1.5/2 m height picker. For V13 it filters the
                    // final count only; for V14 and V15 the same value is part
                    // of the detection formula itself (same UserDefaults key).
                    if detectionEngineRaw == DetectionEngine.v13Pure.rawValue
                        || detectionEngineRaw == DetectionEngine.v14Hybrid.rawValue
                        || detectionEngineRaw == DetectionEngine.v15Clean.rawValue {
                        VStack(alignment: .leading, spacing: 4) {
                            ZStack {
                                Color.clear
                                Picker(selection: $v13MinCountedHeightM) {
                                    ForEach(V13Settings.countedHeightOptions, id: \.self) { metres in
                                        Text(verbatim: v13CountedHeightLabel(metres)).tag(metres)
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: "arrow.up.to.line")
                                            .frame(width: 16)
                                        Text(L("settings.v13_min_counted_height"))
                                            .font(.caption)
                                    }
                                }
                                .pickerStyle(.navigationLink)
                                .buttonStyle(.plain)
                            }
                            .overlay(
                                Rectangle()
                                    .stroke(themeColor.opacity(0.3), lineWidth: 1)
                            )

                            Text(L("settings.v13_min_counted_height_hint"))
                                .font(.system(size: 8))
                                .foregroundColor(.gray)
                                .fixedSize(horizontal: false, vertical: true)

                            if detectionEngineRaw == DetectionEngine.v13Pure.rawValue {
                                ZStack {
                                    Color.clear
                                    Picker(selection: $v13AbsoluteAltitudeSampleIntervalSec) {
                                        ForEach(V13Settings.absoluteAltitudeSampleIntervalOptions, id: \.self) { seconds in
                                            Text(verbatim: absoluteAltitudeIntervalLabel(seconds)).tag(seconds)
                                        }
                                    } label: {
                                        HStack {
                                            Image(systemName: "waveform.path.ecg")
                                                .frame(width: 16)
                                            Text(L("settings.v13_absolute_interval"))
                                                .font(.caption)
                                        }
                                    }
                                    .pickerStyle(.navigationLink)
                                    .buttonStyle(.plain)
                                }
                                .overlay(
                                    Rectangle()
                                        .stroke(themeColor.opacity(0.3), lineWidth: 1)
                                )

                                Text(L("settings.v13_absolute_interval_hint"))
                                    .font(.system(size: 8))
                                    .foregroundColor(.gray)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }

                    if detectionEngineRaw == DetectionEngine.v12AppleSensorFusion.rawValue {
                        ZStack {
                            Color.clear
                            NavigationLink(destination: V12DebugSettingsView()) {
                                HStack {
                                    Image(systemName: "slider.horizontal.3")
                                        .foregroundColor(.cyan)
                                        .frame(width: 20)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(L("settings.v12_debug"))
                                            .font(.caption)
                                        Text(L("settings.v12_debug_hint"))
                                            .font(.system(size: 8))
                                            .foregroundColor(.gray)
                                            .lineLimit(2)
                                    }
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
            // Older/debug builds could persist arbitrary doubles although this
            // product control has three supported choices. Snap to the nearest
            // option so the picker and the engine always show the same value.
            let normalizedHeight = V13Settings.normalizedCountedHeight(v13MinCountedHeightM)
            if normalizedHeight != v13MinCountedHeightM {
                v13MinCountedHeightM = normalizedHeight
            }
            let normalizedInterval = V13Settings.normalizedAbsoluteAltitudeSampleInterval(
                v13AbsoluteAltitudeSampleIntervalSec
            )
            if normalizedInterval != v13AbsoluteAltitudeSampleIntervalSec {
                v13AbsoluteAltitudeSampleIntervalSec = normalizedInterval
            }
        }
    }
    
}

private final class AbsoluteAltitudeSensorMonitor: ObservableObject {
    @Published var altitudeM: Double?
    @Published var accuracyM: Double?
    @Published var precisionM: Double?
    @Published var relativeAltitudeM: Double?
    @Published var pressureKPa: Double?
    @Published var absoluteSampleCount = 0
    @Published var relativeSampleCount = 0
    @Published var lastAbsoluteUpdate: Date?
    @Published var lastRelativeUpdate: Date?
    @Published var statusKey = "settings.absolute_altitude_idle"
    @Published var isAbsoluteSupported = false
    @Published var isRelativeSupported = false

    private let altimeter = CMAltimeter()
    private let queue = OperationQueue()

    init() {
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInteractive
        if #available(watchOS 8.0, iOS 15.0, *) {
            isAbsoluteSupported = CMAltimeter.isAbsoluteAltitudeAvailable()
        }
        isRelativeSupported = CMAltimeter.isRelativeAltitudeAvailable()
    }

    func start() {
        isRelativeSupported = CMAltimeter.isRelativeAltitudeAvailable()
        if #available(watchOS 8.0, iOS 15.0, *) {
            isAbsoluteSupported = CMAltimeter.isAbsoluteAltitudeAvailable()
        } else {
            isAbsoluteSupported = false
        }

        guard isAbsoluteSupported || isRelativeSupported else {
            statusKey = "settings.absolute_altitude_unavailable"
            return
        }

        statusKey = "settings.absolute_altitude_waiting"

        if isRelativeSupported {
            altimeter.startRelativeAltitudeUpdates(to: queue) { [weak self] data, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if error != nil {
                        self.statusKey = "settings.absolute_altitude_error"
                        return
                    }
                    guard let data else {
                        self.statusKey = "settings.absolute_altitude_waiting"
                        return
                    }

                    self.relativeAltitudeM = data.relativeAltitude.doubleValue
                    self.pressureKPa = data.pressure.doubleValue
                    self.relativeSampleCount += 1
                    self.lastRelativeUpdate = Date()
                    self.statusKey = "settings.absolute_altitude_live"
                }
            }
        }

        if #available(watchOS 8.0, iOS 15.0, *), isAbsoluteSupported {
            altimeter.startAbsoluteAltitudeUpdates(to: queue) { [weak self] data, error in
                DispatchQueue.main.async {
                    guard let self = self else { return }
                    if error != nil {
                        self.statusKey = "settings.absolute_altitude_error"
                        return
                    }
                    guard let data else {
                        self.statusKey = "settings.absolute_altitude_waiting"
                        return
                    }

                    self.altitudeM = data.altitude
                    self.accuracyM = data.accuracy
                    self.precisionM = data.precision
                    self.absoluteSampleCount += 1
                    self.lastAbsoluteUpdate = Date()
                    self.statusKey = "settings.absolute_altitude_live"
                }
            }
        }
    }

    func stop() {
        if #available(watchOS 8.0, iOS 15.0, *) {
            altimeter.stopAbsoluteAltitudeUpdates()
        }
        altimeter.stopRelativeAltitudeUpdates()
        statusKey = "settings.absolute_altitude_idle"
    }
}

struct AbsoluteAltitudeSensorView: View {
    @AppStorage("appLanguage") private var languageCode: String = "en"
    @AppStorage("appTheme") private var appTheme: String = "orange"
    @StateObject private var monitor = AbsoluteAltitudeSensorMonitor()

    private var themeColor: Color {
        switch appTheme {
        case "yellow": return .yellow
        case "green":  return .green
        case "red":    return .red
        case "cyan":   return .cyan
        case "pink":   return .pink
        default:       return .orange
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("settings.absolute_altitude_title"))
                    .font(.title3)
                    .fontWeight(.bold)

                HStack {
                    Circle()
                        .fill(hasAnyLiveSample ? Color.green : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(L(monitor.statusKey))
                        .font(.caption)
                        .foregroundColor(.gray)
                }

                sensorCard(label: "settings.absolute_altitude_value",
                           source: "settings.absolute_altitude_source_absolute",
                           value: monitor.altitudeM,
                           decimals: 2,
                           unit: "m")
                sensorCard(label: "settings.relative_altitude_value",
                           source: "settings.absolute_altitude_source_relative",
                           value: monitor.relativeAltitudeM,
                           decimals: 2,
                           unit: "m")
                sensorCard(label: "settings.pressure_value",
                           source: "settings.absolute_altitude_source_pressure",
                           value: monitor.pressureKPa,
                           decimals: 3,
                           unit: "kPa")

                metricRow(label: "settings.absolute_altitude_accuracy",
                          value: monitor.accuracyM.map { String(format: "±%.2f m", $0) } ?? "--")
                metricRow(label: "settings.absolute_altitude_precision",
                          value: monitor.precisionM.map { String(format: "%.2f m", $0) } ?? "--")
                metricRow(label: "settings.absolute_altitude_pressure_hpa",
                          value: monitor.pressureKPa.map { String(format: "%.2f hPa", $0 * 10.0) } ?? "--")
                metricRow(label: "settings.absolute_altitude_absolute_samples",
                          value: "\(monitor.absoluteSampleCount)")
                metricRow(label: "settings.absolute_altitude_relative_samples",
                          value: "\(monitor.relativeSampleCount)")
                metricRow(label: "settings.absolute_altitude_absolute_updated",
                          value: lastAbsoluteUpdateText)
                metricRow(label: "settings.absolute_altitude_relative_updated",
                          value: lastRelativeUpdateText)
            }
            .padding()
        }
        .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { monitor.start() }
        .onDisappear { monitor.stop() }
    }

    private var hasAnyLiveSample: Bool {
        monitor.altitudeM != nil || monitor.relativeAltitudeM != nil || monitor.pressureKPa != nil
    }

    private var lastAbsoluteUpdateText: String {
        updateAgeText(for: monitor.lastAbsoluteUpdate)
    }

    private var lastRelativeUpdateText: String {
        updateAgeText(for: monitor.lastRelativeUpdate)
    }

    private func updateAgeText(for lastUpdate: Date?) -> String {
        guard let lastUpdate else { return "--" }
        let age = max(0, Date().timeIntervalSince(lastUpdate))
        return String(format: "%.1f s", age)
    }

    private func sensorCard(label: String,
                            source: String,
                            value: Double?,
                            decimals: Int,
                            unit: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L(label))
                .font(.caption)
                .foregroundColor(.gray)
                .textCase(.uppercase)

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value.map { String(format: "%.\(decimals)f", $0) } ?? "--")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundColor(themeColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Text(unit)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.gray)
            }

            Text(L(source))
                .font(.system(size: 8))
                .foregroundColor(.gray.opacity(0.75))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack {
            Text(L(label))
                .font(.caption)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(themeColor)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }
}

struct V12DebugSettingsView: View {
    @AppStorage("appLanguage") private var languageCode: String = "en"
    @AppStorage("appTheme") private var appTheme: String = "orange"

    @AppStorage(V12DebugSettings.forceEngineWhenNotReady) private var forceEngineWhenNotReady = false
    @AppStorage(V12DebugSettings.disableSpeedGate) private var disableSpeedGate = true
    @AppStorage(V12DebugSettings.disableBaroAnchorGate) private var disableBaroAnchorGate = true
    @AppStorage(V12DebugSettings.disableCrashCooldown) private var disableCrashCooldown = true
    @AppStorage(V12DebugSettings.disableMidArcCrashAbort) private var disableMidArcCrashAbort = true
    @AppStorage(V12DebugSettings.disableLandingBaroConfirmation) private var disableLandingBaroConfirmation = true
    @AppStorage(V12DebugSettings.disableMinHeightGate) private var disableMinHeightGate = false
    @AppStorage(V12DebugSettings.disableRefineRetraction) private var disableRefineRetraction = true

    @AppStorage(V12DebugSettings.yankG) private var yankG = 2.2
    @AppStorage(V12DebugSettings.crashG) private var crashG = 6.0
    @AppStorage(V12DebugSettings.landImpactG) private var landImpactG = 2.0
    @AppStorage(V12DebugSettings.absoluteTakeoffRiseM) private var absoluteTakeoffRiseM = 0.25
    @AppStorage(V12DebugSettings.landingReturnToleranceM) private var landingReturnToleranceM = 0.35
    @AppStorage(V12DebugSettings.minAirSec) private var minAirSec = 0.3
    @AppStorage(V12DebugSettings.maxAirSec) private var maxAirSec = 8.0
    @AppStorage(V12DebugSettings.planingSpeedMs) private var planingSpeedMs = 0.56
    @AppStorage(V12DebugSettings.planingWinSec) private var planingWinSec = 5.0
    @AppStorage(V12DebugSettings.anchorMaxAgeSec) private var anchorMaxAgeSec = 8.0
    @AppStorage(V12DebugSettings.anchorMinSamples) private var anchorMinSamples = 1.0
    @AppStorage(V12DebugSettings.minJumpHeightM) private var minJumpHeightM = 1.0
    @AppStorage(V12DebugSettings.maxJumpHeightM) private var maxJumpHeightM = 12.0
    @AppStorage(V12DebugSettings.crashCooldownSec) private var crashCooldownSec = 30.0
    @AppStorage(V12DebugSettings.chopWinSec) private var chopWinSec = 0.3
    @AppStorage(V12DebugSettings.chopResumeFrac) private var chopResumeFrac = 0.8
    @AppStorage(V12DebugSettings.chopResumeHoldSec) private var chopResumeHoldSec = 0.3
    @AppStorage(V12DebugSettings.refineDelaySec) private var refineDelaySec = 3.0
    @AppStorage(V12DebugSettings.rtzCorrectM) private var rtzCorrectM = 0.25

    @State private var showResetAlert = false

    private var themeColor: Color {
        switch appTheme {
        case "yellow": return .yellow
        case "green":  return .green
        case "red":    return .red
        case "cyan":   return .cyan
        case "pink":   return .pink
        default:       return .orange
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(L("settings.v12_debug_title"))
                    .font(.title3)
                    .fontWeight(.bold)

                Text(L("settings.v12_debug_applies_next_session"))
                    .font(.system(size: 9))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.leading)

                Divider()

                sectionTitle("settings.v12_gates")
                gateToggle($forceEngineWhenNotReady,
                           icon: "exclamationmark.shield",
                           label: "settings.v12_force_engine",
                           help: "settings.v12_force_engine_help")
                gateToggle($disableSpeedGate,
                           icon: "speedometer",
                           label: "settings.v12_disable_speed_gate",
                           help: "settings.v12_disable_speed_gate_help")
                gateToggle($disableBaroAnchorGate,
                           icon: "barometer",
                           label: "settings.v12_disable_baro_anchor",
                           help: "settings.v12_disable_baro_anchor_help")
                gateToggle($disableCrashCooldown,
                           icon: "bolt.trianglebadge.exclamationmark",
                           label: "settings.v12_disable_crash_cooldown",
                           help: "settings.v12_disable_crash_cooldown_help")
                gateToggle($disableMidArcCrashAbort,
                           icon: "exclamationmark.triangle",
                           label: "settings.v12_disable_mid_arc_crash",
                           help: "settings.v12_disable_mid_arc_crash_help")
                gateToggle($disableLandingBaroConfirmation,
                           icon: "water.waves",
                           label: "settings.v12_disable_landing_baro",
                           help: "settings.v12_disable_landing_baro_help")
                gateToggle($disableMinHeightGate,
                           icon: "ruler",
                           label: "settings.v12_disable_min_height",
                           help: "settings.v12_disable_min_height_help")
                gateToggle($disableRefineRetraction,
                           icon: "arrow.uturn.backward",
                           label: "settings.v12_disable_refine_retraction",
                           help: "settings.v12_disable_refine_retraction_help")

                Divider()

                sectionTitle("settings.v12_thresholds")
                numberRow("settings.v12_yank_g", value: $yankG, range: 0.5...6.0, step: 0.1, unit: "g")
                numberRow("settings.v12_crash_g", value: $crashG, range: 2.0...12.0, step: 0.5, unit: "g")
                numberRow("settings.v12_land_g", value: $landImpactG, range: 0.3...6.0, step: 0.1, unit: "g")
                numberRow("settings.v12_absolute_rise", value: $absoluteTakeoffRiseM, range: 0.0...3.0, step: 0.05, unit: "m", decimals: 2)
                numberRow("settings.v12_min_air", value: $minAirSec, range: 0.0...4.0, step: 0.1, unit: "s")
                numberRow("settings.v12_max_air", value: $maxAirSec, range: 1.0...30.0, step: 0.5, unit: "s")
                numberRow("settings.v12_min_height", value: $minJumpHeightM, range: 0.0...8.0, step: 0.1, unit: "m")
                numberRow("settings.v12_max_height", value: $maxJumpHeightM, range: 1.0...40.0, step: 1.0, unit: "m", decimals: 0)

                Divider()

                sectionTitle("settings.v12_baro_timing")
                numberRow("settings.v12_planing_speed",
                          value: $planingSpeedMs,
                          range: 0.0...8.0,
                          step: 0.1,
                          unit: "",
                          formatter: { String(format: "%.1f m/s · %.0f km/h", $0, $0 * 3.6) })
                numberRow("settings.v12_planing_window", value: $planingWinSec, range: 0.0...20.0, step: 0.5, unit: "s")
                numberRow("settings.v12_anchor_age", value: $anchorMaxAgeSec, range: 0.5...30.0, step: 0.5, unit: "s")
                numberRow("settings.v12_anchor_samples",
                          value: $anchorMinSamples,
                          range: 1.0...8.0,
                          step: 1.0,
                          unit: "",
                          decimals: 0)
                numberRow("settings.v12_landing_return", value: $landingReturnToleranceM, range: 0.05...3.0, step: 0.05, unit: "m", decimals: 2)
                numberRow("settings.v12_crash_cooldown", value: $crashCooldownSec, range: 0.0...120.0, step: 5.0, unit: "s", decimals: 0)
                numberRow("settings.v12_chop_window", value: $chopWinSec, range: 0.05...2.0, step: 0.05, unit: "s", decimals: 2)
                numberRow("settings.v12_chop_resume_frac", value: $chopResumeFrac, range: 0.05...2.0, step: 0.05, unit: "x", decimals: 2)
                numberRow("settings.v12_chop_hold", value: $chopResumeHoldSec, range: 0.0...2.5, step: 0.05, unit: "s", decimals: 2)

                Divider()

                sectionTitle("settings.v12_refinement")
                numberRow("settings.v12_refine_delay", value: $refineDelaySec, range: 0.0...10.0, step: 0.5, unit: "s")
                numberRow("settings.v12_rtz", value: $rtzCorrectM, range: 0.0...3.0, step: 0.05, unit: "m", decimals: 2)

                Button(action: { showResetAlert = true }) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text(L("settings.v12_reset"))
                            .font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.red.opacity(0.15))
                    .foregroundColor(.red)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }
            .padding()
        }
        .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
        .navigationBarTitleDisplayMode(.inline)
        .alert(L("settings.v12_reset_confirm"), isPresented: $showResetAlert) {
            Button(L("common.cancel"), role: .cancel) { }
            Button(L("settings.v12_reset"), role: .destructive) {
                resetToDefaults()
            }
        }
        .onAppear {
            V12DebugSettings.migrateIfNeeded()
        }
    }

    private func sectionTitle(_ key: String) -> some View {
        Text(L(key))
            .font(.caption)
            .foregroundColor(.gray)
            .textCase(.uppercase)
    }

    private func gateToggle(_ value: Binding<Bool>,
                            icon: String,
                            label: String,
                            help: String) -> some View {
        Toggle(isOn: value) {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Image(systemName: icon)
                        .foregroundColor(.cyan)
                        .frame(width: 20)
                    Text(L(label))
                        .font(.caption)
                }
                Text(L(help))
                    .font(.system(size: 8))
                    .foregroundColor(.gray.opacity(0.75))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }

    private func numberRow(_ label: String,
                           value: Binding<Double>,
                           range: ClosedRange<Double>,
                           step: Double,
                           unit: String,
                           decimals: Int = 1,
                           formatter: ((Double) -> String)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(L(label))
                    .font(.system(size: 11))
                Spacer()
                Text(formatter?(value.wrappedValue) ?? formatted(value.wrappedValue, unit: unit, decimals: decimals))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(themeColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }

            Slider(value: value, in: range, step: step)
                .tint(themeColor)

            HStack {
                Button(action: { value.wrappedValue = max(range.lowerBound, value.wrappedValue - step) }) {
                    Image(systemName: "minus.circle")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)

                Spacer()

                Button(action: { value.wrappedValue = min(range.upperBound, value.wrappedValue + step) }) {
                    Image(systemName: "plus.circle")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }

    private func formatted(_ value: Double, unit: String, decimals: Int) -> String {
        let format = "%.\(decimals)f"
        let number = String(format: format, value)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    private func resetToDefaults() {
        let defaults = V12Config()
        forceEngineWhenNotReady = false
        disableSpeedGate = !defaults.requirePlaning
        disableBaroAnchorGate = !defaults.requireBaroAnchor
        disableCrashCooldown = !defaults.enforceCrashCooldown
        disableMidArcCrashAbort = !defaults.abortOnMidArcCrash
        disableLandingBaroConfirmation = !defaults.requireLandingBaroConfirmation
        disableMinHeightGate = !defaults.enforceMinJumpHeight
        disableRefineRetraction = !defaults.retractOnRefineReject

        yankG = defaults.yankG
        crashG = defaults.crashG
        landImpactG = defaults.landImpactG
        absoluteTakeoffRiseM = defaults.absoluteTakeoffRiseM
        landingReturnToleranceM = defaults.landingReturnToleranceM
        minAirSec = defaults.minAirSec
        maxAirSec = defaults.maxAirSec
        planingSpeedMs = defaults.planingSpeedMs
        planingWinSec = defaults.planingWinSec
        anchorMaxAgeSec = defaults.anchorMaxAgeSec
        anchorMinSamples = Double(defaults.anchorMinSamples)
        minJumpHeightM = defaults.minJumpHeightM
        maxJumpHeightM = defaults.maxJumpHeightM
        crashCooldownSec = defaults.crashCooldownSec
        chopWinSec = defaults.chopWinSec
        chopResumeFrac = defaults.chopResumeFrac
        chopResumeHoldSec = defaults.chopResumeHoldSec
        refineDelaySec = defaults.refineDelaySec
        rtzCorrectM = defaults.rtzCorrectM
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
