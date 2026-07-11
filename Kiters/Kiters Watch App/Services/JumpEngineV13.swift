//
//  JumpEngineV13.swift
//  Kiters Watch App
//
//  V13 simple absolute-altitude jump engine.
//
//  Design:
//  - No IMU gate. IMU is optional metrics only.
//  - Keeps a rolling altitude history so jumps can be reconstructed after
//    landing even when several peaks happen before the baseline is stable.
//  - Jump condition is absolute-altitude rise over a short window:
//      1.0 m -> 1.0 s, 1.5 m -> 1.5 s, 2.0 m -> 2.0 s.
//  - Height is max absolute altitude after the jump condition minus the stable
//    landing baseline measured over the landing window. When the landing window
//    is choppy, V13 still emits the jump and lowers confidence instead of
//    rejecting it.
//  - Airtime is jump-condition time to landing-return time.
//  - GPS speed/distance are GPS-derived and can be used as configurable gates.
//

import Foundation

// MARK: - Config

public struct V13Config {
    // Primary field setting: 1.0 / 1.5 / 2.0 m. The takeoff window duration
    // is derived from this value in seconds.
    public var minRiseM = 1.0

    // GPS-derived optional gates. Defaults keep the detector usable while field
    // thresholds are being tuned; set > 0 to require GPS speed/distance.
    public var minGpsSpeedMS = 0.0
    public var minGpsDistanceM = 0.0

    // Landing: the user-requested stable 2 s window.
    public var landingStableSec = 2.0
    public var landingStableDeltaM = 0.25
    public var landingStableRangeM = 0.6
    public var landingReturnBandM = 0.75

    // Bounds applied only after the altitude jump/landing sequence is complete.
    public var minAirtimeSec = 0.2
    public var maxAirtimeSec = 12.0
    public var maxFlightSec = 20.0
    public var maxJumpHeightM = 30.0

    // Compatibility/tuning fields kept for existing settings UI and callers.
    // They are not takeoff gates in V13 simple mode.
    public var bufferSec = 60.0
    public var triggerAccelG = 1.8
    public var triggerGyroRadS = 4.0
    public var armOnAltitudeRiseM = 0.8
    public var preTriggerLeadSec = 0.0
    public var emptyCandidateCloseSec = 0.0
    public var retriggerGuardSec = 0.8
    public var takeoffWindowSlackSec = 0.15
    public var baselineWindowSec = 0.0
    public var baselineGapSec = 0.0
    public var postLandingGapSec = 0.0
    public var postBaselineWindowSec = 2.0
    public var maxBaselineDriftM = 2.0
    public var spikeToleranceM = 0.0
    public var peakNeighborhoodSec = 0.0
    public var minArcSamples = 1
    public var landingImpactG = 1.9
    public var crossingBandM = 0.0
    public var maxResultDelaySec = 2.5
    public var gpsMatchToleranceSec = 2.5

    public init() {}
}

// MARK: - Output

public enum V13TriggerSource: String {
    case imu
    case altitude
}

public struct V13ProfilePoint {
    public let tOffsetSec: Double
    public let relHeightM: Double
}

public struct V13Jump {
    public let heightM: Double
    public let airtimeSec: Double
    public let takeoffT: TimeInterval
    public let landingT: TimeInterval
    public let apexT: TimeInterval

    public let peakAltitudeM: Double
    public let baselinePreM: Double
    public let baselinePostM: Double?
    public let baselineRefM: Double
    public let baselineShifted: Bool
    public let driftSuspect: Bool

    public let maxAscentRateMS: Double
    public let maxDescentRateMS: Double

    public let takeoffG: Double
    public let landingG: Double
    public let peakG: Double
    public let prePopImpulseG: Double
    public let maxRotationRadS: Double
    public let rotationTurns: Double
    public let impactEnergy: Double

    public let takeoffSpeedMS: Double?
    public let landingSpeedMS: Double?
    public let distanceM: Double?
    public let launchLat: Double?
    public let launchLng: Double?
    public let landingLat: Double?
    public let landingLng: Double?

