//
//  JumpDetectorV13.swift
//  Kiters Watch App
//
//  Adapter for the pure V13 altitude-first engine. Conforms to the
//  JumpDetecting surface and feeds JumpEngineV13 from the app's workout-owned
//  altitude/GPS/IMU/submersion streams. V13 opens jumps from altitude rise,
//  keeps IMU as metrics only, and emits one FINAL jump after a stable landing
//  window.
//

import Foundation
import CoreMotion
#if canImport(WatchKit)
import WatchKit
#endif

struct JumpDetectorV13Readiness {
    let isReady: Bool
    let userFacingReason: String
    let logDetails: String
}

/// UserDefaults override keys — every engine threshold is field-tunable (§spec).
/// Absent keys fall back to the V13Config defaults.
enum V13Settings {
    static let minRiseM = "v13MinRiseM"                    // 1.0 / 1.5 / 2.0 picker
    static let minGpsSpeedMS = "v13MinGpsSpeedMS"
    static let minGpsDistanceM = "v13MinGpsDistanceM"
    static let triggerAccelG = "v13TriggerAccelG"
    static let triggerGyroRadS = "v13TriggerGyroRadS"
    static let armOnAltitudeRiseM = "v13ArmOnAltitudeRiseM"
    static let landingReturnBandM = "v13LandingReturnBandM"
    static let landingStableSec = "v13LandingStableSec"
    static let landingStableRangeM = "v13LandingStableRangeM"
    static let landingImpactG = "v13LandingImpactG"
    static let minAirtimeSec = "v13MinAirtimeSec"
    static let maxAirtimeSec = "v13MaxAirtimeSec"
    static let maxFlightSec = "v13MaxFlightSec"
    static let maxResultDelaySec = "v13MaxResultDelaySec"
    static let baselineWindowSec = "v13BaselineWindowSec"
    static let postBaselineWindowSec = "v13PostBaselineWindowSec"
    static let maxBaselineDriftM = "v13MaxBaselineDriftM"
    static let spikeToleranceM = "v13SpikeToleranceM"
    static let peakNeighborhoodSec = "v13PeakNeighborhoodSec"
    static let minArcSamples = "v13MinArcSamples"
    static let maxJumpHeightM = "v13MaxJumpHeightM"
}

final class JumpDetectorV13: JumpDetecting {
    var sessionId: String = ""
    var synchronousAnalysis = false
    var onJumpDetected: ((Jump) -> Void)?
    var onStateChanged: ((JumpDetector.JumpState) -> Void)?

    private var cfg = JumpDetectorV13.makeConfigFromSettings()
    private var engine: JumpEngineV13
    private let engineQueue = DispatchQueue(label: "com.kiters.jumpV13.engine", qos: .userInitiated)
    private let stateLock = NSLock()
    private let speedLock = NSLock()

    private enum AltitudeSource: String {
        case absoluteAltitude
        case relativeAltitude
        case pressure
    }

    private var state: JumpDetector.JumpState = .idle
    private var latestSpeedMS: Double = 0
    private var sampleCount = 0
    private var lastMotionT: TimeInterval = 0
    private var lastAltitudeT: TimeInterval?
    private var lastAltitudeValue: Double?
    private var lastSubmerged: Bool?
    private var activeAltitudeSource: AltitudeSource?
    private var independentAltitudeBaseSensorT: TimeInterval?
    private var independentAltitudeBaseReceivedT: TimeInterval?
    private var lastAbsoluteAltitudeM: Double?
    private var absoluteSentinelActive = false
    private var absoluteAccuracyGateActive = false
    private var hasDirectAbsoluteStream = false

    private let bootWallClock = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime

    init() {
        engine = JumpEngineV13(cfg)
        wireEngine()
    }

