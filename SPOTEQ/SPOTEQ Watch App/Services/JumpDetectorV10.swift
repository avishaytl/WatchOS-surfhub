//
//  JumpDetectorV10.swift
//  SPOTEQ Watch App
//
//  Adapter for the engine_v10 KitesurfJumpEngineV10 implementation.
//

import Foundation
#if os(watchOS)
import WatchKit
#endif
import os

final class JumpDetectorV10: JumpDetecting {
    private let confidenceAsPercent = true
    private let acceptConfidence01: Double = 0.40

    var sessionId: String = ""
    var synchronousAnalysis = false
    var onJumpDetected: ((Jump) -> Void)?
    var onStateChanged: ((JumpDetector.JumpState) -> Void)?

    private var session: KitesurfSessionV10!
    private var mode: DetectionMode = .standard

    private var pendingSpeedMS: Double?
    private var pendingLat: Double?
    private var pendingLon: Double?
    private var pendingAccM: Double?
    private var latestSpeedMS: Double = 0
    private var latestSampleTimestamp: Date?
    private var t0Wall: Date?
    private var sessionWallStart: Date?
    private var sampleCount: Int = 0
    private var state: JumpDetector.JumpState = .idle

    private var gpsLock = os_unfair_lock()
    private var stateLock = os_unfair_lock()

    init() {
        buildSession(for: .standard)
    }

    func reset(mode: DetectionMode) {
        self.mode = mode
        buildSession(for: mode)

        os_unfair_lock_lock(&gpsLock)
        pendingSpeedMS = nil
        pendingLat = nil
        pendingLon = nil
        pendingAccM = nil
        latestSpeedMS = 0
        os_unfair_lock_unlock(&gpsLock)

        t0Wall = nil
        sessionWallStart = nil
        latestSampleTimestamp = nil
        sampleCount = 0

        setState(.idle)
        session.start()
        setState(.riding)

        JumpDetectorV10Log.event("JumpDetector(v10) reset - mode=\(mode.displayName) "
            + "takeoff=\(mode.takeoffG)g land=\(mode.landingG)g "
            + "air=\(mode.minAirtime)-\(mode.maxAirtime)s cd=\(mode.cooldown)s")
    }

    func updateGPS(speed: Double,
                   altitude: Double,
                   latitude: Double,
                   longitude: Double,
                   course: Double = -1,
                   horizontalAccuracy: Double? = nil,
                   timestamp: Date) {
        let v = max(0, speed)
        os_unfair_lock_lock(&gpsLock)
        pendingSpeedMS = v
        pendingLat = latitude
        pendingLon = longitude
        pendingAccM = horizontalAccuracy
        latestSpeedMS = v
        os_unfair_lock_unlock(&gpsLock)

        if state == .idle || state == .riding {
            setState(.riding)
        }
    }

    func processSample(_ sample: IMUSample) {
        sampleCount += 1
        if t0Wall == nil {
            t0Wall = sample.timestamp
            sessionWallStart = sample.timestamp
        }
        latestSampleTimestamp = sample.timestamp

        let s = makeSensorSample(sample)
        session.onSample(s)

        if state != .idle || sampleCount % 5 == 0 {
            SessionLogger.shared.logSample(
                sample: sample,
                speed: latestSpeedMS,
                baselinePressure: 0,
                lowGCount: 0,
                state: state.rawValue
            )
        }
    }

    func endSession() -> [Jump] {
        session.stop()
        return []
    }

    private func buildSession(for mode: DetectionMode) {
        var cfg = KitesurfJumpEngineV10.Config.default
        cfg.releaseFloorG = mode.takeoffG
        cfg.landingSpikeG = mode.landingG
        cfg.minAirTimeSec = mode.minAirtime
        cfg.maxAirTimeSec = mode.maxAirtime
        cfg.kinematicCalibration = mode.kinematicCalibration

        session = KitesurfSessionV10(detectorConfig: cfg,
                                     refractorySec: mode.cooldown,
                                     synchronousAnalysis: synchronousAnalysis)
        session.onStateChange = { [weak self] st in
            self?.mapV10State(st)
        }
        session.onJumpDetected = { [weak self] result in
            self?.emitJump(from: result)
        }
    }

