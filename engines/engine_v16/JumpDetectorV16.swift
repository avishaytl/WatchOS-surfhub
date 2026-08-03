//
//  JumpDetectorV16.swift
//  Kiters Watch App
//
//  The only bridge between the app sensor contract and JumpEngineV16.
//  V16 deliberately consumes only user acceleration, attitude, gyro and GPS
//  metrics. It has no dependency on a previous jump engine or its settings.
//

import Foundation
import CoreMotion
#if canImport(WatchKit)
import WatchKit
#endif

struct V16Readiness {
    let isReady: Bool
    let userFacingReason: String
    let logDetails: String
}

final class JumpDetectorV16: JumpDetecting {
    var sessionId: String = ""
    var synchronousAnalysis = false
    var onJumpDetected: ((Jump) -> Void)?
    var onStateChanged: ((JumpDetector.JumpState) -> Void)?
    var onDebugEvent: ((TimeInterval, String) -> Void)?

    private var configuration = V16Config()
    private var engine: JumpEngineV16
    private let engineQueue = DispatchQueue(label: "com.kiters.jumpV16.engine", qos: .userInitiated)
    private let stateLock = NSLock()
    private let speedLock = NSLock()

    private var state: JumpDetector.JumpState = .idle
    private var latestSpeedMS = 0.0
    private var lastMotionT = 0.0
    private var missingQuaternionSamples = 0
    private var isCollectingFlush = false
    private var flushedJumps: [Jump] = []

    private let bootWallClock = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime

    init() {
        engine = JumpEngineV16(configuration)
        wireEngine()
    }

    var effectiveConfiguration: V16Config {
        engineQueue.sync { configuration }
    }

    static func readinessReport() -> V16Readiness {
        #if os(watchOS)
        let motionAvailable = CMMotionManager().isDeviceMotionAvailable
        return V16Readiness(
            isReady: motionAvailable,
            userFacingReason: motionAvailable
                ? "V16 is ready"
                : "Device Motion with attitude quaternion is unavailable",
            logDetails: "deviceMotion=\(motionAvailable ? "available" : "unavailable"); "
                + "required=userAcceleration+attitudeQuaternion; barometer=unused; gps=metricsOnly"
        )
        #else
        return V16Readiness(
            isReady: true,
            userFacingReason: "Offline replay readiness accepted",
            logDetails: "offlineReplay=true; required=userAcceleration+attitudeQuaternion"
        )
        #endif
    }

    func reset(mode: DetectionMode) {
        _ = mode // V16 is calibrated as one fixed operating point.
        engineQueue.sync {
            configuration = V16Config()
            engine = JumpEngineV16(configuration)
            wireEngine()
            lastMotionT = 0
            missingQuaternionSamples = 0
            isCollectingFlush = false
            flushedJumps.removeAll(keepingCapacity: true)
        }
        setLatestSpeed(0)
        setState(.idle)
        setState(.riding)

        let readiness = Self.readinessReport()
        logEvent(
            "JumpDetector(v16) reset ready=\(readiness.isReady) "
                + "pop=\(configuration.popMinG)g shelf>=\(configuration.minLiftPlateauSec)s "
                + "lift>\(configuration.liftThreshMS2)m/s2 "
                + "apex=[-\(configuration.apexPreSec),+\(configuration.apexPostSec)]s "
                + "height=\(configuration.heightScale)*raw+\(configuration.heightOffsetM)m "
                + "minReport=\(configuration.minReportM)m barometer=unused gps=metricsOnly "
                + readiness.logDetails
        )
    }

    func updateGPS(speed: Double,
                   altitude: Double,
                   latitude: Double,
                   longitude: Double,
                   course: Double = -1,
                   horizontalAccuracy: Double? = nil,
                   timestamp: Date) {
        _ = (altitude, course, horizontalAccuracy)
        let speedMS = max(0, speed)
        setLatestSpeed(speedMS)
        let t = monotonicTime(from: timestamp)
        submitToEngine { [weak self] in
            self?.engine.addGPS(t: t, lat: latitude, lng: longitude, speedMS: speedMS)
        }
    }

