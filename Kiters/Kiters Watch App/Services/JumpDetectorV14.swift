//
//  JumpDetectorV14.swift
//  Kiters Watch App
//
//  Adapter for the pure V14 hybrid engine (IMU + pressure detection with an
//  on-demand absolute-altitude cross-check). Conforms to JumpDetecting and
//  feeds JumpEngineV14 from the app's workout-owned sensor streams:
//
//  • IMU (200 Hz): vertical load is the gravity-projected user acceleration —
//    ~1 g at rest, ~0 g in freefall — computed here so the engine stays
//    platform-free. Gyro magnitude rides along for rotation metrics.
//  • Relative (pressure) altitude: extracted from the ZOH-held IMU rows and
//    de-duplicated by the barometer's own timestamp, so the engine sees the
//    channel at its true cadence.
//  • Absolute altitude: forwarded ONLY while the engine's jump window is
//    open. The engine's window request is surfaced to the session layer via
//    `onAbsoluteAltitudeWindowChange` so MotionManager can physically
//    start/stop `startAbsoluteAltitudeUpdates`. No accuracy gating — only the
//    documented Core Motion re-anchor sentinel (accuracy ≥ 100 m, garbage
//    altitude) is dropped.
//  • GPS: forwarded as optional metrics; V14 detection never depends on it.
//
//  An acquisition-layer restart (`absoluteAltitudeStreamDidRestart`) does NOT
//  reset the engine — V13 lost entire sessions to watchdog-driven resets. The
//  restart is logged and the absolute channel simply keeps feeding whenever
//  the window is open; the engine's health check (distinct values) decides
//  whether it is usable.
//

import Foundation
import CoreMotion
#if canImport(WatchKit)
import WatchKit
#endif

/// UserDefaults override keys — every V14 threshold is field-tunable.
/// Absent keys fall back to the V14Config defaults. The rise threshold reuses
/// the existing "v13MinRiseM" key so the user's 1/1.5/2 m picker selection
/// carries over unchanged.
enum V14Settings {
    static let minRiseM = "v13MinRiseM"        // shared 1.0 / 1.5 / 2.0 picker
    static let baselineWindowSec = "v14BaselineWindowSec"
    static let popG = "v14PopG"
    static let requirePop = "v14RequirePop"
    static let unweightG = "v14UnweightG"
    static let unweightSec = "v14UnweightSec"
    static let landingImpactG = "v14LandingImpactG"
    static let flightLoadCeilingG = "v14FlightLoadCeilingG"
    static let flightEndHoldSec = "v14FlightEndHoldSec"
    static let landingStableSec = "v14LandingStableSec"
    static let landingStableBandM = "v14LandingStableBandM"
    static let minAirtimeSec = "v14MinAirtimeSec"
    static let maxFlightSec = "v14MaxFlightSec"
    static let allowBallisticHeight = "v14AllowBallisticHeight"

    static let riseOptions = [1.0, 1.5, 2.0]

    static func normalizedRise(_ value: Double) -> Double {
        riseOptions.min(by: { abs($0 - value) < abs($1 - value) })
            ?? V14Config().minRiseM
    }
}

final class JumpDetectorV14: JumpDetecting {
    var sessionId: String = ""
    var synchronousAnalysis = false
    var onJumpDetected: ((Jump) -> Void)?
    var onStateChanged: ((JumpDetector.JumpState) -> Void)?
    /// Tooling hook (offline replay/forensics) — mirrors every onDebug event
    /// the engine emits, independent of SessionLogger's silence flag.
    var onDebugEvent: ((TimeInterval, String) -> Void)?

    /// Session-layer hook: `true` when the engine opens a jump window and the
    /// absolute altimeter should start, `false` when the landing baseline is
    /// confirmed and it should stop. Fired on the engine queue.
    var onAbsoluteAltitudeWindowChange: ((Bool, String) -> Void)?

    private var cfg = JumpDetectorV14.makeConfigFromSettings()
    private var engine: JumpEngineV14
    private let engineQueue = DispatchQueue(label: "com.kiters.jumpV14.engine", qos: .userInitiated)
    private let stateLock = NSLock()
    private let speedLock = NSLock()
    private let windowLock = NSLock()

