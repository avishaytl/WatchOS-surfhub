//
//  JumpDetectorV15.swift
//  Kiters Watch App
//
//  Adapter for the pure V15 clean engine (IMU-led detection, continuous
//  barometric measurement). Conforms to JumpDetecting and feeds JumpEngineV15
//  from the app's workout-owned sensor streams. Deliberately self-contained —
//  no dependency on any other engine's adapter or settings.
//
//  • IMU (200 Hz): vertical load = gravity-projected user acceleration
//    (~1 g at rest, ~0 g in freefall), computed here so the engine stays
//    platform-free. Gyro magnitude rides along for spin metrics.
//  • Absolute altitude (3 Hz): CONTINUOUS single-consumer stream for the whole
//    session (spec P4 — onDemand froze 96% of the time, a parallel consumer
//    24%; alone and continuous: 0%). Forwarded unconditionally; the engine's
//    own hygiene (sentinel/degraded accuracy, datum steps, freeze detector,
//    splash-guard) decides what to use.
//  • Relative (pressure) altitude: backup channel, extracted from the ZOH-held
//    IMU rows and de-duplicated by the barometer's own timestamp.
//  • GPS: metrics only (distance/speed); no detection gate reads it.
//
//  An acquisition-layer restart notification is logged and ignored — V15 runs
//  without watchdog restarts by design (restarts only ever added degenerate
//  warm-up records; a real freeze means a competing consumer, which the
//  single-consumer contract already rules out).
//

import Foundation
import CoreMotion
#if canImport(WatchKit)
import WatchKit
#endif

/// UserDefaults override keys — the field-tunable V15 thresholds. Absent keys
/// fall back to the V15Config defaults. The rise threshold reuses the shared
/// "v13MinRiseM" key so the user's 1/1.5/2 m picker selection carries over.
enum V15Settings {
    static let minRiseM = "v13MinRiseM"        // shared 1.0 / 1.5 / 2.0 picker
    static let yankOpenG = "v15YankOpenG"
    static let quietStdG = "v15QuietStdG"
    static let impactG = "v15ImpactG"
    static let floatFactor = "v15FloatFactor"  // the single §9 calibration knob
    static let minFloatFraction = "v15MinFloatFraction"
    static let splashGuardSec = "v15SplashGuardSec"
    static let maxFlightSec = "v15MaxFlightSec"

    static let riseOptions = [1.0, 1.5, 2.0]

    static func normalizedRise(_ value: Double) -> Double {
        riseOptions.min(by: { abs($0 - value) < abs($1 - value) })
            ?? V15Config().minRiseM
    }
}

final class JumpDetectorV15: JumpDetecting {
    var sessionId: String = ""
    var synchronousAnalysis = false
    var onJumpDetected: ((Jump) -> Void)?
    var onStateChanged: ((JumpDetector.JumpState) -> Void)?
    /// Tooling hook (offline replay/forensics) — mirrors every onDebug event
    /// the engine emits, independent of SessionLogger's silence flag.
    var onDebugEvent: ((TimeInterval, String) -> Void)?

    private var cfg = JumpDetectorV15.makeConfigFromSettings()
    private var engine: JumpEngineV15
    private let engineQueue = DispatchQueue(label: "com.kiters.jumpV15.engine", qos: .userInitiated)
    private let stateLock = NSLock()
    private let speedLock = NSLock()

    private var state: JumpDetector.JumpState = .idle
    private var latestSpeedMS: Double = 0
    private var sampleCount = 0
    private var lastMotionT: TimeInterval = 0
    private var lastBarometerT: TimeInterval?
    private var lastRowAbsoluteT: TimeInterval?
    private var hasDirectAbsoluteStream = false
    private var independentAltitudeBaseSensorT: TimeInterval?
    private var independentAltitudeBaseReceivedT: TimeInterval?

    private let bootWallClock = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime

    init() {
        engine = JumpEngineV15(cfg)
        wireEngine()
    }