    static func makeConfigFromSettings() -> V13Config {
        let defaults = UserDefaults.standard
        let base = V13Config()
        var cfg = base

        cfg.minRiseM = doubleSetting(V13Settings.minRiseM, default: base.minRiseM, range: 0.3...5.0, defaults: defaults)
        cfg.minGpsSpeedMS = doubleSetting(V13Settings.minGpsSpeedMS, default: base.minGpsSpeedMS, range: base.minGpsSpeedMS...20.0, defaults: defaults)
        cfg.minGpsDistanceM = doubleSetting(V13Settings.minGpsDistanceM, default: base.minGpsDistanceM, range: 0.0...200.0, defaults: defaults)
        cfg.triggerAccelG = doubleSetting(V13Settings.triggerAccelG, default: base.triggerAccelG, range: 0.5...6.0, defaults: defaults)
        cfg.triggerGyroRadS = doubleSetting(V13Settings.triggerGyroRadS, default: base.triggerGyroRadS, range: 1.0...12.0, defaults: defaults)
        cfg.armOnAltitudeRiseM = doubleSetting(V13Settings.armOnAltitudeRiseM, default: base.armOnAltitudeRiseM, range: 0.3...3.0, defaults: defaults)
        cfg.landingReturnBandM = doubleSetting(V13Settings.landingReturnBandM, default: base.landingReturnBandM, range: 0.2...3.0, defaults: defaults)
        cfg.landingStableSec = doubleSetting(V13Settings.landingStableSec, default: base.landingStableSec, range: 0.3...4.0, defaults: defaults)
        cfg.landingStableRangeM = doubleSetting(V13Settings.landingStableRangeM, default: base.landingStableRangeM, range: 0.2...2.0, defaults: defaults)
        cfg.landingImpactG = doubleSetting(V13Settings.landingImpactG, default: base.landingImpactG, range: 0.5...6.0, defaults: defaults)
        cfg.minAirtimeSec = doubleSetting(V13Settings.minAirtimeSec, default: base.minAirtimeSec, range: 0.0...3.0, defaults: defaults)
        cfg.maxAirtimeSec = doubleSetting(V13Settings.maxAirtimeSec, default: base.maxAirtimeSec, range: 2.0...30.0, defaults: defaults)
        cfg.maxFlightSec = doubleSetting(V13Settings.maxFlightSec, default: base.maxFlightSec, range: 4.0...40.0, defaults: defaults)
        cfg.maxResultDelaySec = doubleSetting(V13Settings.maxResultDelaySec, default: base.maxResultDelaySec, range: 1.0...15.0, defaults: defaults)
        cfg.baselineWindowSec = doubleSetting(V13Settings.baselineWindowSec, default: base.baselineWindowSec, range: 2.0...20.0, defaults: defaults)
        cfg.postBaselineWindowSec = doubleSetting(V13Settings.postBaselineWindowSec, default: base.postBaselineWindowSec, range: 1.0...10.0, defaults: defaults)
        cfg.maxBaselineDriftM = doubleSetting(V13Settings.maxBaselineDriftM, default: base.maxBaselineDriftM, range: 0.5...8.0, defaults: defaults)
        cfg.spikeToleranceM = doubleSetting(V13Settings.spikeToleranceM, default: base.spikeToleranceM, range: 0.2...3.0, defaults: defaults)
        cfg.peakNeighborhoodSec = doubleSetting(V13Settings.peakNeighborhoodSec, default: base.peakNeighborhoodSec, range: 0.3...2.0, defaults: defaults)
        cfg.minArcSamples = Int(doubleSetting(V13Settings.minArcSamples, default: Double(base.minArcSamples), range: 1...6, defaults: defaults).rounded())
        cfg.maxJumpHeightM = doubleSetting(V13Settings.maxJumpHeightM, default: base.maxJumpHeightM, range: 3.0...40.0, defaults: defaults)
        if cfg.maxAirtimeSec < cfg.minAirtimeSec {
            cfg.maxAirtimeSec = cfg.minAirtimeSec
        }
        return cfg
    }

