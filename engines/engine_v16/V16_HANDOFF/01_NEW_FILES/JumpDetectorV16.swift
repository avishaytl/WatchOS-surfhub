//
//  JumpDetectorV16.swift
//  Kiters Watch App
//
//  Adapter for the V16 big-air engine. Conforms to JumpDetecting and feeds
//  JumpEngineV16 from the workout-owned sensor streams.
//
//  WHAT V16 CONSUMES — and what it deliberately does not:
//   • IMU: |userAcceleration| in g for the pop trigger PLUS the raw 3-axis
//     userAcceleration and the attitude quaternion for the vertical channel.
//   • GPS: metrics only (takeoff speed, jump distance). No detection gate
//     reads it — the lift-plateau test alone separates real jumps from chop.
//   • Barometer: NOT consumed at all. Measured on the goldens: absoluteAltitude
//     passes a health gate on only 7/21 jumps and still produced −6.4 m errors
//     when it passed; relativeAltitude noise exceeds the jump signal in the
//     same band. Feeding either would inject metre-scale error into a 0.5 m
//     estimator. `processAbsoluteAltitude` is intentionally left as the
//     protocol's no-op.
//
//  ⚠️ DOMAIN — the single easiest thing to get wrong here.
//  V16's `popMinG` is calibrated in the MAGNITUDE domain: |userAcceleration|,
//  which reads ~0 g at rest. That is `IMUSample.accelerationMagnitude`.
//  It is NOT `JumpDetectorV15.verticalLoadG`, which is the gravity-projected
//  load and reads ~1 g at rest. Feeding the load here would shift every pop by
//  a full g and make the 1.4 g floor meaningless.
//

import Foundation
import CoreMotion
#if canImport(WatchKit)
import WatchKit
#endif

/// UserDefaults override keys for the field-tunable V16 thresholds. Absent keys
/// fall back to the V16Config defaults.
enum V16Settings {
    static let minReportM = "v16MinReportM"
    static let popMinG = "v16PopMinG"
    static let minLiftPlateauSec = "v16MinLiftPlateauSec"
    static let heightScale = "v16HeightScale"
    static let heightOffsetM = "v16HeightOffsetM"
}

final class JumpDetectorV16: JumpDetecting {
    var sessionId: String = ""
    var synchronousAnalysis = false
    var onJumpDetected: ((Jump) -> Void)?
    var onStateChanged: ((JumpDetector.JumpState) -> Void)?
    /// Tooling hook (offline replay/forensics) — mirrors every engine debug event.
    var onDebugEvent: ((TimeInterval, String) -> Void)?

    private var cfg = JumpDetectorV16.makeConfigFromSettings()
    private var engine: JumpEngineV16
    private let engineQueue = DispatchQueue(label: "com.spoteq.jumpV16.engine", qos: .userInitiated)
    private let stateLock = NSLock()
    private let speedLock = NSLock()

    private var state: JumpDetector.JumpState = .idle
    private var latestSpeedMS: Double = 0
    private var sampleCount = 0
    private var lastMotionT: TimeInterval = 0

    /// Wall↔monotonic conversion. Captured ONCE per detector instance and used
    /// for both directions so a jump's wall-clock start/end is the exact inverse
    /// of the engine time that produced it. See the review doc: this quantity
    /// drifts (systemUptime excludes sleep, wall clock is NTP-corrected), so it
    /// must never be re-sampled mid-session.
    private let bootWallClock = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime

    init() {
        engine = JumpEngineV16(cfg)
        wireEngine()
    }

    /// Immutable snapshot for session diagnostics, read through the engine queue
    /// so it matches the configuration actually installed.
    var effectiveConfiguration: V16Config {
        engineQueue.sync { cfg }
    }

