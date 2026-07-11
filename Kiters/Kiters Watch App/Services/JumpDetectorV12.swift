//
//  JumpDetectorV12.swift
//  Kiters Watch App
//
//  Adapter for the V12 Apple Sensor Fusion engine. It conforms to the same
//  JumpDetecting surface as v7-v11 and feeds the pure V12 pipeline from the app's
//  existing workout-owned motion/GPS/submersion streams.
//

import Foundation
import CoreMotion
#if canImport(WatchKit)
import WatchKit
#endif

struct JumpDetectorV12Readiness {
    let isReady: Bool
    let userFacingReason: String
    let logDetails: String
}

private enum V12BaroSource: String {
    case absoluteAltitude
}

enum V12DebugSettings {
    static let defaultsVersion = "v12DebugSettingsVersion"
    static let currentDefaultsVersion = 3

    static let forceEngineWhenNotReady = "v12ForceEngineWhenNotReady"
    static let disableSpeedGate = "v12DisableSpeedGate"
    static let disableBaroAnchorGate = "v12DisableBaroAnchorGate"
    static let disableCrashCooldown = "v12DisableCrashCooldown"
    static let disableMidArcCrashAbort = "v12DisableMidArcCrashAbort"
    static let disableLandingBaroConfirmation = "v12DisableLandingBaroConfirmation"
    static let disableMinHeightGate = "v12DisableMinHeightGate"
    static let disableRefineRetraction = "v12DisableRefineRetraction"

    static let yankG = "v12YankG"
    static let crashG = "v12CrashG"
    static let landImpactG = "v12LandImpactG"
    static let absoluteTakeoffRiseM = "v12AbsoluteTakeoffRiseM"
    static let landingReturnToleranceM = "v12LandingReturnToleranceM"
    static let minAirSec = "v12MinAirSec"
    static let maxAirSec = "v12MaxAirSec"
    static let planingSpeedMs = "v12PlaningSpeedMs"
    static let planingWinSec = "v12PlaningWinSec"
    static let anchorMaxAgeSec = "v12AnchorMaxAgeSec"
    static let anchorMinSamples = "v12AnchorMinSamples"
    static let minJumpHeightM = "v12MinJumpHeightM"
    static let maxJumpHeightM = "v12MaxJumpHeightM"
    static let crashCooldownSec = "v12CrashCooldownSec"
    static let chopWinSec = "v12ChopWinSec"
    static let chopResumeFrac = "v12ChopResumeFrac"
    static let chopResumeHoldSec = "v12ChopResumeHoldSec"
    static let refineDelaySec = "v12RefineDelaySec"
    static let rtzCorrectM = "v12RtzCorrectM"

    private static let allKeys = [
        forceEngineWhenNotReady,
        disableSpeedGate,
        disableBaroAnchorGate,
        disableCrashCooldown,
        disableMidArcCrashAbort,
        disableLandingBaroConfirmation,
        disableMinHeightGate,
        disableRefineRetraction,
        yankG,
        crashG,
        landImpactG,
        absoluteTakeoffRiseM,
        landingReturnToleranceM,
        minAirSec,
        maxAirSec,
        planingSpeedMs,
        planingWinSec,
        anchorMaxAgeSec,
        anchorMinSamples,
        minJumpHeightM,
        maxJumpHeightM,
        crashCooldownSec,
        chopWinSec,
        chopResumeFrac,
        chopResumeHoldSec,
        refineDelaySec,
        rtzCorrectM
    ]

    static func resetToDefaults(_ defaults: UserDefaults = .standard) {
        allKeys.forEach { defaults.removeObject(forKey: $0) }
        defaults.set(currentDefaultsVersion, forKey: defaultsVersion)
    }

    static func migrateIfNeeded(_ defaults: UserDefaults = .standard) {
        guard defaults.integer(forKey: defaultsVersion) < currentDefaultsVersion else { return }

        let base = V12Config()
        defaults.set(!base.requirePlaning, forKey: disableSpeedGate)
        defaults.set(!base.requireBaroAnchor, forKey: disableBaroAnchorGate)
        defaults.set(!base.enforceCrashCooldown, forKey: disableCrashCooldown)
        defaults.set(!base.abortOnMidArcCrash, forKey: disableMidArcCrashAbort)
        defaults.set(!base.requireLandingBaroConfirmation, forKey: disableLandingBaroConfirmation)
        defaults.set(!base.enforceMinJumpHeight, forKey: disableMinHeightGate)
        defaults.set(!base.retractOnRefineReject, forKey: disableRefineRetraction)

        migrateDouble(minAirSec, oldDefault: 1.2, newDefault: base.minAirSec, defaults: defaults)
        migrateDouble(anchorMinSamples, oldDefault: 2.0, newDefault: Double(base.anchorMinSamples), defaults: defaults)
        migrateDouble(minJumpHeightM, oldDefaults: [0.25, 1.5], newDefault: base.minJumpHeightM, defaults: defaults)
        migrateDouble(absoluteTakeoffRiseM, oldDefault: nil, newDefault: base.absoluteTakeoffRiseM, defaults: defaults)
        migrateDouble(landingReturnToleranceM, oldDefault: nil, newDefault: base.landingReturnToleranceM, defaults: defaults)

        defaults.set(currentDefaultsVersion, forKey: defaultsVersion)
    }