    public let altitudePointCount: Int
    public let confidence: Double
    public let triggerSource: V13TriggerSource
    public let emittedAtT: TimeInterval
    public let profile: [V13ProfilePoint]
}

public protocol JumpEngineV13Delegate: AnyObject {
    func jumpDetected(_ jump: V13Jump)
}

// MARK: - Engine

public final class JumpEngineV13 {
    public weak var delegate: JumpEngineV13Delegate?
    public var onDebug: (TimeInterval, String) -> Void = { _, _ in }

    private let cfg: V13Config

    private struct AltPt {
        let t: TimeInterval
        let alt: Double
    }

    private struct ImuPt {
        let t: TimeInterval
        let accelG: Double
        let gyroRadS: Double
    }

    private struct GpsPt {
        let t: TimeInterval
        let lat: Double
        let lng: Double
        let spd: Double
    }

    private struct ActiveJump {
        let takeoffT: TimeInterval
        let baselineAlt: Double
        let launchGPS: GpsPt?

        var maxAlt: Double
        var apexT: TimeInterval
        var previousAlt: AltPt
        var landingWindow: [AltPt]
        var altitudePointCount: Int
        var maxAscentRate: Double
        var maxDescentRate: Double

        var takeoffG: Double
        var landingG: Double
        var peakG: Double
        var maxGyro: Double
        var rotationIntegral: Double
        var impactEnergy: Double
        var previousIMU: ImuPt?
    }

    private enum Phase {
        case idle
        case airborne(ActiveJump)
    }

    private var phase: Phase = .idle
    private var takeoffWindow: [AltPt] = []
    private var latestGPS: GpsPt?
    private var lastAltT = -Double.infinity
    private var lastImuT = -Double.infinity
    private var lastGpsT = -Double.infinity
    private var lastLandedT = -Double.infinity
    private var altitudeHistory: [AltPt] = []
    private var emittedPeakTimes: [TimeInterval] = []

    public init(_ cfg: V13Config = V13Config()) {
        self.cfg = cfg
    }

    public func reset() {
        phase = .idle
        takeoffWindow.removeAll(keepingCapacity: true)
        latestGPS = nil
        lastAltT = -Double.infinity
        lastImuT = -Double.infinity
        lastGpsT = -Double.infinity
        lastLandedT = -Double.infinity
        altitudeHistory.removeAll(keepingCapacity: true)
        emittedPeakTimes.removeAll(keepingCapacity: true)
    }

    // MARK: Inputs

    public func addAltitude(t: TimeInterval, altitudeM: Double) {
        guard t.isFinite, altitudeM.isFinite, t > lastAltT else { return }
        lastAltT = t
        let p = AltPt(t: t, alt: altitudeM)
        altitudeHistory.append(p)
        prune(&altitudeHistory, before: p.t - cfg.bufferSec)
        pruneEmittedPeaks(now: p.t)

        switch phase {
        case .idle:
            ingestIdleAltitude(p)

        case .airborne(var jump):
            ingestAirborneAltitude(p, jump: &jump)
        }

        scanBufferedAltitude(now: p.t)
    }

    public func addIMU(t: TimeInterval, accelG: Double, gyroRadS: Double) {
        guard t.isFinite, accelG.isFinite, gyroRadS.isFinite, t > lastImuT else { return }
        lastImuT = t

        guard case .airborne(var jump) = phase else { return }
        let p = ImuPt(t: t, accelG: max(0, accelG), gyroRadS: max(0, gyroRadS))

        if t - jump.takeoffT <= 0.6 {
            jump.takeoffG = max(jump.takeoffG, p.accelG)
        }
        jump.peakG = max(jump.peakG, p.accelG)
        jump.maxGyro = max(jump.maxGyro, p.gyroRadS)

        if let prev = jump.previousIMU, p.t > prev.t {
            let dt = p.t - prev.t
            jump.rotationIntegral += p.gyroRadS * dt
            if p.accelG >= cfg.landingImpactG {
                let over = max(0, p.accelG - 1.0)
                jump.impactEnergy += over * over * dt
            }
        }
        jump.previousIMU = p
        phase = .airborne(jump)
    }

