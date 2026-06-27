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

    /// Final flush at session end. The streaming v7 engine has already emitted
    /// its jumps live and returns []. The batch v8 engine runs one last analysis
    /// over its buffer and returns any jumps found in the closing seconds that
    /// were not already emitted, so the caller can fold them into the session
    /// being saved (on the main thread, before it is captured).
    func endSession() -> [Jump]
}