    private static func migrateDouble(_ key: String,
                                      oldDefault: Double?,
                                      newDefault: Double,
                                      defaults: UserDefaults) {
        migrateDouble(key, oldDefaults: oldDefault.map { [$0] } ?? [], newDefault: newDefault, defaults: defaults)
    }

    private static func migrateDouble(_ key: String,
                                      oldDefaults: [Double],
                                      newDefault: Double,
                                      defaults: UserDefaults) {
        guard defaults.object(forKey: key) != nil else {
            defaults.set(newDefault, forKey: key)
            return
        }
        let current = defaults.double(forKey: key)
        if oldDefaults.contains(where: { abs(current - $0) < 0.0001 }) {
            defaults.set(newDefault, forKey: key)
        }
    }
}

final class JumpDetectorV12: JumpDetecting {
    var sessionId: String = ""
    var synchronousAnalysis = false
    var onJumpDetected: ((Jump) -> Void)?
    var onStateChanged: ((JumpDetector.JumpState) -> Void)?

    /// V12 emits an instant jump and then a refined result for the same physical
    /// jump after the return-to-zero drift check.
    var onJumpUpdated: ((Jump) -> Void)?
    var onJumpRetracted: ((String) -> Void)?

    private var cfg = JumpDetectorV12.makeConfigFromSettings()
    private var pipeline: JumpPipelineV12
    private let pipelineQueue = DispatchQueue(label: "com.kiters.jumpV12.pipeline", qos: .userInitiated)
    private let stateLock = NSLock()
    private let speedLock = NSLock()

    private var state: JumpDetector.JumpState = .idle
    private var latestSpeedMS: Double = 0
    private var sampleCount = 0
    private var lastMotionT: TimeInterval = 0
    private var lastBarometerT: TimeInterval?
    private var lastSubmerged: Bool?
    private var activeBaroSource: V12BaroSource?
    private var emittedByKey: [String: Jump] = [:]

    private let bootWallClock = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime

    init() {
        pipeline = JumpPipelineV12(cfg)
        wirePipeline()
    }