    public func addGPS(t: TimeInterval, lat: Double, lng: Double, speedMS: Double) {
        guard t.isFinite, t > lastGpsT else { return }
        lastGpsT = t
        latestGPS = GpsPt(t: t, lat: lat, lng: lng, spd: max(0, speedMS))
    }

    public func addSubmersion(t: TimeInterval, submerged: Bool) {
        // V13 simple mode intentionally does not use water/IMU as a condition.
        _ = (t, submerged)
    }

    public func flush(now: TimeInterval) -> [V13Jump] {
        let emittedAt = max(now, lastAltT)
        scanBufferedAltitude(now: emittedAt)

        guard case .airborne(let jump) = phase else { return [] }
        phase = .idle
        takeoffWindow.removeAll(keepingCapacity: true)

        if let stable = stableLanding(from: jump.landingWindow),
           let result = makeJump(from: jump, stable: stable, emittedAt: emittedAt, reason: "flush"),
           markPeakIfNew(result.apexT) {
            return [result]
        }

        onDebug(emittedAt, "REJECT reason=sessionEndedBeforeStableLanding")
        return []
    }

    // MARK: Idle / takeoff

    private var takeoffWindowSec: Double {
        max(0.5, cfg.minRiseM)
    }

    private func ingestIdleAltitude(_ p: AltPt) {
        takeoffWindow.append(p)
        prune(&takeoffWindow, before: p.t - takeoffWindowSec - cfg.takeoffWindowSlackSec)

        guard p.t - lastLandedT >= cfg.retriggerGuardSec else { return }

        guard let first = takeoffWindow.first, p.t - first.t >= takeoffWindowSec * 0.8 else { return }

        let rise = p.alt - first.alt
        guard rise >= cfg.minRiseM else { return }

        beginJump(
            triggerT: first.t,
            baselineAlt: first.alt,
            triggerAlt: p.alt,
            launchGPS: latestGPS,
            altitudePointCount: takeoffWindow.count,
            maxAscentRate: ascentRate(in: takeoffWindow),
            triggerPoint: p
        )
    }

    private func beginJump(triggerT: TimeInterval,
                           baselineAlt: Double,
                           triggerAlt: Double,
                           launchGPS: GpsPt?,
                           altitudePointCount: Int,
                           maxAscentRate: Double,
                           triggerPoint p: AltPt) {
        let jump = ActiveJump(
            takeoffT: triggerT,
            baselineAlt: baselineAlt,
            launchGPS: launchGPS,
            maxAlt: triggerAlt,
            apexT: p.t,
            previousAlt: p,
            landingWindow: [],
            altitudePointCount: altitudePointCount,
            maxAscentRate: maxAscentRate,
            maxDescentRate: 0,
            takeoffG: 0,
            landingG: 0,
            peakG: 0,
            maxGyro: 0,
            rotationIntegral: 0,
            impactEnergy: 0,
            previousIMU: nil
        )

        phase = .airborne(jump)
        onDebug(p.t, "CANDIDATE altitude rise=\(fmt(triggerAlt - baselineAlt))m baseline=\(fmt(baselineAlt))")
        takeoffWindow.removeAll(keepingCapacity: true)
    }

    // MARK: Airborne / landing