    static func makeConfigFromSettings() -> V16Config {
        let defaults = UserDefaults.standard
        let base = V16Config()
        var cfg = base
        cfg.minReportM = doubleSetting(V16Settings.minReportM, default: base.minReportM,
                                       range: 0.5...10.0, defaults: defaults)
        cfg.popMinG = doubleSetting(V16Settings.popMinG, default: base.popMinG,
                                    range: 0.8...4.0, defaults: defaults)
        cfg.minLiftPlateauSec = doubleSetting(V16Settings.minLiftPlateauSec, default: base.minLiftPlateauSec,
                                              range: 0.4...2.0, defaults: defaults)
        // The height calibration is tied to the apex window; exposed for field
        // work but out-of-range values are clamped rather than trusted.
        cfg.heightScale = doubleSetting(V16Settings.heightScale, default: base.heightScale,
                                        range: 1.0...3.0, defaults: defaults)
        cfg.heightOffsetM = doubleSetting(V16Settings.heightOffsetM, default: base.heightOffsetM,
                                          range: 0.0...3.0, defaults: defaults)
        return cfg
    }

    private static func doubleSetting(_ key: String,
                                      default defaultValue: Double,
                                      range: ClosedRange<Double>,
                                      defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return min(max(defaults.double(forKey: key), range.lowerBound), range.upperBound)
    }

    /// V16 needs device motion WITH attitude. Nothing else is a hard requirement
    /// — there is no barometric path to degrade to.
    static func readinessReport() -> JumpDetectorV13Readiness {
        var details: [String] = []
        var blockers: [String] = []

        #if os(watchOS)
        let motionAvailable = CMMotionManager().isDeviceMotionAvailable
        details.append("deviceMotion: \(motionAvailable ? "available" : "unavailable")")
        if !motionAvailable {
            blockers.append("device motion is unavailable")
        }
        details.append("barometer: not used by V16 (IMU-only height)")
        #else
        details.append("offline replay: watch sensor readiness skipped")
        #endif

        return JumpDetectorV13Readiness(
            isReady: blockers.isEmpty,
            userFacingReason: blockers.first ?? "V16 is ready",
            logDetails: (details + blockers.map { "blocker: \($0)" }).joined(separator: "; ")
        )
    }

    func reset(mode: DetectionMode) {
        engineQueue.sync {
            cfg = Self.makeConfigFromSettings()
            engine = JumpEngineV16(cfg)
            wireEngine()
            sampleCount = 0
            lastMotionT = 0
        }
        setLatestSpeed(0)
        setState(.idle)
        setState(.riding)

        let readiness = Self.readinessReport()
        logEvent("JumpDetector(v16) reset - ready=\(readiness.isReady) "
            + "pop>=\(cfg.popMinG)g shelf>=\(cfg.minLiftPlateauSec)s "
            + "apexWindow=[-\(cfg.apexPreSec),+\(cfg.apexPostSec)]s "
            + "h=\(cfg.heightScale)*apex+\(cfg.heightOffsetM) minReport=\(cfg.minReportM)m "
            + "barometer=unused gps=metricsOnly \(readiness.logDetails)")
    }

    func updateGPS(speed: Double,
                   altitude: Double,
                   latitude: Double,
                   longitude: Double,
                   course: Double = -1,
                   horizontalAccuracy: Double? = nil,
                   timestamp: Date) {
        let speedMS = max(0, speed)
        setLatestSpeed(speedMS)
        let t = monotonicTime(from: timestamp)

        submitToEngine { [weak self] in
            self?.engine.addGPS(t: t, lat: latitude, lng: longitude, speedMS: speedMS)
        }

        if currentState() == .idle {
            setState(.riding)
        }
    }

    func processSample(_ sample: IMUSample) {
        sampleCount += 1
        // The engine clock is the raw CoreMotion timestamp — the same clock the
        // engine's own ring, dedup and hold windows are expressed in. The wall
        // conversion happens only when a Jump is built.
        let motionT = sample.motionTimestamp ?? monotonicTime(from: sample.timestamp)

        // DOMAIN: magnitude, not vertical load. See the file header.
        let loadG = sample.accelerationMagnitude
        let gyro = sample.rotationMagnitude
        let accel = (x: sample.accelerationX, y: sample.accelerationY, z: sample.accelerationZ)
        let quat: (w: Double, x: Double, y: Double, z: Double)? = sample.attitudeQuaternion.map {
            (w: $0.w, x: $0.x, y: $0.y, z: $0.z)
        }

        submitToEngine { [weak self] in
            guard let self else { return }
            self.lastMotionT = motionT
            self.engine.addIMU(t: motionT,
                               loadG: loadG,
                               gyroRadS: gyro,
                               accel: quat == nil ? nil : accel,
                               quat: quat)
        }

        // NOTE: the other adapters call SessionLogger.logSample(...) here without
        // an `event:`. That call is a guaranteed no-op — logSample's first line is
        // `guard !event.isEmpty else { return }` — so it costs a state lock and a
        // call on every 200 Hz sample and writes nothing. MOTION rows reach the
        // log through SessionLogger.logMotionSamples on the MotionManager batch
        // path instead. V16 deliberately omits it.
    }