    private static func makeConfigFromSettings() -> V12Config {
        let defaults = UserDefaults.standard
        V12DebugSettings.migrateIfNeeded(defaults)
        let base = V12Config()
        var cfg = base

        cfg.yankG = doubleSetting(V12DebugSettings.yankG, default: base.yankG, range: 0.5...6.0, defaults: defaults)
        cfg.crashG = doubleSetting(V12DebugSettings.crashG, default: base.crashG, range: 2.0...12.0, defaults: defaults)
        cfg.landImpactG = doubleSetting(V12DebugSettings.landImpactG, default: base.landImpactG, range: 0.3...6.0, defaults: defaults)
        cfg.absoluteTakeoffRiseM = doubleSetting(V12DebugSettings.absoluteTakeoffRiseM, default: base.absoluteTakeoffRiseM, range: 0.0...3.0, defaults: defaults)
        cfg.landingReturnToleranceM = doubleSetting(V12DebugSettings.landingReturnToleranceM, default: base.landingReturnToleranceM, range: 0.05...3.0, defaults: defaults)
        cfg.chopWinSec = doubleSetting(V12DebugSettings.chopWinSec, default: base.chopWinSec, range: 0.05...2.0, defaults: defaults)
        cfg.chopResumeFrac = doubleSetting(V12DebugSettings.chopResumeFrac, default: base.chopResumeFrac, range: 0.05...2.0, defaults: defaults)
        cfg.chopResumeHoldSec = doubleSetting(V12DebugSettings.chopResumeHoldSec, default: base.chopResumeHoldSec, range: 0.0...2.5, defaults: defaults)
        cfg.minAirSec = doubleSetting(V12DebugSettings.minAirSec, default: base.minAirSec, range: 0.0...4.0, defaults: defaults)
        cfg.maxAirSec = doubleSetting(V12DebugSettings.maxAirSec, default: base.maxAirSec, range: 1.0...30.0, defaults: defaults)
        if cfg.maxAirSec < cfg.minAirSec {
            cfg.maxAirSec = cfg.minAirSec
        }
        cfg.planingSpeedMs = doubleSetting(V12DebugSettings.planingSpeedMs, default: base.planingSpeedMs, range: 0.0...8.0, defaults: defaults)
        cfg.planingWinSec = doubleSetting(V12DebugSettings.planingWinSec, default: base.planingWinSec, range: 0.0...20.0, defaults: defaults)
        cfg.anchorMaxAgeSec = doubleSetting(V12DebugSettings.anchorMaxAgeSec, default: base.anchorMaxAgeSec, range: 0.5...30.0, defaults: defaults)
        cfg.anchorMinSamples = Int(doubleSetting(V12DebugSettings.anchorMinSamples, default: Double(base.anchorMinSamples), range: 1.0...8.0, defaults: defaults).rounded())
        cfg.minJumpHeightM = doubleSetting(V12DebugSettings.minJumpHeightM, default: base.minJumpHeightM, range: 0.0...8.0, defaults: defaults)
        cfg.maxJumpHeightM = doubleSetting(V12DebugSettings.maxJumpHeightM, default: base.maxJumpHeightM, range: 1.0...40.0, defaults: defaults)
        if cfg.maxJumpHeightM < cfg.minJumpHeightM {
            cfg.maxJumpHeightM = cfg.minJumpHeightM
        }
        cfg.refineDelaySec = doubleSetting(V12DebugSettings.refineDelaySec, default: base.refineDelaySec, range: 0.0...10.0, defaults: defaults)
        cfg.rtzCorrectM = doubleSetting(V12DebugSettings.rtzCorrectM, default: base.rtzCorrectM, range: 0.0...3.0, defaults: defaults)
        cfg.crashCooldownSec = doubleSetting(V12DebugSettings.crashCooldownSec, default: base.crashCooldownSec, range: 0.0...120.0, defaults: defaults)

        let disableSpeedGate = boolSetting(V12DebugSettings.disableSpeedGate, default: !base.requirePlaning, defaults: defaults)
        let disableBaroAnchorGate = boolSetting(V12DebugSettings.disableBaroAnchorGate, default: !base.requireBaroAnchor, defaults: defaults)
        let disableCrashCooldown = boolSetting(V12DebugSettings.disableCrashCooldown, default: !base.enforceCrashCooldown, defaults: defaults)
        let disableMidArcCrashAbort = boolSetting(V12DebugSettings.disableMidArcCrashAbort, default: !base.abortOnMidArcCrash, defaults: defaults)
        let disableLandingBaroConfirmation = boolSetting(V12DebugSettings.disableLandingBaroConfirmation, default: !base.requireLandingBaroConfirmation, defaults: defaults)
        let disableMinHeightGate = boolSetting(V12DebugSettings.disableMinHeightGate, default: !base.enforceMinJumpHeight, defaults: defaults)
        let disableRefineRetraction = boolSetting(V12DebugSettings.disableRefineRetraction, default: !base.retractOnRefineReject, defaults: defaults)

        cfg.requirePlaning = !disableSpeedGate
        cfg.requireBaroAnchor = !disableBaroAnchorGate
        cfg.enforceCrashCooldown = !disableCrashCooldown
        cfg.abortOnMidArcCrash = !disableMidArcCrashAbort
        cfg.requireLandingBaroConfirmation = !disableLandingBaroConfirmation
        cfg.enforceMinJumpHeight = !disableMinHeightGate
        cfg.retractOnRefineReject = !disableRefineRetraction
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

    private static func boolSetting(_ key: String,
                                    default defaultValue: Bool,
                                    defaults: UserDefaults) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }

    static func readinessReport() -> JumpDetectorV12Readiness {
        var details: [String] = []
        var blockers: [String] = []

        #if os(watchOS)
        if #available(watchOS 10.0, *) {
            let motionStatus = CMBatchedSensorManager.authorizationStatus
            details.append("batched motion auth=\(motionStatus.rawValue)")
            details.append("batched deviceMotion: \(CMBatchedSensorManager.isDeviceMotionSupported ? "supported" : "unsupported")")
        } else {
            details.append("batched deviceMotion: unavailable before watchOS 10")
        }