    private static func doubleSetting(_ key: String,
                                      default defaultValue: Double,
                                      range: ClosedRange<Double>,
                                      defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        let value = defaults.double(forKey: key)
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// V13's height source is CMAltimeter absolute altitude (~3 Hz), so the
    /// readiness gate mirrors V12's.
    static func readinessReport() -> JumpDetectorV13Readiness {
        var details: [String] = []
        var blockers: [String] = []

        #if os(watchOS)
        let fallbackMotionAvailable = CMMotionManager().isDeviceMotionAvailable
        details.append("deviceMotion: \(fallbackMotionAvailable ? "available" : "unavailable")")
        if !fallbackMotionAvailable {
            blockers.append("device motion is unavailable")
        }

        let altimeterStatus = CMAltimeter.authorizationStatus()
        details.append("altimeter auth=\(altimeterStatus.rawValue)")
        if altimeterStatus == .denied || altimeterStatus == .restricted {
            blockers.append("altimeter permission is not available")
        }

        if #available(watchOS 8.0, *) {
            let absoluteAvailable = CMAltimeter.isAbsoluteAltitudeAvailable()
            details.append("absolute altitude: \(absoluteAvailable ? "available" : "unavailable")")
            if !absoluteAvailable {
                blockers.append("CMAltimeter absolute altitude is unavailable")
            }
        } else {
            blockers.append("watchOS 8+ is required for CMAltimeter absolute altitude")
        }
        #else
        details.append("offline replay: watch sensor readiness skipped")
        #endif

        return JumpDetectorV13Readiness(
            isReady: blockers.isEmpty,
            userFacingReason: blockers.first ?? "V13 is ready",
            logDetails: (details + blockers.map { "blocker: \($0)" }).joined(separator: "; ")
        )
    }

    func reset(mode: DetectionMode) {
        engineQueue.sync {
            cfg = Self.makeConfigFromSettings()
            engine = JumpEngineV13(cfg)
            wireEngine()
            engine.reset()
            sampleCount = 0
            lastMotionT = 0
            lastAltitudeT = nil
            lastAltitudeValue = nil
            lastSubmerged = nil
            activeAltitudeSource = nil
            independentAltitudeBaseSensorT = nil
            independentAltitudeBaseReceivedT = nil
            lastAbsoluteAltitudeM = nil
            absoluteSentinelActive = false
            absoluteAccuracyGateActive = false
            hasDirectAbsoluteStream = false
        }

        setLatestSpeed(0)
        setState(.idle)
        setState(.riding)

        let readiness = Self.readinessReport()
        logEvent("JumpDetector(v13) reset - ready=\(readiness.isReady) "
            + "minRise=\(cfg.minRiseM)m baroBaselineAvg=\(cfg.baselineWindowSec)s "
            + "warmup=\(cfg.startupWarmupSec)s gps=metricsOnly imu=metricsOnly "
            + "landing=\(cfg.landingStableSec)s±\(cfg.landingStableRangeM)m band=\(cfg.landingReturnBandM)m "
            + "maxDelay=\(cfg.maxResultDelaySec)s \(readiness.logDetails)")
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
        let accel = sample.accelerationMagnitude
        let gyro = sample.rotationMagnitude
        let submerged = sample.submerged

        submitToEngine { [weak self] in
            guard let self = self else { return }
            self.lastMotionT = motionT

            if let submerged, submerged != self.lastSubmerged {
                self.lastSubmerged = submerged
                self.engine.addSubmersion(t: motionT, submerged: submerged)
            }

            // Live sessions receive CMAbsoluteAltitudeData through the direct
            // callback below. The IMU-carried snapshot is only an offline/legacy
            // fallback; processing both paths duplicates work and ties altitude
            // liveness back to the motion loop.
            if !self.hasDirectAbsoluteStream,
               let altitudeFrame = self.altitudeFrame(from: sample, fallbackT: motionT),
               self.shouldIngestAltitude(t: altitudeFrame.t, value: altitudeFrame.altitudeM) {
                self.noteAltitudeSource(altitudeFrame.source)
                self.engine.addAltitude(t: altitudeFrame.t, altitudeM: altitudeFrame.altitudeM)
            }

            self.engine.addIMU(t: motionT, accelG: accel, gyroRadS: gyro)
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

        submitToEngine { [weak self] in
            guard let self = self else { return }
            self.hasDirectAbsoluteStream = true
            guard self.gateAbsoluteAltitude(altitudeM: altitudeM, accuracyM: accuracyM) else { return }
            let t = self.alignedIndependentAltitudeTimestamp(sensorT: sensorT, receivedT: receivedT)
            guard self.shouldIngestAltitude(t: t, value: altitudeM) else { return }
            self.noteAltitudeSource(.absoluteAltitude)
            self.engine.addAltitude(t: t, altitudeM: altitudeM)
            _ = precisionM
        }

        if currentState() == .idle {
            setState(.riding)
        }
    }

    func absoluteAltitudeStreamDidRestart(reason: String) {
        submitToEngine { [weak self] in
            guard let self else { return }
            // Keep the direct-path latch set while Core Motion re-anchors so a
            // stale ZOH value on the IMU stream cannot repopulate the engine.
            self.hasDirectAbsoluteStream = true
            self.lastAbsoluteAltitudeM = nil
            self.absoluteSentinelActive = false
            self.absoluteAccuracyGateActive = false
            self.resetAltitudeStream(reason: "acquisitionRestart \(reason)")
        }
    }

    func endSession() -> [Jump] {
        var late: [Jump] = []
        engineQueue.sync {
            late = engine.flush(now: lastMotionT).map { makeJump(from: $0) }
        }
        logEvent("JumpDetector(v13) endSession flush lateJumps=\(late.count)")
        return late
    }

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
        if event.hasPrefix("CANDIDATE") {
            setState(.airborne)
        } else if event.hasPrefix("JUMP") || event.hasPrefix("REJECT") || event.hasPrefix("CLOSE") {
            setState(.riding)
        }
        logEvent("v13 \(event)")
    }

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