    func processSample(_ sample: IMUSample) {
        let motionT = sample.motionTimestamp ?? monotonicTime(from: sample.timestamp)
        let quaternion = sample.attitudeQuaternion.map { ($0.w, $0.x, $0.y, $0.z) }
        let acceleration = (sample.accelerationX, sample.accelerationY, sample.accelerationZ)
        let loadG = sample.accelerationMagnitude
        let gyro = sample.rotationMagnitude

        submitToEngine { [weak self] in
            guard let self else { return }
            self.lastMotionT = motionT
            if quaternion == nil {
                self.missingQuaternionSamples += 1
                if self.missingQuaternionSamples == 1 {
                    self.handleDebug(
                        t: motionT,
                        "WARNING missingQuaternion; V16 will stay silent until attitude returns"
                    )
                }
            }
            self.engine.addIMU(
                t: motionT,
                loadG: loadG,
                gyroRadS: gyro,
                accel: acceleration,
                quat: quaternion
            )
        }
    }

    func endSession() -> [Jump] {
        var late: [Jump] = []
        engineQueue.sync {
            isCollectingFlush = true
            flushedJumps.removeAll(keepingCapacity: true)
            engine.flush(now: lastMotionT)
            late = flushedJumps
            flushedJumps.removeAll(keepingCapacity: true)
            isCollectingFlush = false
        }
        logEvent("JumpDetector(v16) endSession flush lateJumps=\(late.count)")
        return late
    }

    private func submitToEngine(_ work: @escaping () -> Void) {
        if synchronousAnalysis {
            engineQueue.sync(execute: work)
        } else {
            engineQueue.async(execute: work)
        }
    }

    private func wireEngine() {
        engine.delegate = self
        engine.onDebug = { [weak self] t, message in
            self?.handleDebug(t: t, message)
        }
    }

    private func handleDebug(t: TimeInterval, _ message: String) {
        if message.hasPrefix("POP") {
            setState(.airborne)
        } else if message.hasPrefix("REJECT") || message.hasPrefix("JUMP") {
            setState(.riding)
        }
        logEvent("v16 \(message)")
        onDebugEvent?(t, message)
    }

    private func makeJump(from result: V16Jump) -> Jump {
        var jump = Jump(sessionId: sessionId, startTime: wallDate(from: result.takeoffT))
        let endOffset = result.airtimeSec ?? configuration.apexPostSec
        jump.endTime = wallDate(from: result.takeoffT + endOffset)
        jump.height = result.heightM
        jump.airtime = result.airtimeSec ?? 0
        jump.jumpDistance = result.distanceM ?? 0
        jump.rotations = 0
        jump.confidence = result.confidence * 100
        jump.heightSource = "v16-imu-matched-filter"
        jump.takeoffSpeed = result.takeoffSpeedMS
        jump.detectionConfidence = result.confidence * 100
        jump.matchedFilterApexRawM = result.apexRawM
        jump.liftPlateauDurationSec = result.liftPlateauSec
        jump.airtimeConfidence = result.airtimeSec == nil ? "unresolved" : "low"
        jump.takeoffGroundSpeed = result.takeoffSpeedMS
        return jump
    }

    private func deliver(_ result: V16Jump) {
        let jump = makeJump(from: result)
        let airtimeText = result.airtimeSec.map { String(format: "%.2f", $0) } ?? "n/a"
        let distanceText = result.distanceM.map { String(format: "%.2f", $0) } ?? "n/a"
        let event = [
            "JUMP(v16) FINAL h=\(jump.height)m rawApex=\(result.apexRawM)m",
            "shelf=\(result.liftPlateauSec)s air=\(airtimeText)s airConfidence=low",
            "dist=\(distanceText)m yank=\(result.yankG)g peak=\(result.peakG)g",
            "float=\(result.floatFraction) gyro=\(result.maxGyroRadS)rad/s",
            "conf=\(jump.confidence) barometer=unused gpsGate=none",
        ].joined(separator: " ")
        SessionLogger.shared.logEvent(
            t: result.takeoffT + (result.airtimeSec ?? configuration.apexPostSec),
            event: event,
            state: "JUMP",
            speed: result.takeoffSpeedMS ?? latestSpeed()
        )

        if isCollectingFlush {
            flushedJumps.append(jump)
            return
        }
        playHaptic(for: jump)
        onJumpDetected?(jump)
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

    private func playHaptic(for jump: Jump) {
        #if os(watchOS)
        let enabled = UserDefaults.standard.object(forKey: "hapticFeedback") as? Bool ?? true
        if enabled {
            WKInterfaceDevice.current().play(jump.confidence >= 75 ? .success : .notification)
        }
        #endif
    }

    private func logEvent(_ message: @autoclosure () -> String) {
        let value = message()
        #if DEBUG
        print("🪁 \(value)")
        #endif
        SessionLogger.shared.logEvent(value)
    }
}

extension JumpDetectorV16: JumpEngineV16Delegate {
    func jumpDetected(_ jump: V16Jump) {
        deliver(jump)
    }
}
