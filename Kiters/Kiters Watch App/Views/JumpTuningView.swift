//
//  JumpTuningView.swift
//  Kiters Watch App
//
//  Custom tuning — 6 parameters.
//

import SwiftUI

struct JumpTuningView: View {
    @AppStorage("appLanguage") private var languageCode: String = "en"
    @AppStorage("appTheme") private var appTheme: String = "orange"

    @State private var minSpeed: Double = 15.0 / 3.6       // m/s
    @State private var takeoffG: Double = 1.5
    @State private var landingG: Double = 2.0
    @State private var minAirtime: Double = 0.5
    @State private var maxAirtime: Double = 8.0
    @State private var cooldown: Double = 1.5
    @State private var kinematicCalibration: Double = 1.12

    @State private var showResetAlert = false

    private let config = JumpDetectionConfig.shared

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
            VStack(spacing: 14) {

                Text(L("tuning.title"))
                    .font(.title3)
                    .fontWeight(.bold)
                    .padding(.bottom, 4)

                Text(L("tuning.subtitle"))
                    .font(.system(size: 10))
                    .foregroundColor(.gray)
                    .multilineTextAlignment(.center)

                Divider()

                // ── 6 Parameters ──

                parameterRow(
                    label: L("tuning.min_speed"),
                    value: $minSpeed,
                    range: 0.0...10.0,
                    step: 0.28,
                    help: L("tuning.min_speed_help"),
                    display: .speed
                )

                parameterRow(
                    label: L("tuning.takeoff_g"),
                    value: $takeoffG,
                    range: 0.5...4.0,
                    step: 0.1,
                    help: L("tuning.takeoff_g_help"),
                    display: .unit("g")
                )

                parameterRow(
                    label: L("tuning.landing_g"),
                    value: $landingG,
                    range: 0.5...5.0,
                    step: 0.1,
                    help: L("tuning.landing_g_help"),
                    display: .unit("g")
                )

                parameterRow(
                    label: L("tuning.min_airtime"),
                    value: $minAirtime,
                    range: 0.1...2.0,
                    step: 0.05,
                    help: L("tuning.min_airtime_help"),
                    display: .unit("s")
                )

                parameterRow(
                    label: L("tuning.max_airtime"),
                    value: $maxAirtime,
                    range: 2.0...15.0,
                    step: 0.5,
                    help: L("tuning.max_airtime_help"),
                    display: .unit("s")
                )

                parameterRow(
                    label: L("tuning.cooldown"),
                    value: $cooldown,
                    range: 0.5...10.0,
                    step: 0.5,
                    help: L("tuning.cooldown_help"),
                    display: .unit("s")
                )

                parameterRow(
                    label: L("tuning.kinematic_calibration"),
                    value: $kinematicCalibration,
                    range: 0.8...1.5,
                    step: 0.01,
                    help: L("tuning.kinematic_calibration_help"),
                    display: .unit("×")
                )

                Divider()

                // Info box
                HStack(spacing: 6) {
                    Image(systemName: "barometer")
                        .foregroundColor(.cyan)
                    Text(L("tuning.baro_info"))
                        .font(.system(size: 9))
                        .foregroundColor(.gray)
                }
                .padding(8)
                .background(Color.cyan.opacity(0.08))
                .cornerRadius(8)

                // Reset
                Button(action: { showResetAlert = true }) {
                    HStack {
                        Image(systemName: "arrow.counterclockwise")
                        Text(L("tuning.reset"))
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
        // .watchScrollTopShadow()
        .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
        .onAppear { loadFromConfig() }
        .alert(L("tuning.reset_confirm"), isPresented: $showResetAlert) {
            Button(L("session.cancel"), role: .cancel) { }
            Button(L("tuning.reset"), role: .destructive) {
                config.resetToDefaults()
                loadFromConfig()
            }
        }
    }

    // MARK: - Display Mode

    private enum DisplayMode {
        case speed       // shows km/h converted from m/s
        case unit(String) // shows value + unit
    }

    // MARK: - Parameter Row

    @ViewBuilder
    private func parameterRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double,
        help: String,
        display: DisplayMode
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundColor(.white)
                Spacer()
                switch display {
                case .speed:
                    Text(String(format: "%.0f km/h", value.wrappedValue * 3.6))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(themeColor)
                case .unit(let u):
                    Text(String(format: "%.2f %@", value.wrappedValue, u))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundColor(themeColor)
                }
            }

            Slider(value: value, in: range, step: step)
                .tint(themeColor)

            HStack {
                Button(action: {
                    let new = value.wrappedValue - step
                    if new >= range.lowerBound { value.wrappedValue = new }
                    saveToConfig()
                }) {
                    Image(systemName: "minus.circle")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                .buttonStyle(.plain)

                Spacer()

                Text(help)
                    .font(.system(size: 8))
                    .foregroundColor(.gray.opacity(0.7))
                    .multilineTextAlignment(.center)

                Spacer()

                Button(action: {
                    let new = value.wrappedValue + step
                    if new <= range.upperBound { value.wrappedValue = new }
                    saveToConfig()
                }) {
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
        .onChange(of: value.wrappedValue) { _, _ in saveToConfig() }
    }

    // MARK: - Persistence

    private func loadFromConfig() {
        minSpeed             = config.minSpeed
        takeoffG             = config.takeoffG
        landingG             = config.landingG
        minAirtime           = config.minAirtime
        maxAirtime           = config.maxAirtime
        cooldown             = config.cooldown
        kinematicCalibration = config.kinematicCalibration
    }

    private func saveToConfig() {
        config.minSpeed             = minSpeed
        config.takeoffG             = takeoffG
        config.landingG             = landingG
        config.minAirtime           = minAirtime
        config.maxAirtime           = maxAirtime
        config.cooldown             = cooldown
        config.kinematicCalibration = kinematicCalibration
    }
}

#Preview {
    NavigationView {
        JumpTuningView()
    }
}