    /// Immutable snapshot for session diagnostics; read through the engine
    /// queue so it matches the configuration actually installed.
    var effectiveConfiguration: V15Config {
        engineQueue.sync { cfg }
    }

    static func makeConfigFromSettings() -> V15Config {
        let defaults = UserDefaults.standard
        let base = V15Config()
        var cfg = base

        cfg.minRiseM = V15Settings.normalizedRise(
            doubleSetting(V15Settings.minRiseM, default: base.minRiseM, range: 0.3...5.0, defaults: defaults)
        )
        // V15-FIX §3 F6: the range excluded the actual default (1.2) — any
        // user-set value, even one aimed back near default, got clamped up
        // to 1.5 and could never return to the calibrated 1.2.
        cfg.yankOpenG = doubleSetting(V15Settings.yankOpenG, default: base.yankOpenG, range: 1.0...5.0, defaults: defaults)
        cfg.quietStdG = doubleSetting(V15Settings.quietStdG, default: base.quietStdG, range: 0.1...0.6, defaults: defaults)
        cfg.impactG = doubleSetting(V15Settings.impactG, default: base.impactG, range: 1.2...5.0, defaults: defaults)
        cfg.floatFactor = doubleSetting(V15Settings.floatFactor, default: base.floatFactor, range: 1.0...3.5, defaults: defaults)
        cfg.minFloatFraction = doubleSetting(V15Settings.minFloatFraction, default: base.minFloatFraction, range: 0.1...0.9, defaults: defaults)
        cfg.splashGuardSec = doubleSetting(V15Settings.splashGuardSec, default: base.splashGuardSec, range: 1.0...6.0, defaults: defaults)
        cfg.maxFlightSec = doubleSetting(V15Settings.maxFlightSec, default: base.maxFlightSec, range: 5.0...40.0, defaults: defaults)
        return cfg
    }

    private static func doubleSetting(_ key: String,
                                      default defaultValue: Double,
                                      range: ClosedRange<Double>,
                                      defaults: UserDefaults) -> Double {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return min(max(defaults.double(forKey: key), range.lowerBound), range.upperBound)
    }

