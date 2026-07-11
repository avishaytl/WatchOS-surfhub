//
//  JumpDetectorV9.swift
//  Kiters Watch App
//
//  Adapter that drives the v9 cyclic-buffer SCANNER (JumpScannerV9) with the SAME
//  public surface the app's v7 `JumpDetector` exposes (see JumpDetecting).
//
//  v9 is an ARCHITECTURE on top of the proven v8 baro-centric engine: every sample
//  is pushed into a bounded ring buffer, and every `tickSec` the FULL v8 engine is
//  re-run backwards over the window. Each jump is tracked as one pending with a
//  two-stage lifecycle (provisional → final).
//
//  This adapter surfaces jumps in TWO stages, matched by the scanner's stable id:
//    • PROVISIONAL (~4 s after landing) → `onJumpDetected`: a live jump appears fast.
//    • FINAL (~settleSec later) → `onJumpUpdated`: the SAME jump is refined in place
//      with the accurate measurement once the apex's future baseline is in-window.
//  A provisional the full-baseline re-analysis later rejects is REMOVED via
//  `onJumpRetracted`. If a provisional was gated out but its FINAL clears the gate,
//  the accurate jump is surfaced as new. A flush at session end resolves anything
//  still pending in the closing seconds.
//
//  NOTE: `onJumpUpdated`/`onJumpRetracted` are v9-only and NOT part of the shared
//  `JumpDetecting` surface. SessionManager downcasts to wire them, so the other
//  engines (which emit each jump exactly once) are untouched.
//

import Foundation
#if canImport(WatchKit)
import WatchKit
#endif

final class JumpDetectorV9: JumpDetecting {

    // MARK: - JumpDetecting surface

    var sessionId: String = ""
    var synchronousAnalysis = false          // unused by v9 (kept for protocol parity)
    var onJumpDetected: ((Jump) -> Void)?
    var onStateChanged: ((JumpDetector.JumpState) -> Void)?

    /// v9-only refinement callbacks (wired by SessionManager via a downcast).
    /// `onJumpUpdated` replaces an already-emitted jump in place (same `Jump.id`);
    /// `onJumpRetracted` removes a provisional jump the full baseline rejected.
    var onJumpUpdated: ((Jump) -> Void)?
    var onJumpRetracted: ((String) -> Void)?

    /// Adapter-level accept gate (matches the v8 adapter). v8/v9 confidence is 0…1.
    private let acceptConfidence01: Double = 0.40

    /// Engine parameters for live watch detection (shared with the v8 adapter).
    private var params: JumpEngineV8Params = {
        var p = JumpEngineV8Params.default
        // The ballistic throw path is useful in replay/lab tools, but live
        // kitesurf sessions should only count rider jumps.
        p.detectThrows = false
        return p
    }()

    private let cfg = ScanConfigV9.default

    // MARK: - Scanner (owns the ring buffer + pending lifecycle)
    //  Touched ONLY on `analyzeQueue` so it never races the motion thread.

    private var scanner = JumpScannerV9(JumpEngineV8Params.default, ScanConfigV9.default)
    private let analyzeQueue = DispatchQueue(label: "com.kiters.jumpV9.analyze")

    /// scanner id → the app `Jump` surfaced for it (provisional), so its later FINAL
    /// can refine the same jump in place. Touched ONLY on `analyzeQueue`.
    private var liveJumps: [Int: Jump] = [:]

    // MARK: - Time base (absolute monotonic ms since first sample)

    private var t0Wall: Date?
    private var sessionWallStart: Date?
    private var sampleCount: Int = 0
    private var lastSampleT: Double = 0     // ms, for flush(now) at session end

    // MARK: - Sample staging (drained into the scanner on the tick cadence)

    private var staging: [V8Sample] = []
    private var stagingLock = os_unfair_lock()
    private var lastScanSampleT: Double = -Double.infinity

    // MARK: - GPS one-shot (mirrors v7/v8 JumpDetector)

    private var pendingSpeedMS: Double?
    private var pendingLat: Double?
    private var pendingLon: Double?
    private var latestSpeedMS: Double = 0
    private var gpsLock = os_unfair_lock()