    private var state: JumpDetector.JumpState = .idle
    private var latestSpeedMS: Double = 0
    private var sampleCount = 0
    private var lastMotionT: TimeInterval = 0
    private var lastBarometerT: TimeInterval?
    private var absoluteWindowOpen = false
    private var independentAltitudeBaseSensorT: TimeInterval?
    private var independentAltitudeBaseReceivedT: TimeInterval?
    private var hasDirectAbsoluteStream = false
    private var lastRowAbsoluteT: TimeInterval?
    private var deliverHeldAbsoluteOnOpen = false

    private static let absoluteSentinelAccuracyM = 100.0

    private let bootWallClock = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime

    init() {
        engine = JumpEngineV14(cfg)
        wireEngine()
    }

    /// Immutable snapshot for session diagnostics; read through the engine
    /// queue so it matches the configuration actually installed.
    var effectiveConfiguration: V14Config {
        engineQueue.sync { cfg }
    }

    /// True while the engine wants absolute-altitude samples. Thread-safe;
    /// used by the live adapter and by the offline replay to emulate the
    /// on-demand acquisition window.
    var isAbsoluteWindowOpen: Bool {
        windowLock.lock()
        defer { windowLock.unlock() }
        return absoluteWindowOpen
    }

    static func makeConfigFromSettings() -> V14Config {
        let defaults = UserDefaults.standard
        let base = V14Config()
        var cfg = base

        cfg.minRiseM = V14Settings.normalizedRise(
            doubleSetting(V14Settings.minRiseM, default: base.minRiseM, range: 0.3...5.0, defaults: defaults)
        )
        cfg.baselineWindowSec = doubleSetting(V14Settings.baselineWindowSec, default: base.baselineWindowSec, range: 3.0...5.0, defaults: defaults)
        cfg.popG = doubleSetting(V14Settings.popG, default: base.popG, range: 1.0...4.0, defaults: defaults)
        cfg.requirePop = boolSetting(V14Settings.requirePop, default: base.requirePop, defaults: defaults)
        cfg.unweightG = doubleSetting(V14Settings.unweightG, default: base.unweightG, range: 0.3...0.95, defaults: defaults)
        cfg.unweightSec = doubleSetting(V14Settings.unweightSec, default: base.unweightSec, range: 0.15...1.0, defaults: defaults)
        cfg.landingImpactG = doubleSetting(V14Settings.landingImpactG, default: base.landingImpactG, range: 1.2...5.0, defaults: defaults)
        cfg.flightLoadCeilingG = doubleSetting(V14Settings.flightLoadCeilingG, default: base.flightLoadCeilingG, range: 0.6...1.2, defaults: defaults)
        cfg.flightEndHoldSec = doubleSetting(V14Settings.flightEndHoldSec, default: base.flightEndHoldSec, range: 0.1...1.0, defaults: defaults)
        cfg.landingStableSec = doubleSetting(V14Settings.landingStableSec, default: base.landingStableSec, range: 1.0...4.0, defaults: defaults)
        cfg.landingStableBandM = doubleSetting(V14Settings.landingStableBandM, default: base.landingStableBandM, range: 0.2...2.0, defaults: defaults)
        cfg.minAirtimeSec = doubleSetting(V14Settings.minAirtimeSec, default: base.minAirtimeSec, range: 0.2...3.0, defaults: defaults)
        cfg.maxFlightSec = doubleSetting(V14Settings.maxFlightSec, default: base.maxFlightSec, range: 4.0...40.0, defaults: defaults)
        cfg.allowBallisticHeightFallback = boolSetting(V14Settings.allowBallisticHeight, default: base.allowBallisticHeightFallback, defaults: defaults)
        return cfg
    }

    private static func doubleSetting(_ key: String,
                                      default defaultValue: Double,
                                      range: ClosedRange<Double>,
                                      defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return min(max(defaults.double(forKey: key), range.lowerBound), range.upperBound)
    }