        let fallbackMotionAvailable = CMMotionManager().isDeviceMotionAvailable
        details.append("fallback deviceMotion: \(fallbackMotionAvailable ? "available" : "unavailable")")
        if !fallbackMotionAvailable {
            blockers.append("device motion is unavailable")
        }

        let altimeterStatus = CMAltimeter.authorizationStatus()
        details.append("altimeter auth=\(altimeterStatus.rawValue)")
        if altimeterStatus == .denied || altimeterStatus == .restricted {
            blockers.append("altimeter permission is not available")
        }

        details.append("relative altitude diagnostics: \(CMAltimeter.isRelativeAltitudeAvailable() ? "available" : "unavailable")")

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

        return JumpDetectorV12Readiness(
            isReady: blockers.isEmpty,
            userFacingReason: blockers.first ?? "V12 is ready",
            logDetails: (details + blockers.map { "blocker: \($0)" }).joined(separator: "; ")
        )
    }

    func reset(mode: DetectionMode) {
        pipelineQueue.sync {
            cfg = Self.makeConfigFromSettings()
            pipeline = JumpPipelineV12(cfg)
            wirePipeline()
            pipeline.reset()
            sampleCount = 0
            lastMotionT = 0
            lastBarometerT = nil
            lastSubmerged = nil
            activeBaroSource = nil
            emittedByKey.removeAll(keepingCapacity: true)
        }

        setLatestSpeed(0)
        setState(.idle)
        setState(.riding)

        let readiness = Self.readinessReport()
        let speedGate = cfg.requirePlaning ? String(format: "%.2fm/s", cfg.planingSpeedMs) : "disabled"
        let gates = [
            "anchor=\(cfg.requireBaroAnchor ? "on" : "off")",
            "crashCooldown=\(cfg.enforceCrashCooldown ? "on" : "off")",
            "midArcCrash=\(cfg.abortOnMidArcCrash ? "on" : "off")",
            "landingBaro=\(cfg.requireLandingBaroConfirmation ? "on" : "off")",
            "minHeight=\(cfg.enforceMinJumpHeight ? "\(cfg.minJumpHeightM)m" : "off")",
            "refineRetract=\(cfg.retractOnRefineReject ? "on" : "off")"
        ].joined(separator: " ")
        logEvent("JumpDetector(v12) reset - ready=\(readiness.isReady) speedGate=\(speedGate) "
            + "absoluteRise=\(cfg.absoluteTakeoffRiseM)m landingReturn=\(cfg.landingReturnToleranceM)m "
            + "\(gates) \(readiness.logDetails)")
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

        pipelineQueue.async { [weak self] in
            self?.pipeline.addLocation(t: t, lat: latitude, lng: longitude, speedMs: speedMS)
        }

        if currentState() == .idle {
            setState(.riding)
        }
    }

    func processSample(_ sample: IMUSample) {
        sampleCount += 1
        let motionT = sample.motionTimestamp ?? monotonicTime(from: sample.timestamp)
        let accel = sample.accelerationMagnitude
        let submerged = sample.submerged

        pipelineQueue.async { [weak self] in
            guard let self = self else { return }
            self.lastMotionT = motionT

            if let submerged, submerged != self.lastSubmerged {
                self.lastSubmerged = submerged
                self.pipeline.addSubmersion(t: motionT, submerged: submerged)
            }

            let baroFrame = self.v12BaroFrame(from: sample, fallbackT: motionT)
            if let baroFrame, self.shouldIngestBaro(t: baroFrame.t) {
                self.noteBaroSource(baroFrame.source)
                self.pipeline.addBaro(t: baroFrame.t, relAltM: baroFrame.relAltM)
            }

            self.pipeline.addAccel(t: motionT, aMag: accel)
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

    func endSession() -> [Jump] {
        pipelineQueue.sync {
            pipeline.flush(t: lastMotionT)
        }
        logEvent("JumpDetector(v12) endSession flush")
        return []
    }

    private func wirePipeline() {
        pipeline.delegate = self
        pipeline.onDebug = { [weak self] _, event in
            self?.handleDebug(event)
        }
    }

    private func handleDebug(_ event: String) {
        if event.hasPrefix("TAKEOFF") || event.hasPrefix("RESTART") {
            setState(.airborne)
        } else if event.hasPrefix("ABORT") || event.hasPrefix("REJECT") || event.hasPrefix("JUMP") {
            setState(.riding)
        }
        logEvent("v12 \(event)")
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

    private func v12BaroFrame(from sample: IMUSample, fallbackT: TimeInterval) -> (t: TimeInterval, relAltM: Double, source: V12BaroSource)? {
        guard let absoluteAltitude = sample.absoluteAltitude else { return nil }
        let t = sample.absoluteAltitudeTimestamp ?? fallbackT
        return (t, absoluteAltitude, .absoluteAltitude)
    }

    private func shouldIngestBaro(t: TimeInterval) -> Bool {
        guard t.isFinite else { return false }
        if let last = lastBarometerT, abs(t - last) < 0.001 {
            return false
        }
        lastBarometerT = t
        return true
    }

    private func noteBaroSource(_ source: V12BaroSource) {
        guard activeBaroSource != source else { return }
        activeBaroSource = source
        logEvent("v12 baroSource=\(source.rawValue)")
    }

    private func makeJump(from result: V12Jump, replacing existing: Jump? = nil) -> Jump {
        var jump = existing ?? Jump(sessionId: sessionId, startTime: wallDate(from: result.takeoffT))
        jump.sessionId = sessionId
        jump.startTime = wallDate(from: result.takeoffT)
        jump.endTime = wallDate(from: result.landingT)
        jump.height = result.heightM
        jump.airtime = result.airtimeSec
        jump.jumpDistance = result.distanceM ?? 0
        jump.rotations = 0
        jump.apexTime = result.apexT - result.takeoffT
        jump.confidence = result.confidence * 100.0
        jump.imuSamples = []
        jump.heightSource = "absoluteAltitude"
        jump.absoluteTakeoffAltitude = result.takeoffAltitudeM
        jump.absoluteApexAltitude = result.apexAltitudeM
        jump.absoluteLandingAltitude = result.landingAltitudeM
        jump.takeoffSpeed = result.takeoffSpeedMS
        jump.landingSpeed = result.landingSpeedMS
        return jump
    }

    private func key(for result: V12Jump) -> String {
        String(format: "%.2f", result.takeoffT)
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

    private func logEvent(t: TimeInterval,
                          _ msg: @autoclosure () -> String,
                          state: String = "",
                          speed: Double = 0) {
        let message = msg()
        #if DEBUG
        print("🦘 \(message)")
        #endif
        SessionLogger.shared.logEvent(t: t, event: message, state: state, speed: speed)
    }
}

extension JumpDetectorV12: JumpPipelineV12Delegate {
    func jumpDetected(_ result: V12Jump) {
        let jump = makeJump(from: result)
        emittedByKey[key(for: result)] = jump
        playHaptic(for: jump)
        logEvent(
            t: result.landingT,
            "JUMP(v12) REAL absolute h=\(jump.height)m startAlt=\(result.takeoffAltitudeM)m "
                + "apexAlt=\(result.apexAltitudeM)m landAlt=\(result.landingAltitudeM ?? -1)m "
                + "air=\(jump.airtime)s dist=\(jump.jumpDistance)m "
                + "takeoffSpeed=\(result.takeoffSpeedMS ?? -1)m/s landingSpeed=\(result.landingSpeedMS ?? -1)m/s "
                + "conf=\(jump.confidence) arcPts=\(result.arcBaroPoints)",
            state: "JUMP",
            speed: result.takeoffSpeedMS ?? latestSpeed()
        )
        onJumpDetected?(jump)
    }

    func jumpRefined(_ result: V12Jump) {
        let jumpKey = key(for: result)
        guard let existing = emittedByKey[jumpKey] else {
            let jump = makeJump(from: result)
            emittedByKey[jumpKey] = jump
            onJumpDetected?(jump)
            return
        }

        let refinedRejectedByHeight = cfg.enforceMinJumpHeight && result.heightM < cfg.minJumpHeightM
        let refinedRejectedByConfidence = result.confidence <= 0.30
        if cfg.retractOnRefineReject && (refinedRejectedByHeight || refinedRejectedByConfidence) {
            emittedByKey.removeValue(forKey: jumpKey)
            logEvent("JUMP(v12) RETRACTED id=\(existing.id) h=\(result.heightM)m conf=\(result.confidence * 100.0)")
            onJumpRetracted?(existing.id)
            return
        }

        let updated = makeJump(from: result, replacing: existing)
        emittedByKey[jumpKey] = updated
        logEvent("JUMP(v12) REFINED h=\(updated.height)m air=\(updated.airtime)s "
            + "conf=\(updated.confidence) drift=\(result.driftSuspect) rtz=\(result.rtzM ?? 0)")
        onJumpUpdated?(updated)
    }
}