    // MARK: - State

    private var state: JumpDetector.JumpState = .idle
    private var stateLock = os_unfair_lock()

    // MARK: - Public API

    func reset(mode: DetectionMode) {
        os_unfair_lock_lock(&stagingLock)
        staging.removeAll(keepingCapacity: true)
        lastScanSampleT = -Double.infinity
        os_unfair_lock_unlock(&stagingLock)

        os_unfair_lock_lock(&gpsLock)
        pendingSpeedMS = nil; pendingLat = nil; pendingLon = nil; latestSpeedMS = 0
        os_unfair_lock_unlock(&gpsLock)

        t0Wall = nil
        sessionWallStart = nil
        sampleCount = 0
        lastSampleT = 0

        // Rebuild the scanner on its own queue so a stray late block from a prior
        // session can never observe a half-reset instance.
        analyzeQueue.sync {
            scanner = JumpScannerV9(params, cfg)
            liveJumps.removeAll()
        }

        setState(.idle)
        setState(.riding)

        logEvent("JumpDetector(v9) reset — scan tick=\(Int(cfg.tickSec))s window=\(Int(cfg.windowSec))s "
            + "settle=\(Int(cfg.settleSec))s detectThrows=\(params.detectThrows) minH=\(params.minJumpHeightM)m")
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
        lastSampleT = s.t

        // Stage the sample; drain into the scanner only on the tick cadence.
        os_unfair_lock_lock(&stagingLock)
        staging.append(s)
        let due = s.t - lastScanSampleT >= cfg.tickSec * 1000
        var batch: [V8Sample]? = nil
        if due {
            batch = staging
            staging.removeAll(keepingCapacity: true)
            lastScanSampleT = s.t
        }
        os_unfair_lock_unlock(&stagingLock)

        // Per-sample diagnostics trace (same cadence as v7/v8 so .kslog/CSV + cloud upload keep working).
        if state != .idle || sampleCount % 5 == 0 {
            SessionLogger.shared.logSample(
                sample: sample,
                speed: latestSpeedMS,
                baselinePressure: 0,
                lowGCount: 0,
                state: state.rawValue
            )
        }

        if let batch = batch {
            let now = s.t
            analyzeQueue.async { [weak self] in
                guard let self = self else { return }
                for x in batch { self.scanner.addSample(x) }
                let emissions = self.scanner.scan(now)
                self.processLive(emissions)
            }
        }
    }

    /// Final synchronous flush. Drains any staged samples and runs one last
    /// detection pass. Pendings that already surfaced a provisional jump are
    /// refined/retracted in place via the callbacks; genuinely-new finals are
    /// returned so the caller can fold them into the session being saved.
    func endSession() -> [Jump] {
        os_unfair_lock_lock(&stagingLock)
        let batch = staging
        staging.removeAll(keepingCapacity: true)
        os_unfair_lock_unlock(&stagingLock)

        let now = lastSampleT

        // Collect emissions + the live-jump map on the scanner's queue, then act on
        // them BELOW on the caller's (main) thread — never fire app callbacks from
        // inside the analyzeQueue.sync block.
        var emissions: [ScanEmissionV9] = []
        var live: [Int: Jump] = [:]
        analyzeQueue.sync {
            for x in batch { scanner.addSample(x) }
            emissions = scanner.flush(now)
            live = liveJumps
            liveJumps.removeAll()
        }

        var newJumps: [Jump] = []
        for e in emissions where e.stage != .provisional {
            switch e.stage {
            case .final_:
                if var existing = live.removeValue(forKey: e.id) {
                    if accepts(e.jump) {
                        apply(e.jump, to: &existing)
                        onJumpUpdated?(existing)
                    } else {
                        onJumpRetracted?(existing.id)      // final baseline rejected it
                    }
                } else if accepts(e.jump) {
                    newJumps.append(makeJump(from: e.jump)) // never shown live → fold in as new
                }
            case .retracted:
                if let existing = live.removeValue(forKey: e.id) { onJumpRetracted?(existing.id) }
            case .provisional:
                break
            }
        }
        logEvent("JumpDetector(v9) endSession flush — \(newJumps.count) new final jump(s)")
        return newJumps
    }