    // processAbsoluteAltitude / absoluteAltitudeStreamDidRestart intentionally
    // use the protocol's no-op defaults: V16 does not consume the barometer.

    func endSession() -> [Jump] {
        // Jumps are delivered through the delegate as they are released, so the
        // flush only has to drain candidates still inside their evaluation and
        // dedup hold windows.
        engineQueue.sync {
            engine.flush(now: lastMotionT)
        }
        setState(.idle)
        return []
    }

    // MARK: - Plumbing

    private func submitToEngine(_ work: @escaping () -> Void) {
        if synchronousAnalysis {
            engineQueue.sync { work() }
        } else {
            engineQueue.async { work() }
        }
    }

    private func wireEngine() {
        engine.delegate = self
        engine.onDebug = { [weak self] t, event in
            self?.handleDebug(t: t, event)
        }
    }

    private func handleDebug(t: TimeInterval, _ event: String) {
        onDebugEvent?(t, event)
        SessionLogger.shared.logEvent("v16 \(event)")
    }

    private func setState(_ newState: JumpDetector.JumpState) {
        stateLock.lock()
        let changed = state != newState
        state = newState
        stateLock.unlock()
        if changed { onStateChanged?(newState) }
    }

    private func currentState() -> JumpDetector.JumpState {
        stateLock.lock(); defer { stateLock.unlock() }
        return state
    }

    private func setLatestSpeed(_ v: Double) {
        speedLock.lock(); latestSpeedMS = v; speedLock.unlock()
    }

    private func latestSpeed() -> Double {
        speedLock.lock(); defer { speedLock.unlock() }
        return latestSpeedMS
    }

    private func monotonicTime(from date: Date) -> TimeInterval {
        date.timeIntervalSince1970 - bootWallClock
    }

    private func wallDate(from monotonicTime: TimeInterval) -> Date {
        Date(timeIntervalSince1970: bootWallClock + monotonicTime)
    }

    private func makeJump(from result: V16Jump) -> Jump {
        var jump = Jump(sessionId: sessionId, startTime: wallDate(from: result.takeoffT))
        // airtimeSec is LOW CONFIDENCE (see JumpEngineV16 header). When the
        // landing was never resolved the jump has no meaningful end time, so it
        // is stamped at the takeoff rather than invented.
        let air = result.airtimeSec ?? 0
        jump.endTime = wallDate(from: result.takeoffT + air)
        jump.height = result.heightM
        jump.airtime = air
        jump.jumpDistance = result.distanceM ?? 0
        jump.rotations = 0
        jump.apexTime = air > 0 ? air / 2 : 0
        jump.confidence = result.confidence * 100.0
        jump.imuSamples = []
        jump.heightSource = "v16Apex"
        jump.takeoffSpeed = result.takeoffSpeedMS
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

    private func logEvent(_ msg: @autoclosure () -> String) {
        let message = msg()
        #if DEBUG
        print("🦘 \(message)")
        #endif
        SessionLogger.shared.logEvent(message)
    }
}

extension JumpDetectorV16: JumpEngineV16Delegate {
    func jumpDetected(_ result: V16Jump) {
        let jump = makeJump(from: result)
        logEvent(String(
            format: "v16 JUMP h=%.2fm shelf=%.1fs air=%@ pop=%.1fg conf=%.2f",
            result.heightM, result.liftPlateauSec,
            result.airtimeSec.map { String(format: "%.2fs", $0) } ?? "n/a",
            result.yankG, result.confidence
        ))
        playHaptic(for: jump)
        onJumpDetected?(jump)
    }
}