    private func ingestAirborneAltitude(_ p: AltPt, jump: inout ActiveJump) {
        updateRates(with: p, jump: &jump)
        jump.altitudePointCount += 1

        if p.alt > jump.maxAlt {
            jump.maxAlt = p.alt
            jump.apexT = p.t
            jump.landingWindow.removeAll(keepingCapacity: true)
        } else {
            let descendedFromPeak = jump.maxAlt - p.alt >= max(0.25, cfg.minRiseM * 0.5)
            if descendedFromPeak {
                jump.landingWindow.append(p)
                prune(&jump.landingWindow, before: p.t - cfg.landingStableSec)
            } else {
                jump.landingWindow.removeAll(keepingCapacity: true)
            }
        }

        if p.t - jump.takeoffT > cfg.maxFlightSec {
            onDebug(p.t, "REJECT reason=maxFlightExceeded air=\(fmt(p.t - jump.takeoffT))")
            phase = .idle
            takeoffWindow = [p]
            return
        }

        if let stable = stableLanding(from: jump.landingWindow) {
            if let result = makeJump(from: jump, stable: stable, emittedAt: p.t, reason: "stableLanding") {
                if markPeakIfNew(result.apexT) {
                    delegate?.jumpDetected(result)
                    onDebug(p.t, "JUMP h=\(result.heightM)m air=\(result.airtimeSec)s baseline=\(result.baselinePostM ?? result.baselinePreM) latency=\(fmt(result.emittedAtT - result.landingT))s")
                }
            }
            lastLandedT = stable.landingT
            phase = .idle
            takeoffWindow = jump.landingWindow
            return
        }

        phase = .airborne(jump)
    }

    // MARK: Buffered altitude reconstruction

    private func scanBufferedAltitude(now: TimeInterval, allowOpenTail: Bool = false) {
        guard altitudeHistory.count >= 4 else { return }

        let lookbackSec = takeoffWindowSec + cfg.takeoffWindowSlackSec
        let minTakeoffDt = max(0.25, takeoffWindowSec * 0.45)
        let minDescentM = max(0.35, cfg.minRiseM * 0.45)
        let postWindowSec = max(0.5, cfg.landingStableSec)

        for peakIdx in 1..<(altitudeHistory.count - 1) {
            let peak = altitudeHistory[peakIdx]
            guard peak.t <= now else { continue }
            guard !isPeakAlreadyEmitted(peak.t) else { continue }
            guard isBufferedLocalPeak(at: peakIdx) else { continue }
            guard allowOpenTail || now - peak.t >= min(0.8, postWindowSec) else { continue }

            guard let takeoffIdx = bufferedTakeoffIndex(
                beforePeakAt: peakIdx,
                lookbackSec: lookbackSec,
                minTakeoffDt: minTakeoffDt
            ) else { continue }

            let takeoff = altitudeHistory[takeoffIdx]
            guard peak.alt - takeoff.alt >= cfg.minRiseM else { continue }

            let stableLandingIdx = bufferedStableLandingIndex(
                afterPeakAt: peakIdx,
                baseline: takeoff,
                peak: peak,
                minDescentM: minDescentM,
                postWindowSec: postWindowSec
            )
            guard let fallbackLandingIdx = bufferedLandingIndex(
                afterPeakAt: peakIdx,
                baseline: takeoff,
                peak: peak,
                minDescentM: minDescentM
            ) else { continue }

            let landingIdx: Int
            if let stableLandingIdx {
                landingIdx = stableLandingIdx
            } else {
                let fallbackLanding = altitudeHistory[fallbackLandingIdx]
                guard allowOpenTail || now + 0.05 >= fallbackLanding.t + postWindowSec + cfg.maxResultDelaySec else { continue }
                landingIdx = fallbackLandingIdx
            }

            let landing = altitudeHistory[landingIdx]
            guard allowOpenTail || now + 0.05 >= landing.t + postWindowSec else { continue }

            let postEnd = min(now, landing.t + postWindowSec)
            let postWindow = altitudeHistory.filter { $0.t >= landing.t && $0.t <= postEnd }
            let stable = relaxedLanding(from: postWindow, fallback: landing)

            guard let result = makeBufferedJump(
                takeoffIdx: takeoffIdx,
                peakIdx: peakIdx,
                landingIdx: landingIdx,
                stable: stable,
                emittedAt: now
            ) else { continue }

            guard markPeakIfNew(result.apexT) else { continue }
            delegate?.jumpDetected(result)
            lastLandedT = max(lastLandedT, result.landingT)
            onDebug(now, "JUMP(buffered) h=\(result.heightM)m air=\(result.airtimeSec)s stable=\(stable.isStable) baseline=\(result.baselineRefM)")
        }
    }

