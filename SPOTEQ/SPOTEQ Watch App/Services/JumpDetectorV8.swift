//
//  JumpDetectorV8.swift
//  SPOTEQ Watch App
//
//  Adapter that drives the v8 (baro-centric, whole-session batch) engine
//  `KitesurfJumpEngineV8.detectJumps` with the SAME public surface the app's
//  v7 `JumpDetector` exposes (see JumpDetecting).
//
//  v8 is a WHOLE-SESSION batch detector, so this adapter buffers samples on an
//  absolute monotonic timeline and re-runs detection periodically over a
//  trailing window, emitting any newly-found jumps live (count + haptic). A
//  final synchronous flush at session end catches a jump in the closing seconds.
//

import Foundation
#if canImport(WatchKit)
import WatchKit
#endif

final class JumpDetectorV8: JumpDetecting {

    // MARK: - JumpDetecting surface

    var sessionId: String = ""
    var synchronousAnalysis = false          // unused by v8 (kept for protocol parity)
    var onJumpDetected: ((Jump) -> Void)?
    var onStateChanged: ((JumpDetector.JumpState) -> Void)?

    /// Adapter-level accept gate (matches the v7 adapter). v8 confidence is 0…1.
    private let acceptConfidence01: Double = 0.40

    /// Engine parameters for live watch detection.
    private var params: JumpEngineV8Params = {
        var p = JumpEngineV8Params.default
        // The ballistic throw path is useful in replay/lab tools, but live
        // kitesurf sessions should only count rider jumps.
        p.detectThrows = false
        return p
    }()

    // MARK: - Time base (absolute monotonic ms since first sample)

    private var t0Wall: Date?
    private var sessionWallStart: Date?
    private var sampleCount: Int = 0

    // MARK: - Sample buffer (trailing window, absolute ms timeline)

    private var buffer: [V8Sample] = []
    private var bufferLock = os_unfair_lock()
    /// ≥ baselineHalfWinSec (15 s) + a jump + separation, with headroom.
    private let trailingWindowMs: Double = 120_000

    // MARK: - GPS one-shot (mirrors v7 JumpDetector)

    private var pendingSpeedMS: Double?
    private var pendingLat: Double?
    private var pendingLon: Double?
    private var latestSpeedMS: Double = 0
    private var gpsLock = os_unfair_lock()

    // MARK: - State

    private var state: JumpDetector.JumpState = .idle
    private var stateLock = os_unfair_lock()

    // MARK: - Re-analysis (throttled, off the motion thread)

    private let analyzeQueue = DispatchQueue(label: "com.spoteq.jumpV8.analyze")
    private let analyzeIntervalMs: Double = 5_000
    private var lastAnalyzeSampleT: Double = -Double.infinity
    /// Takeoff times (ms) already emitted — dedup across re-runs. Touched only on `analyzeQueue`.
    private var emittedTakeoffMs: [Double] = []

    // MARK: - Public API

    func reset(mode: DetectionMode) {
        os_unfair_lock_lock(&bufferLock)
        buffer.removeAll(keepingCapacity: true)
        os_unfair_lock_unlock(&bufferLock)

        os_unfair_lock_lock(&gpsLock)
        pendingSpeedMS = nil; pendingLat = nil; pendingLon = nil; latestSpeedMS = 0
        os_unfair_lock_unlock(&gpsLock)

        t0Wall = nil
        sessionWallStart = nil
        sampleCount = 0
        lastAnalyzeSampleT = -Double.infinity
        analyzeQueue.sync { emittedTakeoffMs.removeAll() }

        setState(.idle)
        setState(.riding)

        logEvent("JumpDetector(v8) reset — baro-centric, detectThrows=\(params.detectThrows) "
            + "minH=\(params.minJumpHeightM)m window=\(Int(trailingWindowMs/1000))s")
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
        latestSpeedMS = v
        os_unfair_lock_unlock(&gpsLock)

        if state == .idle || state == .riding { setState(.riding) }
    }

    func processSample(_ sample: IMUSample) {
        sampleCount += 1
        if t0Wall == nil {
            t0Wall = sample.timestamp
            sessionWallStart = sample.timestamp
        }

        let s = makeV8Sample(sample)   // reads + clears the one-shot GPS fix
        let due = s.t - lastAnalyzeSampleT >= analyzeIntervalMs

        os_unfair_lock_lock(&bufferLock)
        buffer.append(s)
        // Trim the front of the window (samples older than the trailing window).
        let cutoff = s.t - trailingWindowMs
        if let first = buffer.first, first.t < cutoff {
            var drop = 0
            while drop < buffer.count && buffer[drop].t < cutoff { drop += 1 }
            if drop > 0 { buffer.removeFirst(drop) }
        }
        let snapshot: [V8Sample]? = due ? buffer : nil   // COW copy only when analysing
        os_unfair_lock_unlock(&bufferLock)

        // Per-sample diagnostics trace (same cadence as v7 so .kslog/CSV + cloud upload keep working).
        if state != .idle || sampleCount % 5 == 0 {
            SessionLogger.shared.logSample(
                sample: sample,
                speed: latestSpeedMS,
                baselinePressure: 0,
                lowGCount: 0,
                state: state.rawValue
            )
        }

        if due, let snap = snapshot {
            lastAnalyzeSampleT = s.t
            analyzeQueue.async { [weak self] in
                guard let self = self else { return }
                let results = KitesurfJumpEngineV8.detectJumps(snap, self.params)
                self.emitNewLiveJumps(results)
            }
        }
    }

