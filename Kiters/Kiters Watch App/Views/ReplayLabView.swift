//
//  ReplayLabView.swift
//  Kiters Watch App
//
//  Hardware-in-the-loop controls and debug overlay for timestamp-faithful
//  replay of locally recorded KSLG sessions.
//

import SwiftUI

struct ReplayLabView: View {
    @StateObject private var controller = ReplaySessionController()
    @AppStorage("appLanguage") private var languageCode: String = "en"
    @AppStorage("appTheme") private var appTheme: String = "orange"

    private var themeColor: Color {
        switch appTheme {
        case "yellow": return .yellow
        case "green": return .green
        case "red": return .red
        case "cyan": return .cyan
        case "pink": return .pink
        default: return .orange
        }
    }

    private var selectableEngines: [DetectionEngine] {
        DetectionEngine.allCases.filter { $0 != .sensorRecorder }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(L("replay.title"))
                    .font(.headline)

                if controller.sessions.isEmpty {
                    emptyState
                } else {
                    sessionPicker
                    engineAndSpeedPickers

                    if controller.isLoading {
                        ProgressView(L("replay.loading"))
                            .font(.caption)
                    } else if let error = controller.errorMessage {
                        Text(error)
                            .font(.caption2)
                            .foregroundColor(.red)
                    } else {
                        timeline
                        controls
                        validationSummary
                        debugOverlay
                        resultSummary
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
        }
        .environment(\.layoutDirection, languageCode == "he" ? .rightToLeft : .leftToRight)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { controller.refreshSessions() }
        .onDisappear { controller.shutdown() }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform.path.badge.plus")
                .font(.title2)
                .foregroundColor(.gray)
            Text(L("replay.no_logs"))
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }

    private var sessionPicker: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("replay.session"))
                .font(.caption2)
                .foregroundColor(.gray)
            Picker(
                L("replay.session"),
                selection: Binding(
                    get: { controller.selectedSessionID ?? "" },
                    set: { controller.selectSession($0) }
                )
            ) {
                ForEach(controller.sessions) { session in
                    Text(session.displayName)
                        .lineLimit(1)
                        .tag(session.id)
                }
            }
            .pickerStyle(.navigationLink)
            .labelsHidden()
        }
    }

    private var engineAndSpeedPickers: some View {
        HStack(spacing: 6) {
            Picker(
                L("replay.engine"),
                selection: Binding(
                    get: { controller.selectedEngine },
                    set: { controller.selectEngine($0) }
                )
            ) {
                ForEach(selectableEngines, id: \.self) { engine in
                    Text(engine.displayName).tag(engine)
                }
            }
            .pickerStyle(.navigationLink)
            .labelsHidden()

            Picker(
                L("replay.speed"),
                selection: Binding(
                    get: { controller.replaySpeed },
                    set: { controller.setSpeed($0) }
                )
            ) {
                Text("1×").tag(1.0)
                Text("2×").tag(2.0)
                Text("5×").tag(5.0)
                Text("10×").tag(10.0)
            }
            .pickerStyle(.navigationLink)
            .labelsHidden()
            .frame(width: 62)
        }
    }

    private var timeline: some View {
        VStack(spacing: 4) {
            ProgressView(value: controller.progress)
                .tint(themeColor)
            HStack {
                Text(formatTime(controller.currentSeconds))
                Spacer()
                statusLabel
                Spacer()
                Text(formatTime(controller.durationSeconds))
            }
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundColor(.gray)
        }
    }

    private var statusLabel: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(statusColor)
                .frame(width: 5, height: 5)
            Text(statusText)
        }
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                controlButton(icon: "gobackward.5", accessibility: "replay.seek_back") {
                    controller.seek(by: -5)
                }
                controlButton(
                    icon: controller.state == .playing ? "pause.fill" : "play.fill",
                    accessibility: controller.state == .playing ? "replay.pause" : "replay.play",
                    prominent: true
                ) {
                    controller.togglePlayPause()
                }
                controlButton(icon: "goforward.5", accessibility: "replay.seek_forward") {
                    controller.seek(by: 5)
                }
            }

            HStack(spacing: 8) {
                Button {
                    controller.stop()
                } label: {
                    Label(L("replay.stop"), systemImage: "stop.fill")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.bordered)

                Button {
                    controller.restart()
                } label: {
                    Label(L("replay.restart"), systemImage: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(.bordered)
            }
        }
        .disabled(controller.isSeeking)
        .overlay {
            if controller.isSeeking {
                ProgressView()
                    .scaleEffect(0.7)
            }
        }
    }

    private var validationSummary: some View {
        Group {
            if let summary = controller.logSummary {
                HStack(spacing: 8) {
                    miniMetric(
                        value: "\(summary.counts.motion)",
                        label: L("replay.imu_samples")
                    )
                    miniMetric(
                        value: "\(summary.counts.absoluteAltitude + summary.counts.barometer)",
                        label: L("replay.alt_samples")
                    )
                    miniMetric(
                        value: "\(summary.outOfOrderRecordCount)",
                        label: L("replay.out_of_order"),
                        warning: summary.outOfOrderRecordCount > 0
                    )
                }
            }
        }
    }

    private var debugOverlay: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("replay.debug_overlay"))
                .font(.caption2)
                .foregroundColor(.gray)
                .textCase(.uppercase)

            metricRow("IMU |a|", value(controller.telemetry.accelerationMagnitude, unit: "g", decimals: 2))
            metricRow("Vertical", value(controller.telemetry.verticalLoadG, unit: "g", decimals: 2))
            metricRow("Gyro", value(controller.telemetry.gyroMagnitude, unit: "rad/s", decimals: 2))
            metricRow("Pressure", optionalValue(controller.telemetry.pressureHPa, unit: "hPa", decimals: 1))
            metricRow("Rel altitude", optionalValue(controller.telemetry.relativeAltitudeM, unit: "m", decimals: 2))
            metricRow("Abs altitude", optionalValue(controller.telemetry.absoluteAltitudeM, unit: "m", decimals: 2))
            metricRow("Baseline", optionalValue(controller.telemetry.baselineM, unit: "m", decimals: 2))
            metricRow(L("replay.fsm_state"), controller.telemetry.state.uppercased())
            metricRow(L("replay.candidate"), controller.telemetry.candidate ? L("common.yes") : L("common.no"))
            metricRow(
                L("replay.jump_height"),
                optionalValue(controller.telemetry.latestHeightM, unit: "m", decimals: 2)
            )

            if !controller.telemetry.debugFlags.isEmpty {
                Text(controller.telemetry.debugFlags)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.yellow)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }

    private var resultSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("\(controller.jumps.count)", systemImage: "figure.kitesurfing")
                    .font(.caption)
                Spacer()
                regressionBadge
            }

            ForEach(controller.jumps.prefix(5)) { jump in
                HStack {
                    Text(formatTime(Double(jump.takeoffNs) / 1_000_000_000))
                    Spacer()
                    Text(String(format: "%.2f m", jump.heightM))
                        .foregroundColor(themeColor)
                    Text(String(format: "%.2f s", jump.airtimeSec))
                }
                .font(.system(size: 9, design: .monospaced))
            }

            if controller.report != nil {
                Button(L("replay.save_baseline")) {
                    controller.saveCurrentAsBaseline()
                }
                .font(.caption2)
                .buttonStyle(.bordered)
            }

            if let filename = controller.telemetryFilename {
                Text(String(format: L("replay.telemetry_file"), filename))
                    .font(.system(size: 8))
                    .foregroundColor(.gray)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.05))
        .cornerRadius(8)
    }

    @ViewBuilder
    private var regressionBadge: some View {
        switch controller.regressionState {
        case .unavailable:
            EmptyView()
        case .noBaseline:
            Text(L("replay.no_baseline"))
                .foregroundColor(.gray)
                .font(.caption2)
        case .matches:
            Label(L("replay.match"), systemImage: "checkmark.seal.fill")
                .foregroundColor(.green)
                .font(.caption2)
        case .differs:
            Label(L("replay.differs"), systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.caption2)
        }
    }

    private func controlButton(
        icon: String,
        accessibility: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: prominent ? 17 : 14, weight: .bold))
                .frame(width: prominent ? 38 : 32, height: 30)
        }
        .buttonStyle(.bordered)
        .tint(prominent ? themeColor : .gray)
        .accessibilityLabel(L(accessibility))
    }

    private func miniMetric(
        value: String,
        label: String,
        warning: Bool = false
    ) -> some View {
        VStack(spacing: 1) {
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(warning ? .orange : .white)
            Text(label)
                .font(.system(size: 7))
                .foregroundColor(.gray)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private func metricRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.gray)
            Spacer()
            Text(value)
                .foregroundColor(.white)
        }
        .font(.system(size: 9, design: .monospaced))
    }

    private func value(_ number: Double, unit: String, decimals: Int) -> String {
        String(format: "%.\(decimals)f %@", number, unit)
    }

    private func optionalValue(_ number: Double?, unit: String, decimals: Int) -> String {
        guard let number else { return "--" }
        return value(number, unit: unit, decimals: decimals)
    }

    private func formatTime(_ seconds: Double) -> String {
        let whole = max(0, Int(seconds))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }

    private var statusText: String {
        switch controller.state {
        case .stopped: return L("replay.stopped")
        case .playing: return L("replay.playing")
        case .paused: return L("replay.paused")
        case .finished: return L("replay.finished")
        case .failed: return L("replay.failed")
        }
    }

    private var statusColor: Color {
        switch controller.state {
        case .playing: return .green
        case .paused: return .yellow
        case .finished: return .cyan
        case .failed: return .red
        case .stopped: return .gray
        }
    }
}