    private func isBufferedLocalPeak(at idx: Int) -> Bool {
        guard idx > 0, idx + 1 < altitudeHistory.count else { return false }
        let p = altitudeHistory[idx]
        return p.alt >= altitudeHistory[idx - 1].alt && p.alt >= altitudeHistory[idx + 1].alt
    }

    private func bufferedTakeoffIndex(beforePeakAt peakIdx: Int,
                                      lookbackSec: Double,
                                      minTakeoffDt: Double) -> Int? {
        let peak = altitudeHistory[peakIdx]
        let candidates = (0..<peakIdx).filter { idx in
            let dt = peak.t - altitudeHistory[idx].t
            return dt >= minTakeoffDt && dt <= lookbackSec
        }

        let qualifying = candidates.filter { peak.alt - altitudeHistory[$0].alt >= cfg.minRiseM }
        return qualifying.min(by: { altitudeHistory[$0].alt < altitudeHistory[$1].alt })
    }

    private func bufferedLandingIndex(afterPeakAt peakIdx: Int,
                                      baseline: AltPt,
                                      peak: AltPt,
                                      minDescentM: Double) -> Int? {
        guard peakIdx + 1 < altitudeHistory.count else { return nil }

        let returnAltitude = baseline.alt + cfg.landingReturnBandM
        var firstDescent: Int?
        for idx in (peakIdx + 1)..<altitudeHistory.count {
            let p = altitudeHistory[idx]
            if p.alt <= returnAltitude {
                return idx
            }
            if firstDescent == nil, peak.alt - p.alt >= minDescentM {
                firstDescent = idx
            }
        }
        return firstDescent
    }

    private func bufferedStableLandingIndex(afterPeakAt peakIdx: Int,
                                            baseline: AltPt,
                                            peak: AltPt,
                                            minDescentM: Double,
                                            postWindowSec: Double) -> Int? {
        guard peakIdx + 1 < altitudeHistory.count else { return nil }

        let returnAltitude = baseline.alt + cfg.landingReturnBandM
        for idx in (peakIdx + 1)..<altitudeHistory.count {
            let p = altitudeHistory[idx]
            let returnedToBase = p.alt <= returnAltitude
            let descendedEnough = peak.alt - p.alt >= minDescentM
            guard returnedToBase || descendedEnough else { continue }

            let endT = p.t + postWindowSec
            let window = altitudeHistory.filter { $0.t >= p.t && $0.t <= endT }
            guard let last = window.last, last.t - p.t + 0.05 >= postWindowSec else { continue }
            if relaxedLanding(from: window, fallback: p).isStable {
                return idx
            }
        }
        return nil
    }

    private func relaxedLanding(from window: [AltPt],
                                fallback: AltPt) -> (landingT: TimeInterval, baseline: Double, range: Double, isStable: Bool) {
        let points = window.isEmpty ? [fallback] : window
        let values = points.map(\.alt)
        let lo = values.min() ?? fallback.alt
        let hi = values.max() ?? fallback.alt
        let delta = abs((points.last ?? fallback).alt - (points.first ?? fallback).alt)
        let range = hi - lo
        let isStable = delta <= cfg.landingStableDeltaM && range <= cfg.landingStableRangeM
        return (fallback.t, average(values), range, isStable)
    }

