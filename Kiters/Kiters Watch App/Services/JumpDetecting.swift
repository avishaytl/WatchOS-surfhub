//
//  JumpDetecting.swift
//  Kiters Watch App
//
//  Shared surface implemented by every jump-detection engine adapter so the
//  SessionManager can plug in either engine (v7 streaming FSM or v8 batch).
//

import Foundation

/// The exact surface SessionManager drives on a jump detector. Both
/// `JumpDetector` (v7) and `JumpDetectorV8` (v8) conform.
protocol JumpDetecting: AnyObject {
    /// Session id stamped onto produced `Jump`s.
    var sessionId: String { get set }

    /// When true the engine analyses jumps INLINE / synchronously (offline
    /// JumpReplay harness). The live app keeps this false.
    var synchronousAnalysis: Bool { get set }

    /// Jump callback — emits the app's `Jump` model.
    var onJumpDetected: ((Jump) -> Void)? { get set }

    /// UI callback for state changes.
    var onStateChanged: ((JumpDetector.JumpState) -> Void)? { get set }

    func reset(mode: DetectionMode)

    func updateGPS(speed: Double,
                   altitude: Double,
                   latitude: Double,
                   longitude: Double,
                   course: Double,
                   horizontalAccuracy: Double?,
                   timestamp: Date)

    func processSample(_ sample: IMUSample)

    /// Direct CMAltimeter absolute-altitude samples. V13 consumes these so it
    /// keeps detecting jumps even if the IMU stream stalls; older engines keep
    /// the default no-op implementation.
    func processAbsoluteAltitude(sensorT: TimeInterval,
                                 receivedT: TimeInterval,
                                 altitudeM: Double,
                                 accuracyM: Double?,
                                 precisionM: Double?)

    /// Acquisition-layer recovery notification. V13 clears its altitude FSM so
    /// a new absolute-altitude datum cannot be mistaken for a jump; engines that
    /// do not consume the direct stream keep the default no-op implementation.
    func absoluteAltitudeStreamDidRestart(reason: String)

    /// Final flush at session end. The streaming v7 engine has already emitted
    /// its jumps live and returns []. The batch v8 engine runs one last analysis
    /// over its buffer and returns any jumps found in the closing seconds that
    /// were not already emitted, so the caller can fold them into the session
    /// being saved (on the main thread, before it is captured).
    func endSession() -> [Jump]
}

extension JumpDetecting {
    func processAbsoluteAltitude(sensorT: TimeInterval,
                                 receivedT: TimeInterval,
                                 altitudeM: Double,
                                 accuracyM: Double?,
                                 precisionM: Double?) {
        _ = (sensorT, receivedT, altitudeM, accuracyM, precisionM)
    }

    func absoluteAltitudeStreamDidRestart(reason: String) {
        _ = reason
    }
}
