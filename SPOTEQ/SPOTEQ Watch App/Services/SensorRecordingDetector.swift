//
//  SensorRecordingDetector.swift
//  SPOTEQ Watch App
//
//  The "engine" behind the sensor-recording session: it detects nothing and
//  computes nothing. Its only job is to satisfy the JumpDetecting slot so the
//  whole acquisition pipeline (IMU 200Hz, relative + absolute altimeter, GPS,
//  submersion) runs exactly as in a real session and every sample lands in
//  the .kslog unmodified — a ground-truth capture of sensor behaviour on the
//  water, free of any formula's side effects.
//

import Foundation

final class SensorRecordingDetector: JumpDetecting {
    var sessionId: String = ""
    var synchronousAnalysis: Bool = false
    var onJumpDetected: ((Jump) -> Void)?
    var onStateChanged: ((JumpDetector.JumpState) -> Void)?

    func reset(mode: DetectionMode) {
        SessionLogger.shared.logEvent("Sensor recording session: no detection engine active")
    }

    func updateGPS(speed: Double,
                   altitude: Double,
                   latitude: Double,
                   longitude: Double,
                   course: Double,
                   horizontalAccuracy: Double?,
                   timestamp: Date) {}

    func processSample(_ sample: IMUSample) {}

    func endSession() -> [Jump] { [] }
}