    private static func boolSetting(_ key: String,
                                    default defaultValue: Bool,
                                    defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    /// V14 detects from IMU + relative pressure; the absolute altimeter is a
    /// height cross-check. Only device motion is a hard requirement.
    static func readinessReport() -> JumpDetectorV13Readiness {
        var details: [String] = []
        var blockers: [String] = []

        #if os(watchOS)
        let motionAvailable = CMMotionManager().isDeviceMotionAvailable
        details.append("deviceMotion: \(motionAvailable ? "available" : "unavailable")")
        if !motionAvailable {
            blockers.append("device motion is unavailable")
        }

        let altimeterStatus = CMAltimeter.authorizationStatus()
        details.append("altimeter auth=\(altimeterStatus.rawValue)")
        if altimeterStatus == .denied || altimeterStatus == .restricted {
            blockers.append("altimeter permission is not available")
        }

        if #available(watchOS 8.0, *) {
            let absoluteAvailable = CMAltimeter.isAbsoluteAltitudeAvailable()
            details.append("absolute altitude: \(absoluteAvailable ? "available" : "unavailable (height cross-check disabled)")")
        }
        #else
        details.append("offline replay: watch sensor readiness skipped")
        #endif

        return JumpDetectorV13Readiness(
            isReady: blockers.isEmpty,
            userFacingReason: blockers.first ?? "V14 is ready",
            logDetails: (details + blockers.map { "blocker: \($0)" }).joined(separator: "; ")
        )
    }

    func reset(mode: DetectionMode) {
        engineQueue.sync {
            cfg = Self.makeConfigFromSettings()
            engine = JumpEngineV14(cfg)
            wireEngine()
            sampleCount = 0
            lastMotionT = 0
            lastBarometerT = nil
            independentAltitudeBaseSensorT = nil
            independentAltitudeBaseReceivedT = nil
            hasDirectAbsoluteStream = false
            lastRowAbsoluteT = nil
            deliverHeldAbsoluteOnOpen = false
        }
        setWindowOpen(false)

        setLatestSpeed(0)
        setState(.idle)
        setState(.riding)

        let readiness = Self.readinessReport()
        logEvent("JumpDetector(v14) reset - ready=\(readiness.isReady) "
            + "minRise=\(cfg.minRiseM)m baselineMedian=\(cfg.baselineWindowSec)s "
            + "unweight=\(cfg.unweightG)g/\(cfg.unweightSec)s pop=\(cfg.popG)g(require=\(cfg.requirePop)) "
            + "landingImpact=\(cfg.landingImpactG)g stable=\(cfg.landingStableSec)s±\(cfg.landingStableBandM)m "
            + "absolute=onDemandWindow gps=metricsOnly \(readiness.logDetails)")
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
        let motionT = sample.motionTimestamp ?? monotonicTime(from: sample.timestamp)
        let verticalLoad = Self.verticalLoadG(of: sample)
        let gyro = sample.rotationMagnitude
        let baroFrame = relativeAltitudeFrame(from: sample, fallbackT: motionT)

        submitToEngine { [weak self] in
            guard let self else { return }
            self.lastMotionT = motionT

            if let baroFrame {
                self.engine.addRelativeAltitude(t: baroFrame.t, altitudeM: baroFrame.altitudeM)
            }

            self.engine.addIMU(t: motionT, verticalLoadG: verticalLoad, gyroRadS: gyro)

            // Live sessions receive absolute altitude through the direct
            // callback. The ZOH snapshot held on IMU rows is the offline /
            // legacy fallback — forwarded only inside the jump window, with
            // the currently-held value delivered the moment it opens (the
            // live stream's immediate first callback behaves the same way).
            if !self.hasDirectAbsoluteStream, self.isAbsoluteWindowOpen,
               let absolute = sample.absoluteAltitude, absolute.isFinite {
                if let accuracy = sample.absoluteAltitudeAccuracy,
                   accuracy.isFinite, accuracy >= Self.absoluteSentinelAccuracyM {
                    return
                }
                let rowT = sample.absoluteAltitudeTimestamp ?? motionT
                let isNewSample = self.lastRowAbsoluteT.map { rowT > $0 } ?? true
                if isNewSample || self.deliverHeldAbsoluteOnOpen {
                    self.lastRowAbsoluteT = max(rowT, self.lastRowAbsoluteT ?? rowT)
                    self.deliverHeldAbsoluteOnOpen = false
                    self.engine.addAbsoluteAltitude(
                        t: isNewSample ? self.alignedToMotionClock(rowT, fallback: motionT) : motionT,
                        altitudeM: absolute
                    )
                }
            }
        }

        let snapshotState = currentState()
        if snapshotState != .idle || sampleCount % 5 == 0 {
            SessionLogger.shared.logSample(
                sample: sample,
                speed: latestSpeed(),
                baselinePressure: 0,
                lowGCount: 0,
                state: snapshotState.rawValue
            )
        }
    }