    private func makeBufferedJump(takeoffIdx: Int,
                                  peakIdx: Int,
                                  landingIdx: Int,
                                  stable: (landingT: TimeInterval, baseline: Double, range: Double, isStable: Bool),
                                  emittedAt: TimeInterval) -> V13Jump? {
        let takeoff = altitudeHistory[takeoffIdx]
        let peak = altitudeHistory[peakIdx]
        let landing = altitudeHistory[landingIdx]
        let baselineShift = stable.baseline - takeoff.alt
        let baselineRef: Double
        if stable.isStable {
            baselineRef = stable.baseline
        } else if abs(baselineShift) <= cfg.maxBaselineDriftM {
            baselineRef = min(stable.baseline, takeoff.alt)
        } else {
            baselineRef = takeoff.alt
        }
        let rawHeight = peak.alt - baselineRef
        let height = min(rawHeight, cfg.maxJumpHeightM)
        let airtime = landing.t - takeoff.t
        let landingGPS = latestGPS
        let launchGPS = latestGPS
        let distance = gpsDistance(from: launchGPS, to: landingGPS, airtime: airtime)

        guard height >= cfg.minRiseM else {
            onDebug(emittedAt, "REJECT(buffered) reason=belowMinRise h=\(fmt(height)) min=\(fmt(cfg.minRiseM))")
            return nil
        }
        guard airtime >= cfg.minAirtimeSec, airtime <= cfg.maxAirtimeSec else {
            onDebug(emittedAt, "REJECT(buffered) reason=airtimeOutOfRange air=\(fmt(airtime))")
            return nil
        }
        if cfg.minGpsSpeedMS > 0 {
            guard let speed = launchGPS?.spd, speed >= cfg.minGpsSpeedMS else {
                onDebug(emittedAt, "REJECT(buffered) reason=gpsSpeed speed=\(fmt(launchGPS?.spd ?? -1)) min=\(fmt(cfg.minGpsSpeedMS))")
                return nil
            }
        }
        if cfg.minGpsDistanceM > 0 {
            guard let distance, distance >= cfg.minGpsDistanceM else {
                onDebug(emittedAt, "REJECT(buffered) reason=gpsDistance dist=\(fmt(distance ?? -1)) min=\(fmt(cfg.minGpsDistanceM))")
                return nil
            }
        }

        let segment = Array(altitudeHistory[takeoffIdx...landingIdx])
        let rates = altitudeRates(in: segment)
        let baselineShifted = abs(baselineShift) > cfg.landingReturnBandM
        let driftSuspect = abs(baselineShift) > cfg.maxBaselineDriftM

        var confidence = stable.isStable ? 0.72 : 0.58
        if height >= cfg.minRiseM + 0.5 { confidence += 0.08 }
        if launchGPS != nil { confidence += 0.08 }
        if distance != nil { confidence += 0.04 }
        if baselineShifted { confidence -= 0.06 }
        if driftSuspect { confidence -= 0.12 }
        confidence = min(max(confidence, 0.05), 1.0)

        return V13Jump(
            heightM: round2(height),
            airtimeSec: round2(airtime),
            takeoffT: takeoff.t,
            landingT: landing.t,
            apexT: peak.t,
            peakAltitudeM: round2(peak.alt),
            baselinePreM: round2(takeoff.alt),
            baselinePostM: round2(stable.baseline),
            baselineRefM: round2(baselineRef),
            baselineShifted: baselineShifted,
            driftSuspect: driftSuspect,
            maxAscentRateMS: round2(rates.ascent),
            maxDescentRateMS: round2(rates.descent),
            takeoffG: 0,
            landingG: 0,
            peakG: 0,
            prePopImpulseG: 0,
            maxRotationRadS: 0,
            rotationTurns: 0,
            impactEnergy: 0,
            takeoffSpeedMS: launchGPS.map { round2($0.spd) },
            landingSpeedMS: landingGPS.map { round2($0.spd) },
            distanceM: distance.map(round2),
            launchLat: coordinate(launchGPS?.lat, launchGPS?.lng)?.lat,
            launchLng: coordinate(launchGPS?.lat, launchGPS?.lng)?.lng,
            landingLat: coordinate(landingGPS?.lat, landingGPS?.lng)?.lat,
            landingLng: coordinate(landingGPS?.lat, landingGPS?.lng)?.lng,
            altitudePointCount: segment.count,
            confidence: confidence,
            triggerSource: .altitude,
            emittedAtT: emittedAt,
            profile: [
                V13ProfilePoint(tOffsetSec: 0, relHeightM: round2(takeoff.alt - baselineRef)),
                V13ProfilePoint(tOffsetSec: round2(peak.t - takeoff.t), relHeightM: round2(peak.alt - baselineRef)),
                V13ProfilePoint(tOffsetSec: round2(landing.t - takeoff.t), relHeightM: round2(landing.alt - baselineRef))
            ]
        )
    }

