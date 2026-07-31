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
    static let absoluteAltitudeSampleIntervalSec = "v13AbsoluteAltitudeSampleIntervalSec"
    // Preserve the original defaults key so existing user selections migrate
    // without intervention. Its meaning is now final counted height only.
    static let minCountedHeightM = "v13MinRiseM"           // 1.0 / 1.5 / 2.0 picker
    static let candidateRiseM = "v13CandidateRiseM"
    static let takeoffWindowSec = "v13TakeoffWindowSec"
    static let landingDescentM = "v13LandingDescentM"
    static let minGpsSpeedMS = "v13MinGpsSpeedMS"
    static let minGpsDistanceM = "v13MinGpsDistanceM"
    static let triggerAccelG = "v13TriggerAccelG"
    static let triggerGyroRadS = "v13TriggerGyroRadS"
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

    static let countedHeightOptions = [1.0, 1.5, 2.0]
    static let absoluteAltitudeSampleIntervalOptions = [0.25, 0.5, 0.75, 1.0]

    static func normalizedCountedHeight(_ value: Double) -> Double {
        countedHeightOptions.min(by: { abs($0 - value) < abs($1 - value) })
            ?? V13Config().minCountedHeightM
    }

    static func normalizedAbsoluteAltitudeSampleInterval(_ value: Double) -> Double {
        absoluteAltitudeSampleIntervalOptions.min(by: { abs($0 - value) < abs($1 - value) })
            ?? V13Config().absoluteAltitudeSampleIntervalSec
    }
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
    private let engineQueueHealthLock = NSLock()
    private var pendingEngineOperations = 0
    private var maximumPendingEngineOperations = 0
    private var engineQueueDelayEwmaMs = 0.0
    private var maximumEngineQueueDelayMs = 0.0
    private var lastEngineQueueHealthT = 0.0

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
    private var lastAbsoluteAltitudeT: TimeInterval?
    private var lastAbsoluteAccuracyM: Double?
    private var lastAbsoluteAccuracyT: TimeInterval?
    private var absoluteAccuracyWindowStartM: Double?
    private var absoluteAccuracyWindowStartT: TimeInterval?
    private var cumulativeDatumAnchorM: Double?
    private var cumulativeDatumStartT: TimeInterval?
    private var cumulativeDatumDirection: Double = 0
    private var cumulativeDatumStepCount = 0
    private var absoluteSentinelActive = false
    private var absoluteAccuracyGateActive = false
    private var hasDirectAbsoluteStream = false

    /// Adapter diagnostics are internal so replay regression tests can verify
    /// that a datum discontinuity was actually isolated from the engine.
    private(set) var altitudeStreamResetCount = 0
    private(set) var lastAltitudeStreamResetReason: String?

    private let bootWallClock = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime

    init() {
        engine = JumpEngineV13(cfg)
        wireEngine()
    }

    /// Immutable snapshot used by session diagnostics after `reset(mode:)`.
    /// Reading through the engine queue guarantees the header matches the
    /// configuration actually installed in the live engine.
    var effectiveConfiguration: V13Config {
        engineQueue.sync { cfg }
    }

    static func makeConfigFromSettings() -> V13Config {
        let defaults = UserDefaults.standard
        let base = V13Config()
        var cfg = base

        cfg.absoluteAltitudeSampleIntervalSec = V13Settings.normalizedAbsoluteAltitudeSampleInterval(
            doubleSetting(
                V13Settings.absoluteAltitudeSampleIntervalSec,
                default: base.absoluteAltitudeSampleIntervalSec,
                range: 0.25...1.0,
                defaults: defaults
            )
        )

        cfg.minCountedHeightM = V13Settings.normalizedCountedHeight(
            doubleSetting(
                V13Settings.minCountedHeightM,
                default: base.minCountedHeightM,
                range: 0.3...5.0,
                defaults: defaults
            )
        )
        cfg.candidateRiseM = doubleSetting(
            V13Settings.candidateRiseM,
            default: base.candidateRiseM,
            range: 0.3...3.0,
            defaults: defaults
        )
        cfg.takeoffWindowSec = doubleSetting(
            V13Settings.takeoffWindowSec,
            default: base.takeoffWindowSec,
            range: 0.5...3.0,
            defaults: defaults
        )
        cfg.landingDescentM = doubleSetting(
            V13Settings.landingDescentM,
            default: base.landingDescentM,
            range: 0.25...3.0,
            defaults: defaults
        )
        cfg.minGpsSpeedMS = doubleSetting(V13Settings.minGpsSpeedMS, default: base.minGpsSpeedMS, range: base.minGpsSpeedMS...20.0, defaults: defaults)
        cfg.minGpsDistanceM = doubleSetting(V13Settings.minGpsDistanceM, default: base.minGpsDistanceM, range: 0.0...200.0, defaults: defaults)
        cfg.triggerAccelG = doubleSetting(V13Settings.triggerAccelG, default: base.triggerAccelG, range: 0.5...6.0, defaults: defaults)
        cfg.triggerGyroRadS = doubleSetting(V13Settings.triggerGyroRadS, default: base.triggerGyroRadS, range: 1.0...12.0, defaults: defaults)
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
            V13CalculationLogService.shared.configure(cfg, t: ProcessInfo.processInfo.systemUptime)
            sampleCount = 0
            lastMotionT = 0
            lastAltitudeT = nil
            lastAltitudeValue = nil
            lastSubmerged = nil
            activeAltitudeSource = nil
            independentAltitudeBaseSensorT = nil
            independentAltitudeBaseReceivedT = nil
            clearAbsoluteDatumTracking()
            absoluteSentinelActive = false
            absoluteAccuracyGateActive = false
            hasDirectAbsoluteStream = false
            altitudeStreamResetCount = 0
            lastAltitudeStreamResetReason = nil
            resetEngineQueueHealth()
        }

        setLatestSpeed(0)
        setState(.idle)
        setState(.riding)

        let readiness = Self.readinessReport()
        logEvent("JumpDetector(v13) reset - ready=\(readiness.isReady) "
            + "minCounted=\(cfg.minCountedHeightM)m candidateRise=\(cfg.candidateRiseM)m "
            + "takeoffWindow=\(cfg.takeoffWindowSec)s landingDescent=\(cfg.landingDescentM)m "
            + "absoluteInterval=\(cfg.absoluteAltitudeSampleIntervalSec)s "
            + "baroBaselineAvg=\(cfg.baselineWindowSec)s "
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
        guard altitudeM.isFinite else {
            audit(
                t: receivedT,
                stage: "adapter",
                action: "absoluteAltitudeReceived",
                decision: "dropped",
                reason: "nonFiniteAltitude"
            )
            return
        }

        submitToEngine { [weak self] in
            guard let self = self else { return }
            self.hasDirectAbsoluteStream = true
            let t = self.alignedIndependentAltitudeTimestamp(sensorT: sensorT, receivedT: receivedT)
            self.audit(
                t: t,
                stage: "adapter",
                action: "absoluteAltitudeReceived",
                decision: "evaluating",
                values: [
                    "absoluteAltitudeM": altitudeM,
                    "absoluteAccuracyM": accuracyM ?? .nan,
                    "absolutePrecisionM": precisionM ?? .nan,
                    "sensorT": sensorT,
                    "receivedT": receivedT,
                    "alignedT": t
                ]
            )
            guard self.gateAbsoluteAltitude(t: t, altitudeM: altitudeM, accuracyM: accuracyM) else { return }
            guard self.shouldIngestAltitude(t: t, value: altitudeM) else { return }
            self.noteAltitudeSource(.absoluteAltitude)
            self.audit(
                t: t,
                stage: "adapter",
                action: "absoluteAltitudeForwarded",
                decision: "passed",
                values: ["absoluteAltitudeM": altitudeM, "absoluteAccuracyM": accuracyM ?? .nan]
            )
            self.engine.addAltitude(t: t, altitudeM: altitudeM)
        }

        if currentState() == .idle {
            setState(.riding)
        }
    }

    /// V13 now runs the absolute altimeter as a continuous single consumer
    /// with no watchdog restarts (spec P4 — measured: every observed freeze
    /// was a competing consumer or a restart-induced re-anchor, not a lack of
    /// supervision). An acquisition-layer restart notification should not
    /// occur in that mode; if Core Motion restarts the stream anyway for its
    /// own reasons, this is deliberately NOT an engine reset — a mid-session
    /// wipe is far costlier than briefly tolerating a stale sample, and the
    /// gate/heartbeat logic in `shouldIngestAltitude`/`gateAbsoluteAltitude`
    /// already isolates genuinely bad data.
    func absoluteAltitudeStreamDidRestart(reason: String) {
        logEvent("v13 absoluteStreamRestart reason=\(reason) (engine unaffected)")
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
        let enqueuedT = ProcessInfo.processInfo.systemUptime
        noteEngineOperationEnqueued()
        let monitoredWork = { [self] in
            let startedT = ProcessInfo.processInfo.systemUptime
            work()
            let finishedT = ProcessInfo.processInfo.systemUptime
            if let healthRecord = noteEngineOperationCompleted(
                enqueuedT: enqueuedT,
                startedT: startedT,
                finishedT: finishedT
            ) {
                V13CalculationLogService.shared.record(healthRecord)
            }
        }
        if synchronousAnalysis {
            engineQueue.sync(execute: monitoredWork)
        } else {
            engineQueue.async(execute: monitoredWork)
        }
    }

    private func resetEngineQueueHealth() {
        engineQueueHealthLock.lock()
        pendingEngineOperations = 0
        maximumPendingEngineOperations = 0
        engineQueueDelayEwmaMs = 0
        maximumEngineQueueDelayMs = 0
        lastEngineQueueHealthT = ProcessInfo.processInfo.systemUptime
        engineQueueHealthLock.unlock()
    }

    private func noteEngineOperationEnqueued() {
        engineQueueHealthLock.lock()
        pendingEngineOperations += 1
        maximumPendingEngineOperations = max(maximumPendingEngineOperations, pendingEngineOperations)
        engineQueueHealthLock.unlock()
    }

    private func noteEngineOperationCompleted(enqueuedT: TimeInterval,
                                              startedT: TimeInterval,
                                              finishedT: TimeInterval) -> V13AuditRecord? {
        let delayMs = max(0, startedT - enqueuedT) * 1_000
        let workMs = max(0, finishedT - startedT) * 1_000
        var shouldEmit = false
        var pending = 0
        var maximumPending = 0
        var delayEwmaMs = 0.0
        var maximumDelayMs = 0.0

        engineQueueHealthLock.lock()
        pendingEngineOperations = max(0, pendingEngineOperations - 1)
        pending = pendingEngineOperations
        engineQueueDelayEwmaMs = engineQueueDelayEwmaMs == 0
            ? delayMs
            : 0.9 * engineQueueDelayEwmaMs + 0.1 * delayMs
        maximumEngineQueueDelayMs = max(maximumEngineQueueDelayMs, delayMs)
        if finishedT - lastEngineQueueHealthT >= 5.0 {
            shouldEmit = true
            lastEngineQueueHealthT = finishedT
            maximumPending = maximumPendingEngineOperations
            delayEwmaMs = engineQueueDelayEwmaMs
            maximumDelayMs = maximumEngineQueueDelayMs
            maximumPendingEngineOperations = pendingEngineOperations
            maximumEngineQueueDelayMs = delayMs
        }
        engineQueueHealthLock.unlock()

        guard shouldEmit else { return nil }
        let unhealthy = maximumDelayMs >= 250 || maximumPending >= 100
        return V13AuditRecord(
            monotonicTime: finishedT,
            kind: "pipelineHealth",
            stage: "pipeline",
            action: "engineQueueHealth",
            decision: unhealthy ? "degraded" : "healthy",
            reason: maximumDelayMs >= 250
                ? "engineQueueDelay"
                : (maximumPending >= 100 ? "engineQueueBacklog" : nil),
            values: [
                "pendingOperations": Double(pending),
                "maximumPendingOperations": Double(maximumPending),
                "queueDelayEwmaMs": delayEwmaMs,
                "maximumQueueDelayMs": maximumDelayMs,
                "lastWorkDurationMs": workMs
            ],
            labels: ["queue": "com.kiters.jumpV13.engine"]
        )
    }

    private func wireEngine() {
        engine.delegate = self
        engine.onDebug = { [weak self] t, event in
            self?.handleDebug(t: t, event)
        }
        engine.onAudit = { record in
            V13CalculationLogService.shared.record(record)
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
        let oldState = state
        state = newState
        stateLock.unlock()
        audit(
            t: ProcessInfo.processInfo.systemUptime,
            stage: "adapter",
            action: "stateChanged",
            decision: "transition",
            labels: ["stateBefore": oldState.rawValue, "stateAfter": newState.rawValue]
        )
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
        guard let absoluteAltitude = sample.absoluteAltitude else { return nil }
        let t = alignedAltitudeTimestamp(sample.absoluteAltitudeTimestamp, fallback: fallbackT)
        guard gateAbsoluteAltitude(t: t,
                                   altitudeM: absoluteAltitude,
                                   accuracyM: sample.absoluteAltitudeAccuracy) else { return nil }
        return (t, absoluteAltitude, .absoluteAltitude)
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
    private static let absoluteAccuracyStepM = 1.0
    private static let absoluteAccuracyDriftM = 1.5
    private static let absoluteAccuracyWindowSec = 2.0
    private static let cumulativeDatumMinStepM = 1.5
    private static let cumulativeDatumShiftM = 8.0
    private static let cumulativeDatumWindowSec = 2.0

    private func gateAbsoluteAltitude(t: TimeInterval,
                                      altitudeM: Double,
                                      accuracyM: Double?) -> Bool {
        if let accuracyM, accuracyM.isFinite, accuracyM >= Self.absoluteReanchorAccuracyM {
            if !absoluteSentinelActive {
                absoluteSentinelActive = true
                clearAbsoluteDatumTracking()
                resetAltitudeStream(reason: "absoluteReanchorSentinel acc=\(fmt(accuracyM))")
            }
            auditAbsoluteGate(
                t: t,
                altitudeM: altitudeM,
                accuracyM: accuracyM,
                decision: "dropped",
                reason: "absoluteReanchorSentinel",
                conditions: [
                    .init(id: "belowReanchorSentinel", actual: accuracyM, comparator: "<", expected: Self.absoluteReanchorAccuracyM, passed: false, unit: "m")
                ]
            )
            return false
        }
        absoluteSentinelActive = false

        if let accuracyM, accuracyM.isFinite, accuracyM > Self.absoluteUsableAccuracyM {
            if !absoluteAccuracyGateActive {
                absoluteAccuracyGateActive = true
                clearAbsoluteDatumTracking()
                resetAltitudeStream(reason: "absoluteAccuracy acc=\(fmt(accuracyM))")
            }
            auditAbsoluteGate(
                t: t,
                altitudeM: altitudeM,
                accuracyM: accuracyM,
                decision: "dropped",
                reason: "absoluteAccuracyUnusable",
                conditions: [
                    .init(id: "usableAbsoluteAccuracy", actual: accuracyM, comparator: "<=", expected: Self.absoluteUsableAccuracyM, passed: false, unit: "m")
                ]
            )
            return false
        }
        absoluteAccuracyGateActive = false

        if let reason = absoluteAccuracyDiscontinuityReason(t: t, accuracyM: accuracyM) {
            anchorAbsoluteDatumTracking(t: t, altitudeM: altitudeM, accuracyM: accuracyM)
            resetAltitudeStream(reason: reason)
            auditAbsoluteGate(t: t, altitudeM: altitudeM, accuracyM: accuracyM, decision: "passedAfterReset", reason: reason)
            return true
        }

        if let reason = cumulativeDatumDiscontinuityReason(t: t, altitudeM: altitudeM) {
            anchorAbsoluteDatumTracking(t: t, altitudeM: altitudeM, accuracyM: accuracyM)
            resetAltitudeStream(reason: reason)
            auditAbsoluteGate(t: t, altitudeM: altitudeM, accuracyM: accuracyM, decision: "passedAfterReset", reason: reason)
            return true
        }

        recordAbsoluteDatumSample(t: t, altitudeM: altitudeM, accuracyM: accuracyM)
        auditAbsoluteGate(
            t: t,
            altitudeM: altitudeM,
            accuracyM: accuracyM,
            decision: "passed",
            conditions: [
                .init(id: "belowReanchorSentinel", actual: accuracyM, comparator: "<", expected: Self.absoluteReanchorAccuracyM, passed: accuracyM.map { $0 < Self.absoluteReanchorAccuracyM }, unit: "m"),
                .init(id: "usableAbsoluteAccuracy", actual: accuracyM, comparator: "<=", expected: Self.absoluteUsableAccuracyM, passed: accuracyM.map { $0 <= Self.absoluteUsableAccuracyM }, unit: "m")
            ]
        )
        return true
    }

    /// Accuracy normally moves by only a few millimetres between callbacks.
    /// Core Motion re-anchors, however, change it by metres even when the
    /// accompanying altitude step is below the old 12 m datum threshold.
    private func absoluteAccuracyDiscontinuityReason(t: TimeInterval,
                                                      accuracyM: Double?) -> String? {
        guard let accuracyM, accuracyM.isFinite else { return nil }

        if let last = lastAbsoluteAccuracyM,
           let lastT = lastAbsoluteAccuracyT,
           t > lastT,
           t - lastT <= Self.absoluteAccuracyWindowSec,
           abs(accuracyM - last) >= Self.absoluteAccuracyStepM {
            return "absoluteAccuracyStep \(fmt(last))->\(fmt(accuracyM))"
        }

        if let start = absoluteAccuracyWindowStartM,
           let startT = absoluteAccuracyWindowStartT,
           t >= startT,
           t - startT <= Self.absoluteAccuracyWindowSec,
           abs(accuracyM - start) >= Self.absoluteAccuracyDriftM {
            return "absoluteAccuracyDrift \(fmt(start))->\(fmt(accuracyM)) in=\(fmt(t - startT))s"
        }
        return nil
    }

    /// Detect a downward datum correction split across several callbacks. An
    /// upward staircase can be the start of an arbitrarily high real jump, so
    /// altitude magnitude alone must never reset it; it is passed to the engine
    /// for full arc validation. A descent that belongs to a real jump is also
    /// preserved because this guard stands down while airborne.
    private func cumulativeDatumDiscontinuityReason(t: TimeInterval,
                                                     altitudeM: Double) -> String? {
        guard currentState() != .airborne else {
            clearCumulativeDatumCandidate()
            return nil
        }
        guard let last = lastAbsoluteAltitudeM,
              let lastT = lastAbsoluteAltitudeT,
              t > lastT,
              t - lastT <= Self.cumulativeDatumWindowSec else {
            clearCumulativeDatumCandidate()
            return nil
        }

        let step = altitudeM - last
        guard step < 0 else {
            clearCumulativeDatumCandidate()
            return nil
        }
        let direction = -1.0
        guard abs(step) >= Self.cumulativeDatumMinStepM else {
            if cumulativeDatumDirection != 0, direction != 0, direction != cumulativeDatumDirection {
                clearCumulativeDatumCandidate()
            }
            return nil
        }

        let candidateExpired = cumulativeDatumStartT.map { t - $0 > Self.cumulativeDatumWindowSec } ?? true
        if cumulativeDatumAnchorM == nil || candidateExpired || direction != cumulativeDatumDirection {
            cumulativeDatumAnchorM = last
            cumulativeDatumStartT = lastT
            cumulativeDatumDirection = direction
            cumulativeDatumStepCount = 1
        } else {
            cumulativeDatumStepCount += 1
        }

        guard let anchor = cumulativeDatumAnchorM,
              let startT = cumulativeDatumStartT else { return nil }
        let cumulativeShift = altitudeM - anchor
        guard cumulativeDatumStepCount >= 2,
              abs(cumulativeShift) >= Self.cumulativeDatumShiftM else { return nil }
        return "absoluteDatumCumulative from=\(fmt(anchor)) to=\(fmt(altitudeM)) "
            + "delta=\(fmt(cumulativeShift)) in=\(fmt(t - startT))s steps=\(cumulativeDatumStepCount)"
    }

    private func recordAbsoluteDatumSample(t: TimeInterval,
                                           altitudeM: Double,
                                           accuracyM: Double?) {
        lastAbsoluteAltitudeM = altitudeM
        lastAbsoluteAltitudeT = t

        guard let accuracyM, accuracyM.isFinite else { return }
        lastAbsoluteAccuracyM = accuracyM
        lastAbsoluteAccuracyT = t
        if absoluteAccuracyWindowStartT == nil
            || t < (absoluteAccuracyWindowStartT ?? t)
            || t - (absoluteAccuracyWindowStartT ?? t) > Self.absoluteAccuracyWindowSec {
            absoluteAccuracyWindowStartM = accuracyM
            absoluteAccuracyWindowStartT = t
        }
    }

    private func anchorAbsoluteDatumTracking(t: TimeInterval,
                                             altitudeM: Double,
                                             accuracyM: Double?) {
        clearAbsoluteDatumTracking()
        lastAbsoluteAltitudeM = altitudeM
        lastAbsoluteAltitudeT = t
        if let accuracyM, accuracyM.isFinite {
            lastAbsoluteAccuracyM = accuracyM
            lastAbsoluteAccuracyT = t
            absoluteAccuracyWindowStartM = accuracyM
            absoluteAccuracyWindowStartT = t
        }
    }

    private func clearAbsoluteDatumTracking() {
        lastAbsoluteAltitudeM = nil
        lastAbsoluteAltitudeT = nil
        lastAbsoluteAccuracyM = nil
        lastAbsoluteAccuracyT = nil
        absoluteAccuracyWindowStartM = nil
        absoluteAccuracyWindowStartT = nil
        clearCumulativeDatumCandidate()
    }

    private func clearCumulativeDatumCandidate() {
        cumulativeDatumAnchorM = nil
        cumulativeDatumStartT = nil
        cumulativeDatumDirection = 0
        cumulativeDatumStepCount = 0
    }

    /// The absolute-altitude datum just moved. Height magnitude alone never
    /// reaches this method: a reset requires an accuracy discontinuity, the
    /// Core Motion sentinel, or a cumulative downward staircase while riding.
    private func resetAltitudeStream(reason: String) {
        audit(
            t: ProcessInfo.processInfo.systemUptime,
            stage: "adapter",
            action: "datumReset",
            decision: "transition",
            reason: reason,
            values: ["resetCount": Double(altitudeStreamResetCount + 1)],
            labels: ["engineHistory": "cleared"]
        )
        engine.reset()
        lastAltitudeT = nil
        lastAltitudeValue = nil
        altitudeStreamResetCount += 1
        lastAltitudeStreamResetReason = reason
        setState(.riding)
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
    /// through as a ~1 Hz heartbeat instead of being dropped outright. Live
    /// hardware callbacks are already cadence-limited by MotionManager.
    private static let repeatedAltitudeHeartbeatSec = 0.9

    private func shouldIngestAltitude(t: TimeInterval, value: Double) -> Bool {
        guard t.isFinite, value.isFinite else {
            audit(t: t, stage: "adapter", action: "altitudeCadence", decision: "dropped", reason: "nonFinite")
            return false
        }
        if let last = lastAltitudeT, abs(t - last) < 0.001 {
            audit(
                t: t,
                stage: "adapter",
                action: "altitudeCadence",
                decision: "dropped",
                reason: "duplicateTimestamp",
                values: ["absoluteAltitudeM": value, "deltaTimeSec": t - last]
            )
            return false
        }
        if let last = lastAltitudeT, let lastValue = lastAltitudeValue,
           value == lastValue,
           t - last < Self.repeatedAltitudeHeartbeatSec {
            audit(
                t: t,
                stage: "adapter",
                action: "altitudeCadence",
                decision: "dropped",
                reason: "heldValueBeforeHeartbeat",
                values: ["absoluteAltitudeM": value, "deltaTimeSec": t - last],
                conditions: [
                    .init(id: "repeatedAltitudeHeartbeat", actual: t - last, comparator: ">=", expected: Self.repeatedAltitudeHeartbeatSec, passed: false, unit: "s")
                ]
            )
            return false
        }
        lastAltitudeT = t
        lastAltitudeValue = value
        audit(
            t: t,
            stage: "adapter",
            action: "altitudeCadence",
            decision: "passed",
            values: ["absoluteAltitudeM": value]
        )
        return true
    }

    private func noteAltitudeSource(_ source: AltitudeSource) {
        guard activeAltitudeSource != source else { return }
        activeAltitudeSource = source
        audit(
            t: ProcessInfo.processInfo.systemUptime,
            stage: "adapter",
            action: "altitudeSource",
            decision: "selected",
            labels: ["source": source.rawValue]
        )
        logEvent("v13 altitudeSource=\(source.rawValue)")
    }

    private func auditAbsoluteGate(t: TimeInterval,
                                   altitudeM: Double,
                                   accuracyM: Double?,
                                   decision: String,
                                   reason: String? = nil,
                                   conditions: [V13AuditCondition] = []) {
        audit(
            t: t,
            stage: "adapter",
            action: "absoluteAltitudeQuality",
            decision: decision,
            reason: reason,
            values: ["absoluteAltitudeM": altitudeM, "absoluteAccuracyM": accuracyM ?? .nan],
            conditions: conditions
        )
    }

    private func audit(t: TimeInterval,
                       stage: String,
                       action: String,
                       decision: String,
                       reason: String? = nil,
                       values: [String: Double] = [:],
                       labels: [String: String] = [:],
                       conditions: [V13AuditCondition] = []) {
        V13CalculationLogService.shared.record(V13AuditRecord(
            monotonicTime: t,
            stage: stage,
            action: action,
            decision: decision,
            reason: reason,
            values: values,
            labels: labels,
            conditions: conditions
        ))
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