    /// Height source per the spec is absolute altitude (~3 Hz). V13 does not
    /// fall back to relative altitude or pressure: those streams are useful for
    /// diagnostics, but jump detection must stay on the absolute barometer.
    ///
    /// Must run on `engineQueue` — consults the calibration gate.
    private func altitudeFrame(from sample: IMUSample,
                               fallbackT: TimeInterval) -> (t: TimeInterval, altitudeM: Double, source: AltitudeSource)? {
        if let absoluteAltitude = sample.absoluteAltitude,
           gateAbsoluteAltitude(altitudeM: absoluteAltitude, accuracyM: sample.absoluteAltitudeAccuracy) {
            return (alignedAltitudeTimestamp(sample.absoluteAltitudeTimestamp, fallback: fallbackT), absoluteAltitude, .absoluteAltitude)
        }
        return nil
    }

    /// Quality guard for the absolute-altitude channel. The calibration
    /// re-anchor emits an accuracy-500 sentinel carrying garbage altitude, and
    /// water/shore noise in the 2026-07-11 zero-jump log sits around
    /// 17-18 m accuracy while the real one-minute jump logs are around 8-10 m.
    /// V13 is barometer-first, but it should only consume the absolute barometer
    /// when that channel reports usable quality.
    ///
    /// Must run on `engineQueue`.
    private static let absoluteReanchorAccuracyM = 100.0
    private static let absoluteUsableAccuracyM = 12.0
    private static let absoluteDatumStepM = 12.0

    private func gateAbsoluteAltitude(altitudeM: Double, accuracyM: Double?) -> Bool {
        if let accuracyM, accuracyM.isFinite, accuracyM >= Self.absoluteReanchorAccuracyM {
            if !absoluteSentinelActive {
                absoluteSentinelActive = true
                lastAbsoluteAltitudeM = nil
                resetAltitudeStream(reason: "absoluteReanchorSentinel acc=\(fmt(accuracyM))")
            }
            return false
        }
        absoluteSentinelActive = false

        if let accuracyM, accuracyM.isFinite, accuracyM > Self.absoluteUsableAccuracyM {
            if !absoluteAccuracyGateActive {
                absoluteAccuracyGateActive = true
                lastAbsoluteAltitudeM = nil
                resetAltitudeStream(reason: "absoluteAccuracy acc=\(fmt(accuracyM))")
            }
            return false
        }
        absoluteAccuracyGateActive = false

        if let last = lastAbsoluteAltitudeM, abs(altitudeM - last) > Self.absoluteDatumStepM {
            lastAbsoluteAltitudeM = altitudeM
            resetAltitudeStream(reason: "absoluteDatumStep \(fmt(last))->\(fmt(altitudeM))")
        } else {
            lastAbsoluteAltitudeM = altitudeM
        }
        return true
    }