    private func stableLanding(from window: [AltPt]) -> (landingT: TimeInterval, baseline: Double, range: Double)? {
        guard let first = window.first, let last = window.last else { return nil }
        guard last.t - first.t + 0.05 >= cfg.landingStableSec else { return nil }

        let values = window.map(\.alt)
        guard let lo = values.min(), let hi = values.max() else { return nil }
        let delta = abs(last.alt - first.alt)
        let range = hi - lo
        guard delta <= cfg.landingStableDeltaM, range <= cfg.landingStableRangeM else { return nil }

        return (first.t, average(values), range)
    }

    private func makeJump(from jump: ActiveJump,
                          stable: (landingT: TimeInterval, baseline: Double, range: Double),
                          emittedAt: TimeInterval,
                          reason: String) -> V13Jump? {
        let rawHeight = jump.maxAlt - stable.baseline
        let height = min(rawHeight, cfg.maxJumpHeightM)
        let airtime = stable.landingT - jump.takeoffT
        let landingGPS = latestGPS
        let distance = gpsDistance(from: jump.launchGPS, to: landingGPS, airtime: airtime)

        guard height >= cfg.minRiseM else {
            onDebug(emittedAt, "REJECT reason=belowMinRise h=\(fmt(height)) min=\(fmt(cfg.minRiseM)) via=\(reason)")
            return nil
        }
        guard airtime >= cfg.minAirtimeSec, airtime <= cfg.maxAirtimeSec else {
            onDebug(emittedAt, "REJECT reason=airtimeOutOfRange air=\(fmt(airtime)) via=\(reason)")
            return nil
        }
        if cfg.minGpsSpeedMS > 0 {
            guard let speed = jump.launchGPS?.spd, speed >= cfg.minGpsSpeedMS else {
                onDebug(emittedAt, "REJECT reason=gpsSpeed speed=\(fmt(jump.launchGPS?.spd ?? -1)) min=\(fmt(cfg.minGpsSpeedMS))")
                return nil
            }
        }
        if cfg.minGpsDistanceM > 0 {
            guard let distance, distance >= cfg.minGpsDistanceM else {
                onDebug(emittedAt, "REJECT reason=gpsDistance dist=\(fmt(distance ?? -1)) min=\(fmt(cfg.minGpsDistanceM))")
                return nil
            }
        }

        let baselineShift = stable.baseline - jump.baselineAlt
        let baselineShifted = abs(baselineShift) > cfg.landingReturnBandM
        let driftSuspect = abs(baselineShift) > cfg.maxBaselineDriftM

        var confidence = 0.65
        if stable.range <= cfg.landingStableDeltaM { confidence += 0.1 }
        if jump.launchGPS != nil { confidence += 0.1 }
        if distance != nil { confidence += 0.05 }
        if driftSuspect { confidence -= 0.15 }
        confidence = min(max(confidence, 0.05), 1.0)

        return V13Jump(
            heightM: round2(height),
            airtimeSec: round2(airtime),
            takeoffT: jump.takeoffT,
            landingT: stable.landingT,
            apexT: jump.apexT,
            peakAltitudeM: round2(jump.maxAlt),
            baselinePreM: round2(jump.baselineAlt),
            baselinePostM: round2(stable.baseline),
            baselineRefM: round2(stable.baseline),
            baselineShifted: baselineShifted,
            driftSuspect: driftSuspect,
            maxAscentRateMS: round2(jump.maxAscentRate),
            maxDescentRateMS: round2(jump.maxDescentRate),
            takeoffG: round2(jump.takeoffG),
            landingG: round2(jump.landingG),
            peakG: round2(jump.peakG),
            prePopImpulseG: 0,
            maxRotationRadS: round2(jump.maxGyro),
            rotationTurns: round2(jump.rotationIntegral / (2 * .pi)),
            impactEnergy: round2(jump.impactEnergy),
            takeoffSpeedMS: jump.launchGPS.map { round2($0.spd) },
            landingSpeedMS: landingGPS.map { round2($0.spd) },
            distanceM: distance.map(round2),
            launchLat: coordinate(jump.launchGPS?.lat, jump.launchGPS?.lng)?.lat,
            launchLng: coordinate(jump.launchGPS?.lat, jump.launchGPS?.lng)?.lng,
            landingLat: coordinate(landingGPS?.lat, landingGPS?.lng)?.lat,
            landingLng: coordinate(landingGPS?.lat, landingGPS?.lng)?.lng,
            altitudePointCount: jump.altitudePointCount,
            confidence: confidence,
            triggerSource: .altitude,
            emittedAtT: emittedAt,
            profile: [
                V13ProfilePoint(tOffsetSec: 0, relHeightM: round2(jump.baselineAlt - stable.baseline)),
                V13ProfilePoint(tOffsetSec: round2(jump.apexT - jump.takeoffT), relHeightM: round2(jump.maxAlt - stable.baseline)),
                V13ProfilePoint(tOffsetSec: round2(stable.landingT - jump.takeoffT), relHeightM: 0)
            ]
        )
    }