    private func mapV10State(_ st: KitesurfSessionV10.State) {
        switch st {
        case .idle:
            setState(.idle)
        case .riding:
            setState(.riding)
        case .airborne, .analyzing:
            setState(.airborne)
        }
    }

    private func setState(_ new: JumpDetector.JumpState) {
        os_unfair_lock_lock(&stateLock)
        guard new != state else {
            os_unfair_lock_unlock(&stateLock)
            return
        }
        state = new
        os_unfair_lock_unlock(&stateLock)
        onStateChanged?(new)
        JumpDetectorV10Log.event("v10 state -> \(new.rawValue)")
    }

    private func makeSensorSample(_ s: IMUSample) -> SensorSampleV10 {
        let t = s.timestamp.timeIntervalSince(t0Wall ?? s.timestamp)
        let gravX = s.gravity?.x ?? 0
        let gravY = s.gravity?.y ?? 0
        let gravZ = s.gravity?.z ?? -1

        os_unfair_lock_lock(&gpsLock)
        let spd = pendingSpeedMS
        let lat = pendingLat
        let lon = pendingLon
        let acc = pendingAccM
        pendingSpeedMS = nil
        pendingLat = nil
        pendingLon = nil
        pendingAccM = nil
        os_unfair_lock_unlock(&gpsLock)

        return SensorSampleV10(
            t: t,
            ax: s.accelerationX,
            ay: s.accelerationY,
            az: s.accelerationZ,
            aM: s.accelerationMagnitude,
            gx: s.rotationX,
            gy: s.rotationY,
            gz: s.rotationZ,
            gM: s.rotationMagnitude,
            gravX: gravX,
            gravY: gravY,
            gravZ: gravZ,
            baro: s.pressure,
            gpsSpeedMS: spd,
            gpsLat: lat,
            gpsLon: lon,
            gpsAccuracyM: acc
        )
    }

    private func emitJump(from r: JumpResultV10) {
        guard r.confidence >= acceptConfidence01 else {
            JumpDetectorV10Log.event("v10 jump rejected by adapter conf=\(r.confidence)")
            return
        }

        let base = sessionWallStart ?? t0Wall ?? latestSampleTimestamp ?? Date()
        let start = base.addingTimeInterval(r.takeoffTimeSeconds)
        let end = base.addingTimeInterval(r.landingTimeSeconds)
        var jump = Jump(sessionId: sessionId, startTime: start)
        jump.endTime = end
        jump.height = r.jumpHeightMeters
        jump.airtime = r.airTimeSeconds
        jump.jumpDistance = r.jumpDistanceMeters ?? r.jumpDistanceGPSMeters ?? 0
        jump.rotations = r.rotations
        jump.apexTime = r.apexTimeSeconds
        jump.confidence = confidenceAsPercent ? r.confidence * 100.0 : r.confidence
        jump.imuSamples = []

        #if os(watchOS)
        let hapticsEnabled = UserDefaults.standard.object(forKey: "hapticFeedback") as? Bool ?? true
        if hapticsEnabled {
            let confidencePct = confidenceAsPercent ? jump.confidence : jump.confidence * 100
            WKInterfaceDevice.current().play(confidencePct >= 75 ? .success : .notification)
        }
        #endif

        JumpDetectorV10Log.event("JUMP(v10) ACCEPTED h=\(jump.height)m air=\(jump.airtime)s "
            + "rot=\(jump.rotations) conf=\(jump.confidence) src=\(r.heightSource.rawValue) "
            + "land=\(r.landingKind.rawValue)")

        onJumpDetected?(jump)
    }
}

private enum JumpDetectorV10Log {
    static func event(_ msg: @autoclosure () -> String) {
        let m = msg()
        SessionLogger.shared.logEvent(m)
    }
}
