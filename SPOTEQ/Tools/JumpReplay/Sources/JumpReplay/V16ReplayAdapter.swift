// Dedicated command-line bridge for V16 log replay. The production Watch
// adapter stays in engine_v16/JumpDetectorV16.swift; this file contains no
// dependency on an older detector and imports only the V16 core package.

import Foundation
import V16Core

final class JumpDetectorV16: JumpDetecting, JumpEngineV16Delegate {
    var sessionId: String = "replay-v16"
    var synchronousAnalysis = true
    var onJumpDetected: ((Jump) -> Void)?
    var onStateChanged: ((JumpDetector.JumpState) -> Void)?
    var onDebugEvent: ((TimeInterval, String) -> Void)?

    private var configuration = V16Config()
    private var engine: JumpEngineV16
    private var lastMotionT = 0.0
    private var wallMinusMotion: TimeInterval?
    private var collectingFlush = false
    private var flushed: [Jump] = []

    init() {
        engine = JumpEngineV16(configuration)
        wireEngine()
    }

    var effectiveConfiguration: V16Config { configuration }
    var engineVersion: String { "v\(JumpEngineV16.version)" }

    func reset(mode: DetectionMode) {
        _ = mode
        configuration = V16Config()
        engine = JumpEngineV16(configuration)
        lastMotionT = 0
        wallMinusMotion = nil
        collectingFlush = false
        flushed.removeAll(keepingCapacity: true)
        wireEngine()
        onStateChanged?(.riding)
    }

    func updateGPS(speed: Double,
                   altitude: Double,
                   latitude: Double,
                   longitude: Double,
                   course: Double,
                   horizontalAccuracy: Double?,
                   timestamp: Date) {
        _ = (altitude, course, horizontalAccuracy)
        let t = timestamp.timeIntervalSince1970 - (wallMinusMotion ?? 0)
        engine.addGPS(t: t, lat: latitude, lng: longitude, speedMS: speed)
    }

    func processSample(_ sample: IMUSample) {
        let t = sample.motionTimestamp ?? sample.timestamp.timeIntervalSince1970
        if wallMinusMotion == nil {
            wallMinusMotion = sample.timestamp.timeIntervalSince1970 - t
        }
        lastMotionT = t
        let q = sample.attitudeQuaternion.map { ($0.w, $0.x, $0.y, $0.z) }
        engine.addIMU(
            t: t,
            loadG: sample.accelerationMagnitude,
            gyroRadS: sample.rotationMagnitude,
            accel: (sample.accelerationX, sample.accelerationY, sample.accelerationZ),
            quat: q
        )
    }

    func endSession() -> [Jump] {
        collectingFlush = true
        flushed.removeAll(keepingCapacity: true)
        engine.flush(now: lastMotionT)
        collectingFlush = false
        let result = flushed
        flushed.removeAll(keepingCapacity: true)
        return result
    }

    func jumpDetected(_ result: V16Jump) {
        // Unresolved airtime is encoded as 0 / endTime == startTime, exactly as
        // JumpDetectorV16.makeJump does on the watch — replay must not invent a
        // landing the engine never found. `airtimeConfidence` below carries
        // "unresolved" and is the field to branch on.
        let airtime = result.airtimeSec ?? 0
        var jump = Jump(sessionId: sessionId, startTime: date(for: result.takeoffT))
        jump.endTime = date(for: result.takeoffT + airtime)
        jump.height = result.heightM
        jump.airtime = airtime
        jump.apexTime = result.airtimeSec.map { $0 / 2 }
        jump.jumpDistance = result.distanceM ?? 0
        jump.confidence = result.confidence * 100
        // Per-jump, as on the watch: "flight" is the 16.2 metre measurement,
        // "freefall" a ballistic event, "matched" the 16.1 calibrated fallback
        // taken when the landing never resolved.
        jump.heightSource = "v16-imu-\(result.heightSource.rawValue)"
        jump.takeoffSpeed = result.takeoffSpeedMS
        jump.detectionConfidence = result.confidence * 100
        jump.matchedFilterApexRawM = result.apexRawM
        jump.liftPlateauDurationSec = result.liftPlateauSec
        jump.airtimeConfidence = result.airtimeSec == nil ? "unresolved" : "low"
        jump.distanceConfidence = result.distanceM == nil ? "unresolved" : "low"
        jump.takeoffGroundSpeed = result.takeoffSpeedMS
        // Same optional-in, optional-out contract as the watch adapter.
        jump.landingLatitude = result.landLat
        jump.landingLongitude = result.landLng
        jump.apexLatitude = result.apexLat
        jump.apexLongitude = result.apexLng
        jump.riseFraction = result.riseFraction
        jump.takeoffYankG = result.yankG
        jump.landingImpactG = result.landingImpactG
        jump.rotationRevs = result.rotationRevs
        jump.edgeLoadG = result.edgeLoadG

        if collectingFlush {
            flushed.append(jump)
        } else {
            onJumpDetected?(jump)
        }
    }

    private func wireEngine() {
        engine.delegate = self
        engine.onDebug = { [weak self] t, message in
            self?.onDebugEvent?(t, message)
            if message.hasPrefix("POP") {
                self?.onStateChanged?(.airborne)
            } else if message.hasPrefix("REJECT") || message.hasPrefix("JUMP") {
                self?.onStateChanged?(.riding)
            }
        }
    }

    private func date(for t: TimeInterval) -> Date {
        Date(timeIntervalSince1970: (wallMinusMotion ?? 0) + t)
    }
}
