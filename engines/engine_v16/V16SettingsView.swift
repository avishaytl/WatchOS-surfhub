//
//  V16SettingsView.swift
//  SPOTEQ Watch App
//
//  Read-only description of the calibrated V16 operating point. Thresholds
//  are intentionally not shared with, or inherited from, previous engines.
//

import SwiftUI

struct V16SettingsView: View {
    private let config = V16Config()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Label(L("settings.v16_title"), systemImage: "waveform.path.ecg.rectangle")
                    .font(.headline)
                    .foregroundColor(.cyan)

                Text(L("settings.v16_scope"))
                    .font(.caption)

                metric(L("settings.v16_trigger"), String(format: "≥ %.1f g", config.popMinG))
                metric(
                    L("settings.v16_lift_shelf"),
                    String(format: "> %.1f m/s² · ≥ %.1f s", config.liftThreshMS2, config.minLiftPlateauSec)
                )
                metric(L("settings.v16_strong_shelf"), String(format: "≥ %.2f s", config.strongShelfSec))
                metric(
                    L("settings.v16_flight_corroboration"),
                    String(format: "≥ %.1f m", config.shortShelfFlightM)
                )
                metric(
                    L("settings.v16_height_window"),
                    String(format: "t0 − %.1f s", config.heightPreRollSec)
                )
                metric(
                    L("settings.v16_post_roll"),
                    String(
                        format: "+%.1f s · air ≥ %.1f s ∨ h ≥ %.1f m · floor %.1f s",
                        config.heightPostRollSec,
                        config.heightPostRollMinAirSec,
                        config.heightPostRollMinM,
                        config.heightPostRollFloorSec
                    )
                )
                metric(
                    L("settings.v16_calibration"),
                    String(format: "%.1f×h %+.1f m", config.heightCalSlope, config.heightCalOffsetM)
                )
                metric(L("settings.v16_min_height"), String(format: "%.1f m", config.minReportM))

                Divider()

                Label(L("settings.v16_sensor_imu"), systemImage: "gyroscope")
                Label(L("settings.v16_sensor_attitude"), systemImage: "move.3d")
                Label(L("settings.v16_sensor_gps"), systemImage: "location")
                Label(L("settings.v16_sensor_no_baro"), systemImage: "barometer")

                Text(L("settings.v16_airtime_warning"))
                    .font(.system(size: 10))
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
        }
        .navigationTitle(L("settings.v16_title"))
    }

    private func metric(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.caption2).foregroundColor(.gray)
            Spacer()
            Text(verbatim: value).font(.caption).monospacedDigit()
        }
    }
}