    /// The absolute-altitude datum just moved (re-anchor sentinel or a step of
    /// tens of metres). History in the engine belongs to the old datum, so the
    /// step would otherwise read as a giant (possibly negative) jump arc.
    private func resetAltitudeStream(reason: String) {
        engine.reset()
        lastAltitudeT = nil
        lastAltitudeValue = nil
        logEvent("v13 altitudeStreamReset reason=\(reason)")
    }

    private func fmt(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    private func alignedAltitudeTimestamp(_ sensorT: TimeInterval?, fallback: TimeInterval) -> TimeInterval {
        guard let sensorT, sensorT.isFinite else { return fallback }
        guard fallback.isFinite else { return sensorT }
        return abs(sensorT - fallback) <= 60 ? sensorT : fallback
    }

    private func alignedIndependentAltitudeTimestamp(sensorT: TimeInterval,
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

    /// Altimeter frames are ZOH-held onto every IMU row, so ingest only true
    /// altitude changes. Replaying the same held value would stretch peaks and
    /// landing windows beyond the actual altimeter cadence.
    ///
    /// The calibrated absolute altimeter can emit the exact same value for
    /// minutes while still ticking at 1 Hz (measured: 339 s frozen at 1.04 m,
    /// 22.6 of 48.5 min starved on the 2026-07-08 water log). Dropping every
    /// repeat starves the engine of its time base — takeoff baselines go stale
    /// and landing windows never fill. Repeated values are therefore let
    /// through as a ~1 Hz heartbeat instead of being dropped outright.
    private static let repeatedAltitudeHeartbeatSec = 0.9

    private func shouldIngestAltitude(t: TimeInterval, value: Double) -> Bool {
        guard t.isFinite, value.isFinite else { return false }
        if let last = lastAltitudeT, abs(t - last) < 0.001 {
            return false
        }
        if let last = lastAltitudeT, let lastValue = lastAltitudeValue,
           value == lastValue, t - last < Self.repeatedAltitudeHeartbeatSec {
            return false
        }
        lastAltitudeT = t
        lastAltitudeValue = value
        return true
    }

    private func noteAltitudeSource(_ source: AltitudeSource) {
        guard activeAltitudeSource != source else { return }
        activeAltitudeSource = source
        logEvent("v13 altitudeSource=\(source.rawValue)")
    }

    private func makeJump(from result: V13Jump) -> Jump {
        var jump = Jump(sessionId: sessionId, startTime: wallDate(from: result.takeoffT))
        jump.endTime = wallDate(from: result.landingT)
        jump.height = result.heightM
        jump.airtime = result.airtimeSec
        jump.jumpDistance = result.distanceM ?? 0
        jump.rotations = Int(result.rotationTurns.rounded())
        jump.apexTime = result.apexT - result.takeoffT
        jump.confidence = result.confidence * 100.0
        jump.imuSamples = []
        jump.heightSource = activeAltitudeSource?.rawValue ?? AltitudeSource.absoluteAltitude.rawValue
        jump.absoluteTakeoffAltitude = result.baselinePreM
        jump.absoluteApexAltitude = result.peakAltitudeM
        jump.absoluteLandingAltitude = result.baselinePostM
        jump.takeoffSpeed = result.takeoffSpeedMS
        jump.landingSpeed = result.landingSpeedMS
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

extension JumpDetectorV13: JumpEngineV13Delegate {
    func jumpDetected(_ result: V13Jump) {
        let jump = makeJump(from: result)
        playHaptic(for: jump)
        SessionLogger.shared.logEvent(
            t: result.landingT,
            event: "JUMP(v13) FINAL h=\(jump.height)m air=\(jump.airtime)s dist=\(jump.jumpDistance)m "
                + "pre=\(result.baselinePreM)m post=\(result.baselinePostM ?? -1)m ref=\(result.baselineRefM)m "
                + "takeoffG=\(result.takeoffG) landingG=\(result.landingG) rot=\(result.rotationTurns) "
                + "arcPts=\(result.altitudePointCount) conf=\(jump.confidence) "
                + "trigger=\(result.triggerSource.rawValue) latency=\(String(format: "%.1f", result.emittedAtT - result.landingT))s",
            state: "JUMP",
            speed: result.takeoffSpeedMS ?? latestSpeed()
        )
        onJumpDetected?(jump)
    }
}