    /// Final synchronous flush. Returns any not-yet-emitted jumps so the caller
    /// can fold them into the session being saved (on the main thread).
    func endSession() -> [Jump] {
        os_unfair_lock_lock(&bufferLock)
        let snap = buffer
        os_unfair_lock_unlock(&bufferLock)

        var newJumps: [Jump] = []
        analyzeQueue.sync {
            let results = KitesurfJumpEngineV8.detectJumps(snap, self.params)
            for r in results where isNewAcceptedJump(r) {
                emittedTakeoffMs.append(r.takeoffTimeMs ?? 0)
                newJumps.append(makeJump(from: r))
            }
        }
        logEvent("JumpDetector(v8) endSession flush — \(newJumps.count) final jump(s)")
        return newJumps
    }

    // MARK: - Emit (live path, runs on analyzeQueue)

    private func emitNewLiveJumps(_ results: [JumpResultV8]) {
        for r in results where isNewAcceptedJump(r) {
            emittedTakeoffMs.append(r.takeoffTimeMs ?? 0)
            let jump = makeJump(from: r)
            playHaptic(for: jump)
            logEvent("JUMP(v8) ACCEPTED h=\(jump.height)m air=\(jump.airtime)s "
                + "conf=\(jump.confidence) src=\(r.heightSource.rawValue)")
            onJumpDetected?(jump)
        }
    }

    /// Dedup + confidence gate. MUST be called on `analyzeQueue` (touches `emittedTakeoffMs`).
    private func isNewAcceptedJump(_ r: JumpResultV8) -> Bool {
        guard let toMs = r.takeoffTimeMs else { return false }
        guard r.confidence >= acceptConfidence01 else { return false }
        guard r.airTimeSec >= params.minAirTimeSec else { return false }
        let sepMs = params.jumpSepSec * 1000
        if emittedTakeoffMs.contains(where: { abs($0 - toMs) < sepMs }) { return false }
        return true
    }

    private func makeJump(from r: JumpResultV8) -> Jump {
        let base = sessionWallStart ?? t0Wall ?? Date()
        let start = base.addingTimeInterval((r.takeoffTimeMs ?? 0) / 1000)
        let end = base.addingTimeInterval((r.landingTimeMs ?? 0) / 1000)
        var jump = Jump(sessionId: sessionId, startTime: start)
        jump.endTime      = end
        jump.height       = r.jumpHeightM
        jump.airtime      = r.airTimeSec
        jump.jumpDistance = r.jumpDistanceM ?? 0
        jump.rotations    = 0                     // v8 does not estimate rotations
        jump.apexTime     = r.apexTimeSec
        jump.confidence   = r.confidence * 100.0  // app stores confidence as 0…100
        jump.imuSamples   = []
        return jump
    }

    private func playHaptic(for jump: Jump) {
        #if os(watchOS)
        let hapticsEnabled = UserDefaults.standard.object(forKey: "hapticFeedback") as? Bool ?? true
        if hapticsEnabled {
            WKInterfaceDevice.current().play(jump.confidence >= 75 ? .success : .notification)
        }
        #endif
    }

    // MARK: - IMUSample → V8Sample

    private func makeV8Sample(_ s: IMUSample) -> V8Sample {
        let tMs = s.timestamp.timeIntervalSince(t0Wall ?? s.timestamp) * 1000

        let gvX = s.gravity?.x ?? 0
        let gvY = s.gravity?.y ?? 0
        let gvZ = s.gravity?.z ?? -1   // default "up" if gravity missing

        os_unfair_lock_lock(&gpsLock)
        let spd = pendingSpeedMS, lat = pendingLat, lon = pendingLon
        pendingSpeedMS = nil; pendingLat = nil; pendingLon = nil
        os_unfair_lock_unlock(&gpsLock)

        return V8Sample(
            t:  tMs,
            ax: s.accelerationX, ay: s.accelerationY, az: s.accelerationZ,
            aM: s.accelerationMagnitude,
            gx: s.rotationX, gy: s.rotationY, gz: s.rotationZ,
            gM: s.rotationMagnitude,
            gvX: gvX, gvY: gvY, gvZ: gvZ,
            baro: s.pressure,
            spd: spd, lat: lat, lng: lon
        )
    }

    // MARK: - State

    private func setState(_ new: JumpDetector.JumpState) {
        os_unfair_lock_lock(&stateLock)
        guard new != state else { os_unfair_lock_unlock(&stateLock); return }
        state = new
        os_unfair_lock_unlock(&stateLock)
        onStateChanged?(new)
    }

    private func logEvent(_ msg: @autoclosure () -> String) {
        let m = msg()
        #if DEBUG
        print("🦘 \(m)")
        #endif
        SessionLogger.shared.logEvent(m)
    }
}