    // MARK: Helpers

    private func updateRates(with p: AltPt, jump: inout ActiveJump) {
        let prev = jump.previousAlt
        if p.t > prev.t {
            let rate = (p.alt - prev.alt) / (p.t - prev.t)
            jump.maxAscentRate = max(jump.maxAscentRate, rate)
            jump.maxDescentRate = min(jump.maxDescentRate, rate)
        }
        jump.previousAlt = p
    }

    private func ascentRate(in points: [AltPt]) -> Double {
        guard points.count >= 2 else { return 0 }
        var best = 0.0
        for idx in 1..<points.count {
            let a = points[idx - 1]
            let b = points[idx]
            guard b.t > a.t else { continue }
            best = max(best, (b.alt - a.alt) / (b.t - a.t))
        }
        return best
    }

    private func altitudeRates(in points: [AltPt]) -> (ascent: Double, descent: Double) {
        guard points.count >= 2 else { return (0, 0) }
        var ascent = 0.0
        var descent = 0.0
        for idx in 1..<points.count {
            let a = points[idx - 1]
            let b = points[idx]
            guard b.t > a.t else { continue }
            let rate = (b.alt - a.alt) / (b.t - a.t)
            ascent = max(ascent, rate)
            descent = min(descent, rate)
        }
        return (ascent, descent)
    }

    private func prune(_ points: inout [AltPt], before cutoff: TimeInterval) {
        while let first = points.first, first.t < cutoff {
            points.removeFirst()
        }
    }

    private func pruneEmittedPeaks(now: TimeInterval) {
        emittedPeakTimes.removeAll { now - $0 > cfg.bufferSec }
    }

    private func isPeakAlreadyEmitted(_ peakT: TimeInterval) -> Bool {
        let minSeparation = max(2.0, cfg.retriggerGuardSec)
        return emittedPeakTimes.contains { abs($0 - peakT) < minSeparation }
    }

    private func markPeakIfNew(_ peakT: TimeInterval) -> Bool {
        guard !isPeakAlreadyEmitted(peakT) else { return false }
        emittedPeakTimes.append(peakT)
        return true
    }

    private func gpsDistance(from a: GpsPt?, to b: GpsPt?, airtime: Double) -> Double? {
        if let a, let b, coordinate(a.lat, a.lng) != nil, coordinate(b.lat, b.lng) != nil {
            return haversineM(a.lat, a.lng, b.lat, b.lng)
        }
        if let a {
            return a.spd * airtime
        }
        return nil
    }

    private func coordinate(_ lat: Double?, _ lng: Double?) -> (lat: Double, lng: Double)? {
        guard let lat, let lng, lat != 0 || lng != 0 else { return nil }
        return (lat, lng)
    }

    private func haversineM(_ lat1: Double, _ lng1: Double, _ lat2: Double, _ lng2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
        return 2 * r * asin(min(1, h.squareRoot()))
    }

    private func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    private func round2(_ v: Double) -> Double {
        (v * 100).rounded() / 100
    }

    private func fmt(_ v: Double) -> String {
        String(format: "%.2f", v)
    }
}