    // MARK: - Emit (live path, runs on analyzeQueue)

    /// Turn scanner emissions into app-level jump events. Provisional jumps surface
    /// immediately; a later FINAL refines the same jump in place, or retracts it if
    /// the full baseline rejected it. A provisional that was gated out but whose
    /// FINAL clears the gate is surfaced as a new jump.
    private func processLive(_ emissions: [ScanEmissionV9]) {
        for e in emissions {
            switch e.stage {
            case .provisional:
                guard liveJumps[e.id] == nil, accepts(e.jump) else { continue }
                let jump = makeJump(from: e.jump)
                liveJumps[e.id] = jump
                playHaptic(for: jump)
                logEvent("JUMP(v9) PROVISIONAL h=\(jump.height)m air=\(jump.airtime)s "
                    + "conf=\(jump.confidence) latency=\(e.emitLatencySec)s")
                onJumpDetected?(jump)

            case .final_:
                if var existing = liveJumps.removeValue(forKey: e.id) {
                    if accepts(e.jump) {
                        apply(e.jump, to: &existing)
                        logEvent("JUMP(v9) FINAL(update) h=\(existing.height)m air=\(existing.airtime)s "
                            + "conf=\(existing.confidence) src=\(e.jump.heightSource.rawValue) latency=\(e.emitLatencySec)s")
                        onJumpUpdated?(existing)
                    } else {
                        logEvent("JUMP(v9) FINAL rejected provisional — retracting id=\(existing.id)")
                        onJumpRetracted?(existing.id)
                    }
                } else if accepts(e.jump) {
                    let jump = makeJump(from: e.jump)
                    playHaptic(for: jump)
                    logEvent("JUMP(v9) FINAL(new) h=\(jump.height)m air=\(jump.airtime)s "
                        + "conf=\(jump.confidence) src=\(e.jump.heightSource.rawValue) latency=\(e.emitLatencySec)s")
                    onJumpDetected?(jump)
                }

            case .retracted:
                if let existing = liveJumps.removeValue(forKey: e.id) {
                    logEvent("JUMP(v9) RETRACTED provisional id=\(existing.id)")
                    onJumpRetracted?(existing.id)
                }
            }
        }
    }

    /// Confidence gate mirroring the v8 adapter. The scanner's v8 engine already
    /// enforces height / airtime / run-up gates; this is the same 0…1 accept floor.
    private func accepts(_ r: JumpResultV8) -> Bool {
        guard r.takeoffTimeMs != nil else { return false }
        guard r.confidence >= acceptConfidence01 else { return false }
        guard r.airTimeSec >= params.minAirTimeSec else { return false }
        return true
    }

    private func makeJump(from r: JumpResultV8) -> Jump {
        let base = sessionWallStart ?? t0Wall ?? Date()
        var jump = Jump(sessionId: sessionId, startTime: base.addingTimeInterval((r.takeoffTimeMs ?? 0) / 1000))
        apply(r, to: &jump)
        return jump
    }

    /// Refine an existing jump's metrics from a (later) result, KEEPING its `id` so
    /// the app can replace it in place. Used for the provisional → final update.
    private func apply(_ r: JumpResultV8, to jump: inout Jump) {
        let base = sessionWallStart ?? t0Wall ?? Date()
        jump.startTime    = base.addingTimeInterval((r.takeoffTimeMs ?? 0) / 1000)
        jump.endTime      = base.addingTimeInterval((r.landingTimeMs ?? 0) / 1000)
        jump.height       = r.jumpHeightM
        jump.airtime      = r.airTimeSec
        jump.jumpDistance = r.jumpDistanceM ?? 0
        jump.rotations    = 0                     // v8/v9 does not estimate rotations
        jump.apexTime     = r.apexTimeSec
        jump.confidence   = r.confidence * 100.0  // app stores confidence as 0…100
        jump.imuSamples   = []
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