    /// V15 detects from the IMU; the barometer measures. Only device motion is
    /// a hard requirement — everything else degrades to a lower height floor.
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
            details.append("absolute altitude: \(absoluteAvailable ? "available" : "unavailable (apexFit floor disabled)")")
        }
        #else
        details.append("offline replay: watch sensor readiness skipped")
        #endif

        return JumpDetectorV13Readiness(
            isReady: blockers.isEmpty,
            userFacingReason: blockers.first ?? "V15 is ready",
            logDetails: (details + blockers.map { "blocker: \($0)" }).joined(separator: "; ")
        )
    }

    func reset(mode: DetectionMode) {
        engineQueue.sync {
            cfg = Self.makeConfigFromSettings()
            engine = JumpEngineV15(cfg)
            wireEngine()
            engine.reset()
            sampleCount = 0
            lastMotionT = 0
            lastBarometerT = nil
            lastRowAbsoluteT = nil
            hasDirectAbsoluteStream = false
            independentAltitudeBaseSensorT = nil
            independentAltitudeBaseReceivedT = nil
        }

        setLatestSpeed(0)
        setState(.idle)
        setState(.riding)

        let readiness = Self.readinessReport()
        logEvent("JumpDetector(v15) reset - ready=\(readiness.isReady) "
            + "minRise=\(cfg.minRiseM)m base=\(cfg.baselineWindowSec)s-median@yank "
            + "yank=\(cfg.yankOpenG)g quietStd=\(cfg.quietStdG)g impact=\(cfg.impactG)g "
            + "float>=\(cfg.minFloatFraction) floatFactor=\(cfg.floatFactor) "
            + "splashGuard=\(cfg.splashGuardSec)s absolute=continuousSingleConsumer "
            + "gps=metricsOnly \(readiness.logDetails)")
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
            self?.engine.addGPS(
                t: t,
                lat: latitude,
                lng: longitude,
                speedMS: speedMS,
                courseDeg: course
            )
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

            // Offline / legacy fallback: without a direct absolute stream the
            // ZOH snapshot held on the IMU rows is forwarded at its true
            // cadence (de-duplicated by the sample's own timestamp).
            if !self.hasDirectAbsoluteStream,
               let absolute = sample.absoluteAltitude, absolute.isFinite {
                let rowT = sample.absoluteAltitudeTimestamp ?? motionT
                if self.lastRowAbsoluteT.map({ rowT > $0 }) ?? true {
                    self.lastRowAbsoluteT = rowT
                    self.engine.addAbsoluteAltitude(
                        t: self.alignedToMotionClock(rowT, fallback: motionT),
                        altitudeM: absolute,
                        accuracyM: sample.absoluteAltitudeAccuracy
                    )
                }
            }

            self.engine.addIMU(t: motionT, verticalLoadG: verticalLoad, gyroRadS: gyro)
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
        _ = precisionM

        submitToEngine { [weak self] in
            guard let self else { return }
            self.hasDirectAbsoluteStream = true
            let t = self.alignedAbsoluteTimestamp(sensorT: sensorT, receivedT: receivedT)
            self.engine.addAbsoluteAltitude(t: t, altitudeM: altitudeM, accuracyM: accuracyM)
        }
    }

    func absoluteAltitudeStreamDidRestart(reason: String) {
        // V15 runs without watchdog restarts by design; if the acquisition
        // layer restarted anyway, log it — the engine's freeze/step hygiene
        // decides what the channel is worth.
        logEvent("v15 absoluteStreamRestart reason=\(reason) (engine unaffected)")
    }

    func endSession() -> [Jump] {
        var late: [Jump] = []
        engineQueue.sync {
            late = engine.flush(now: lastMotionT).map { makeJump(from: $0) }
        }
        logEvent("JumpDetector(v15) endSession flush lateJumps=\(late.count)")
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
    }

    private func handleDebug(t: TimeInterval, _ event: String) {
        if event.hasPrefix("CANDIDATE") {
            setState(.airborne)
        } else if event.hasPrefix("JUMP") || event.hasPrefix("REJECT") {
            setState(.riding)
        }
        logEvent("v15 \(event)")
        onDebugEvent?(t, event)
    }

    // MARK: - Sensor extraction

    /// Gravity-projected vertical load in g: userAcceleration·ĝ + |g|.
    /// ~1 at rest, ~0 in freefall, >1 under yank/impact compression. Samples
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
    /// channel at its true cadence.
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

    private func makeJump(from result: V15Jump) -> Jump {
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
        jump.absoluteTakeoffAltitude = result.baseAbsM
        jump.absoluteApexAltitude = result.peakAbsM
        jump.absoluteLandingAltitude = result.baseAbsM
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

extension JumpDetectorV15: JumpEngineV15Delegate {
    func jumpDetected(_ result: V15Jump) {
        let jump = makeJump(from: result)
        playHaptic(for: jump)
        SessionLogger.shared.logEvent(
            t: result.landingT,
            event: "JUMP(v15) FINAL h=\(jump.height)m src=\(result.heightSource.rawValue) "
                + "air=\(jump.airtime)s dist=\(jump.jumpDistance)m "
                + "hFit=\(result.heightApexFitM ?? -1) hRel=\(result.heightRelativeM ?? -1) "
                + "hBal=\(result.heightBallisticM) arcPts=\(result.arcPointCount) "
                + "yank=\(result.yankG)g impact=\(result.landingImpactG)g float=\(result.floatFraction) "
                + "rot=\(result.rotationTurns) hard=\(result.hardLanding) conf=\(jump.confidence) "
                + "latency=\(String(format: "%.1f", result.emittedAtT - result.landingT))s",
            state: "JUMP",
            speed: result.takeoffSpeedMS ?? latestSpeed()
        )
        onJumpDetected?(jump)
    }
}
