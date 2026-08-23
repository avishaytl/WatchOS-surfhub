//
//  JumpDetectorV11.swift
//  SPOTEQ Watch App
//
//  Adapter for the v11 Offline Buffered Jump Detection Engine
//  (KitesurfJumpEngineV11). Conforms to the shared `JumpDetecting` surface so
//  SessionManager can swap it in for v7/v8/v10 with no other changes.
//
//  Unlike the streaming engines, v11 buffers every event and analyses
//  complete jump segments on a 3–5 s background schedule, so jumps surface a
//  few seconds after they happen — in exchange for fewer false positives and
//  more reliable metrics.
//

import Foundation
#if os(watchOS)
import WatchKit
#endif
import os

final class JumpDetectorV11: JumpDetecting {
    private let confidenceAsPercent = true
    /// The engine's CandidateRankingScorer is the authoritative accept gate
    /// (cfg.rankAcceptScore). The adapter must NOT re-gate above that or it would
    /// silently drop jumps the engine accepted — keep this below the engine's
    /// threshold so it never overrides it.
    private let acceptConfidence01: Double = 0.30

    var sessionId: String = ""
    var synchronousAnalysis = false
    var onJumpDetected: ((Jump) -> Void)?
    var onStateChanged: ((JumpDetector.JumpState) -> Void)?

    /// Full v11 result stream (score + reason codes + rich metrics) for the
    /// comparison runner / debug export. The `Jump` model can't carry all of it.
    var onJumpResultV11: ((JumpResultV11) -> Void)?
    /// Accepted + rejected segment debug records, available after the run.
    var debugSegments: [JumpSegmentDebugV11] { session?.debugSegments ?? [] }
    /// Raw candidates (pre-clustering) and final clusters for the eval harness.
    var rawCandidates: [JumpRawCandidateV11] { session?.rawCandidates ?? [] }
    var clusters: [JumpClusterV11] { session?.clusters ?? [] }

    private var session: KitesurfSessionV11!
    private var mode: DetectionMode = .standard

    private var pendingSpeedMS: Double?
    private var pendingLat: Double?
    private var pendingLon: Double?
    private var pendingAccM: Double?
    private var pendingCourse: Double?
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
        pendingCourse = nil
        latestSpeedMS = 0
        os_unfair_lock_unlock(&gpsLock)

        t0Wall = nil
        sessionWallStart = nil
        latestSampleTimestamp = nil
        sampleCount = 0

        setState(.idle)
        session.start()
        setState(.riding)

        JumpDetectorV11Log.event("JumpDetector(v11-buffered) reset - mode=\(mode.displayName) "
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
        pendingCourse = course >= 0 ? course : nil
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
        // v11 buffers jumps and emits them on its background schedule. The final
        // flush analyses anything still pending so the closing seconds of the
        // session are not lost. Collect those late jumps and hand them back so
        // the caller can fold them into the session being saved.
        var lateJumps: [Jump] = []
        let prior = onJumpDetected
        onJumpDetected = { jump in
            prior?(jump)
            lateJumps.append(jump)
        }
        session.stop()
        onJumpDetected = prior
        return lateJumps
    }

    private func buildSession(for mode: DetectionMode) {
        var cfg = JumpEngineV11Config.default
        cfg.releaseFloorG = mode.takeoffG
        cfg.landingSpikeG = mode.landingG
        cfg.minAirTimeSec = mode.minAirtime
        cfg.maxAirTimeSec = mode.maxAirtime
        cfg.minRidingSpeedMS = mode.minSpeed
        cfg.kinematicCalibration = mode.kinematicCalibration

        session = KitesurfSessionV11(detectorConfig: cfg,
                                     refractorySec: mode.cooldown,
                                     synchronousAnalysis: synchronousAnalysis)
        session.onStateChange = { [weak self] st in
            self?.mapV11State(st)
        }
        session.onJumpDetected = { [weak self] result in
            self?.emitJump(from: result)
        }
    }

    private func mapV11State(_ st: KitesurfSessionV11.State) {
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
        JumpDetectorV11Log.event("v11 state -> \(new.rawValue)")
    }

    private func makeSensorSample(_ s: IMUSample) -> SensorSampleV11 {
        let t = s.timestamp.timeIntervalSince(t0Wall ?? s.timestamp)
        let gravX = s.gravity?.x ?? 0
        let gravY = s.gravity?.y ?? 0
        let gravZ = s.gravity?.z ?? -1

        os_unfair_lock_lock(&gpsLock)
        let spd = pendingSpeedMS
        let lat = pendingLat
        let lon = pendingLon
        let acc = pendingAccM
        let course = pendingCourse
        pendingSpeedMS = nil
        pendingLat = nil
        pendingLon = nil
        pendingAccM = nil
        pendingCourse = nil
        os_unfair_lock_unlock(&gpsLock)

        return SensorSampleV11(
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
            gpsAccuracyM: acc,
            gpsCourse: course,
            submerged: s.submerged,
            waterDepthM: s.waterDepth,
            waterPressureHPa: s.waterPressure
        )
    }

    private func emitJump(from r: JumpResultV11) {
        onJumpResultV11?(r)

        guard r.confidence >= acceptConfidence01 else {
            JumpDetectorV11Log.event("v11 jump rejected by adapter conf=\(r.confidence)")
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
        // v11's quality score IS the confidence the rest of the app reads (0–100).
        jump.confidence = confidenceAsPercent ? r.score : r.score / 100.0
        jump.imuSamples = []

        #if os(watchOS)
        let hapticsEnabled = UserDefaults.standard.object(forKey: "hapticFeedback") as? Bool ?? true
        if hapticsEnabled {
            WKInterfaceDevice.current().play(r.score >= 75 ? .success : .notification)
        }
        #endif

        JumpDetectorV11Log.event("JUMP(v11) ACCEPTED h=\(jump.height)m air=\(jump.airtime)s "
            + "rot=\(jump.rotations) score=\(r.score) label=\(r.label) "
            + "src=\(r.heightSource.rawValue) land=\(r.landingKind.rawValue) "
            + "reasons=\(r.reasonCodes.joined(separator: ","))")

        onJumpDetected?(jump)
    }
}

private enum JumpDetectorV11Log {
    static func event(_ msg: @autoclosure () -> String) {
        let m = msg()
        SessionLogger.shared.logEvent(m)
    }
}