    func processAbsoluteAltitude(sensorT: TimeInterval,
                                 receivedT: TimeInterval,
                                 altitudeM: Double,
                                 accuracyM: Double?,
                                 precisionM: Double?) {
        guard altitudeM.isFinite else { return }
        guard isAbsoluteWindowOpen else { return }
        // Core Motion re-anchor sentinel: accuracy ≈ 500 with garbage altitude.
        if let accuracyM, accuracyM.isFinite, accuracyM >= Self.absoluteSentinelAccuracyM {
            return
        }
        _ = precisionM

        submitToEngine { [weak self] in
            guard let self else { return }
            self.hasDirectAbsoluteStream = true
            let t = self.alignedAbsoluteTimestamp(sensorT: sensorT, receivedT: receivedT)
            self.engine.addAbsoluteAltitude(t: t, altitudeM: altitudeM)
        }
    }

    func absoluteAltitudeStreamDidRestart(reason: String) {
        // Deliberately NOT an engine reset: V13 lost whole rides to
        // watchdog-driven resets. The engine's distinct-value health check
        // decides whether the restarted channel is usable.
        logEvent("v14 absoluteStreamRestart reason=\(reason) (engine unaffected)")
    }

    func endSession() -> [Jump] {
        var late: [Jump] = []
        engineQueue.sync {
            late = engine.flush(now: lastMotionT).map { makeJump(from: $0) }
        }
        setWindowOpen(false)
        logEvent("JumpDetector(v14) endSession flush lateJumps=\(late.count)")
        return late
    }

    // MARK: - Engine wiring

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
        engine.onAbsoluteWindowRequest = { [weak self] open, reason in
            guard let self else { return }
            self.setWindowOpen(open)
            if open { self.deliverHeldAbsoluteOnOpen = true }
            self.logEvent("v14 absoluteWindow \(open ? "OPEN" : "CLOSE") reason=\(reason)")
            self.onAbsoluteAltitudeWindowChange?(open, reason)
        }
    }

    private func handleDebug(t: TimeInterval, _ event: String) {
        if event.hasPrefix("CANDIDATE") {
            setState(.airborne)
        } else if event.hasPrefix("JUMP") || event.hasPrefix("REJECT") {
            setState(.riding)
        }
        logEvent("v14 \(event)")
        onDebugEvent?(t, event)
    }

    private func setWindowOpen(_ open: Bool) {
        windowLock.lock()
        absoluteWindowOpen = open
        windowLock.unlock()
    }

    // MARK: - Sensor extraction

    /// Gravity-projected vertical load in g: userAcceleration·ĝ + |g|.
    /// ~1 at rest, ~0 in freefall, >1 under pop/impact compression. Samples
    /// without a gravity vector (older logs) assume wrist-flat (0, 0, −1).
    static func verticalLoadG(of sample: IMUSample) -> Double {
        let gx = sample.gravity?.x ?? 0
        let gy = sample.gravity?.y ?? 0
        let gz = sample.gravity?.z ?? -1
        let gMag = (gx * gx + gy * gy + gz * gz).squareRoot()
        guard gMag > 0.01 else { return sample.accelerationMagnitude }
        let projected = (sample.accelerationX * gx + sample.accelerationY * gy + sample.accelerationZ * gz) / gMag
        return projected + gMag
    }

    /// The barometer value is ZOH-held onto every 200 Hz IMU row; forward it
    /// only when the barometer's own timestamp advances so the engine sees the
    /// channel at its true cadence. De-dup runs on the raw sensor timestamp;
    /// the engine receives a motion-clock time (older logs stamp the barometer
    /// on a different clock, and every engine comparison is motion-clock).
    private func relativeAltitudeFrame(from sample: IMUSample,
                                       fallbackT: TimeInterval) -> (t: TimeInterval, altitudeM: Double)? {
        guard let relative = sample.relativeAltitude else { return nil }
        let baroT = sample.barometerTimestamp ?? fallbackT
        if let last = lastBarometerT, baroT <= last { return nil }
        lastBarometerT = baroT
        return (alignedToMotionClock(baroT, fallback: fallbackT), relative)
    }

    /// Sensor timestamps within 60 s of the motion clock are trusted as-is;
    /// anything further (epoch-scale stamps in older logs) falls back to the
    /// motion time so all engine timelines share one clock.
    private func alignedToMotionClock(_ sensorT: TimeInterval, fallback: TimeInterval) -> TimeInterval {
        guard sensorT.isFinite, fallback.isFinite else { return fallback }
        return abs(sensorT - fallback) <= 60 ? sensorT : fallback
    }

    private func alignedAbsoluteTimestamp(sensorT: TimeInterval,
                                          receivedT: TimeInterval) -> TimeInterval {
        let fallback = receivedT.isFinite ? receivedT : ProcessInfo.processInfo.systemUptime
        guard sensorT.isFinite else { return fallback }
        if abs(sensorT - fallback) <= 60 {
            return sensorT
        }
        if independentAltitudeBaseSensorT == nil || independentAltitudeBaseReceivedT == nil {
            independentAltitudeBaseSensorT = sensorT
            independentAltitudeBaseReceivedT = fallback
        }
        guard let baseSensor = independentAltitudeBaseSensorT,
              let baseReceived = independentAltitudeBaseReceivedT else {
            return fallback
        }
        return baseReceived + (sensorT - baseSensor)
    }

    // MARK: - State / speed

    private func setState(_ newState: JumpDetector.JumpState) {
        stateLock.lock()
        guard newState != state else {
            stateLock.unlock()
            return
        }
        state = newState
        stateLock.unlock()
        onStateChanged?(newState)
    }

    private func currentState() -> JumpDetector.JumpState {
        stateLock.lock()
        defer { stateLock.unlock() }
        return state
    }

    private func setLatestSpeed(_ speed: Double) {
        speedLock.lock()
        latestSpeedMS = speed
        speedLock.unlock()
    }

    private func latestSpeed() -> Double {
        speedLock.lock()
        defer { speedLock.unlock() }
        return latestSpeedMS
    }

    private func monotonicTime(from date: Date) -> TimeInterval {
        date.timeIntervalSince1970 - bootWallClock
    }

    private func wallDate(from monotonicTime: TimeInterval) -> Date {
        Date(timeIntervalSince1970: bootWallClock + monotonicTime)
    }

    // MARK: - Result mapping

    private func makeJump(from result: V14Jump) -> Jump {
        var jump = Jump(sessionId: sessionId, startTime: wallDate(from: result.takeoffT))
        jump.endTime = wallDate(from: result.landingT)
        jump.height = result.heightM
        jump.airtime = result.airtimeSec
        jump.jumpDistance = result.distanceM ?? 0
        jump.rotations = Int(result.rotationTurns.rounded())
        jump.apexTime = result.apexT - result.takeoffT
        jump.confidence = result.confidence * 100.0
        jump.imuSamples = []
        jump.heightSource = result.heightSource.rawValue
        jump.absoluteTakeoffAltitude = result.baselineRelM
        jump.absoluteApexAltitude = result.peakAbsoluteM
        jump.absoluteLandingAltitude = result.landingAbsoluteM
        jump.takeoffSpeed = result.takeoffSpeedMS
        jump.landingSpeed = result.landingSpeedMS
        jump.detectionConfidence = result.detectionConfidence * 100.0
        jump.heightConfidence = result.heightConfidence * 100.0
        jump.baselineQuality = result.baselineQuality
        jump.heightFailureReason = result.heightFailureReason?.rawValue
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

extension JumpDetectorV14: JumpEngineV14Delegate {
    func jumpDetected(_ result: V14Jump) {
        let jump = makeJump(from: result)
        playHaptic(for: jump)
        SessionLogger.shared.logEvent(
            t: result.landingT,
            event: "JUMP(v14) FINAL h=\(jump.height)m src=\(result.heightSource.rawValue) "
                + "air=\(jump.airtime)s dist=\(jump.jumpDistance)m "
                + "hRel=\(result.heightRelativeM ?? -1) hAbs=\(result.heightAbsoluteM ?? -1) "
                + "pop=\(result.popImpulseG)g impact=\(result.landingImpactG)g rot=\(result.rotationTurns) "
                + "confirmed=\(result.landingConfirmed) conf=\(jump.confidence) "
                + "v14_detection_confidence=\(result.detectionConfidence) v14_height_confidence=\(result.heightConfidence) "
                + "v14_baseline_quality=\(result.baselineQuality ?? -1) v14_apex_confidence=\(result.apexConfidence ?? -1) "
                + "v14_altitude_coverage=\(result.altitudeCoverage ?? -1) "
                + "v14_height_failure_reason=\(result.heightFailureReason?.rawValue ?? "none") "
                + "latency=\(String(format: "%.1f", result.emittedAtT - result.landingT))s",
            state: "JUMP",
            speed: result.takeoffSpeedMS ?? latestSpeed()
        )
        onJumpDetected?(jump)
    }
}
