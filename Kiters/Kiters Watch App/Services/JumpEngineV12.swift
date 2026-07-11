//
//  JumpEngineV12.swift
//  Kiters Watch App
//
//  Pure V12 Apple Sensor Fusion jump pipeline. It consumes timestamped accel,
//  barometer, GPS and optional submersion frames, then emits an instant jump at
//  landing plus a later drift-checked refinement.
//

import Foundation

// MARK: - Config

public struct V12Config {
    public var yankG = 2.2
    public var crashG = 6.0
    public var landImpactG = 2.0
    public var absoluteTakeoffRiseM = 0.25
    public var landingReturnToleranceM = 0.35
    public var chopWinSec = 0.3
    public var chopResumeFrac = 0.8
    public var chopResumeHoldSec = 0.3
    public var minAirSec = 0.3
    public var maxAirSec = 8.0
    public var planingSpeedMs = 0.56
    public var planingWinSec = 5.0
    public var anchorSamples = 4
    public var anchorMaxAgeSec = 8.0
    public var minJumpHeightM = 1.0
    public var maxJumpHeightM = 12.0
    public var refineDelaySec = 3.0
    public var rtzCorrectM = 0.25
    public var crashCooldownSec = 30.0
    public var anchorMinSamples = 1

    public var requirePlaning = false
    public var requireBaroAnchor = false
    public var enforceCrashCooldown = false
    public var abortOnMidArcCrash = false
    public var requireLandingBaroConfirmation = false
    public var enforceMinJumpHeight = true
    public var retractOnRefineReject = false

    public init() {}
}

// MARK: - Output

public struct V12Jump {
    public let heightM: Double
    public let airtimeSec: Double
    public let distanceM: Double?
    public let takeoffAltitudeM: Double
    public let apexAltitudeM: Double
    public let landingAltitudeM: Double?
    public let takeoffSpeedMS: Double?
    public let landingSpeedMS: Double?
    public let takeoffT: TimeInterval
    public let landingT: TimeInterval
    public let apexT: TimeInterval
    public let confidence: Double
    public let arcBaroPoints: Int
    public let refined: Bool
    public let driftSuspect: Bool
    public let rtzM: Double?
}

public protocol JumpPipelineV12Delegate: AnyObject {
    func jumpDetected(_ jump: V12Jump)
    func jumpRefined(_ jump: V12Jump)
}

// MARK: - Pipeline

public final class JumpPipelineV12 {
    public weak var delegate: JumpPipelineV12Delegate?
    public var onDebug: (TimeInterval, String) -> Void = { _, _ in }

    private let cfg: V12Config

    private struct BaroPt { let t: TimeInterval; let alt: Double }
    private struct LocPt { let t: TimeInterval; let lat: Double; let lng: Double; let spd: Double }
    private struct AccPt { let t: TimeInterval; let a: Double }
    private enum State { case idle, airborne }

    private var accRing: [AccPt] = []
    private var chop = 0.0
    private var preChop = 0.0
    private var lastCrashT = -Double.infinity

    private var baro: [BaroPt] = []
    private var locs: [LocPt] = []
    private var submerged: Bool?

    private var state: State = .idle
    private var tTO: TimeInterval = 0
    private var anchorB = 0.0
    private var anchorOk = false
    private var landEvidenceT: TimeInterval = -1
    private var chopRunStart: TimeInterval = -1
    private var pendingRefine: (jump: V12Jump, dueT: TimeInterval)?

    private var arcLastBaroRel = Double.infinity
    private var arcPrevBaroRel = Double.infinity
    private var arcLastBaroT: TimeInterval = -1
    private var arcMaxBaroRel = 0.0
    private var arcBaroSeen = false

    public init(_ cfg: V12Config = V12Config()) {
        self.cfg = cfg
    }

    public func reset() {
        accRing.removeAll(keepingCapacity: true)
        chop = 0
        preChop = 0
        lastCrashT = -Double.infinity
        baro.removeAll(keepingCapacity: true)
        locs.removeAll(keepingCapacity: true)
        submerged = nil
        state = .idle
        tTO = 0
        anchorB = 0
        anchorOk = false
        landEvidenceT = -1
        chopRunStart = -1
        pendingRefine = nil
        resetArc()
    }

    public func addAccel(t: TimeInterval, aMag: Double) {
        accRing.append(AccPt(t: t, a: aMag))
        let lo = t - cfg.chopWinSec
        while let first = accRing.first, first.t < lo {
            accRing.removeFirst()
        }
        if accRing.count >= 4 {
            let mean = accRing.reduce(0.0) { $0 + $1.a } / Double(accRing.count)
            let variance = accRing.reduce(0.0) { $0 + ($1.a - mean) * ($1.a - mean) }
            chop = (variance / Double(accRing.count)).squareRoot()
        }

        if cfg.enforceCrashCooldown, aMag >= cfg.crashG, state == .idle {
            lastCrashT = t
        }

        switch state {
        case .idle:
            if aMag >= cfg.yankG,
               aMag < cfg.crashG,
               (!cfg.enforceCrashCooldown || t - lastCrashT > cfg.crashCooldownSec),
               (!cfg.requirePlaning || isPlaning(at: t)),
               let anchor = waterAnchor(at: t) {
                beginJump(t: t, anchor: anchor)
                onDebug(t, "TAKEOFF yank=\(rounded(aMag, decimals: 2))")
            }

        case .airborne:
            let air = t - tTO
            if air > cfg.maxAirSec {
                state = .idle
                onDebug(t, "ABORT maxAir")
                break
            }
            if air < cfg.minAirSec * 0.5 {
                break
            }
            let realArc = arcMaxBaroRel >= cfg.minJumpHeightM * 0.5
            if cfg.abortOnMidArcCrash, aMag >= cfg.crashG, (air < cfg.minAirSec || !realArc) {
                state = .idle
                onDebug(t, "ABORT crashMidArc")
                break
            }
            if aMag >= cfg.landImpactG, air >= cfg.minAirSec, landEvidenceT < 0 {
                landEvidenceT = t
            }

            if aMag >= cfg.yankG,
               air >= 1.0,
               arcMaxBaroRel < 0.5,
               (!cfg.requirePlaning || isPlaning(at: t)),
               let anchor = waterAnchor(at: t) {
                beginJump(t: t, anchor: anchor)
                onDebug(t, "RESTART yank=\(rounded(aMag, decimals: 2))")
                break
            }

            if air >= cfg.minAirSec {
                if chop >= preChop * cfg.chopResumeFrac {
                    if chopRunStart < 0 {
                        chopRunStart = t
                    }
                    if t - chopRunStart >= cfg.chopResumeHoldSec, landEvidenceT < 0 {
                        landEvidenceT = chopRunStart
                    }
                } else {
                    chopRunStart = -1
                }

                if submerged == true, landEvidenceT < 0 {
                    landEvidenceT = t
                }

                if landEvidenceT > 0 {
                    let baroSilent = arcLastBaroT < 0 ? air > 2.5 : (t - arcLastBaroT) > 2.5
                    let closeInTime = abs(arcLastBaroT - landEvidenceT) <= 1.3
                    let baroConfirms = !cfg.requireLandingBaroConfirmation
                        || (baroOnWater(strict: false) && closeInTime)
                        || submerged == true
                        || baroSilent
                    if baroConfirms {
                        finishJump(landingT: landEvidenceT)
                        break
                    }
                    if t - landEvidenceT > 2.0 {
                        landEvidenceT = -1
                        chopRunStart = -1
                    }
                }
            }
        }

        if let pending = pendingRefine, t >= pending.dueT {
            refine(now: t)
        }
    }

    public func addBaro(t: TimeInterval, relAltM: Double) {
        baro.append(BaroPt(t: t, alt: relAltM))
        let keep = max(cfg.anchorMaxAgeSec + cfg.maxAirSec + cfg.refineDelaySec, 30)
        let lo = t - keep
        while let first = baro.first, first.t < lo {
            baro.removeFirst()
        }

        if state == .airborne {
            let rel = relAltM - anchorB
            arcPrevBaroRel = arcLastBaroRel
            arcLastBaroRel = rel
            arcLastBaroT = t
            if rel > arcMaxBaroRel {
                arcMaxBaroRel = rel
            }
            arcBaroSeen = true

            let air = t - tTO
            if landEvidenceT > 0,
               air >= cfg.minAirSec,
               (!cfg.requireLandingBaroConfirmation || baroOnWater(strict: false)),
               abs(t - landEvidenceT) <= 1.3 {
                finishJump(landingT: landEvidenceT)
                return
            }

            if air >= cfg.minAirSec,
               arcMaxBaroRel >= cfg.absoluteTakeoffRiseM,
               baroOnWater(strict: cfg.requireLandingBaroConfirmation) {
                finishJump(landingT: t)
            }
        } else if let anchor = waterAnchor(at: t) {
            let rel = relAltM - anchor
            if rel >= cfg.absoluteTakeoffRiseM {
                beginJump(t: t, anchor: anchor)
                arcLastBaroRel = rel
                arcPrevBaroRel = .infinity
                arcLastBaroT = t
                arcMaxBaroRel = max(0, rel)
                arcBaroSeen = true
                onDebug(t, "TAKEOFF absoluteRise=\(rounded(rel, decimals: 2))")
            }
        }
    }

    public func addLocation(t: TimeInterval, lat: Double, lng: Double, speedMs: Double) {
        locs.append(LocPt(t: t, lat: lat, lng: lng, spd: max(speedMs, 0)))
        let lo = t - 30
        while let first = locs.first, first.t < lo {
            locs.removeFirst()
        }
    }

    public func addSubmersion(t: TimeInterval, submerged: Bool) {
        self.submerged = submerged
    }

    public func flush(t: TimeInterval) {
        if pendingRefine != nil {
            refine(now: t)
        }
    }

    private func resetArc() {
        arcLastBaroRel = .infinity
        arcPrevBaroRel = .infinity
        arcLastBaroT = -1
        arcMaxBaroRel = 0
        arcBaroSeen = false
    }

    private func beginJump(t: TimeInterval, anchor: Double) {
        state = .airborne
        tTO = t
        anchorB = anchor
        anchorOk = true
        preChop = max(chop, 0.02)
        landEvidenceT = -1
        chopRunStart = -1
        resetArc()
    }

    private func baroOnWater(strict: Bool) -> Bool {
        guard arcBaroSeen else { return false }
        let tolerance = strict ? cfg.landingReturnToleranceM : max(cfg.landingReturnToleranceM, 0.30 * arcMaxBaroRel)
        let lowBar = max(tolerance, 0.20 * arcMaxBaroRel)
        let flat = arcPrevBaroRel == .infinity ? true : abs(arcLastBaroRel - arcPrevBaroRel) <= 0.35
        return arcLastBaroRel <= lowBar && flat
    }

    private func isPlaning(at t: TimeInterval) -> Bool {
        guard cfg.requirePlaning else { return true }
        let lo = t - cfg.planingWinSec
        var sawFix = false
        for loc in locs.reversed() {
            if loc.t < lo {
                break
            }
            sawFix = true
            if loc.spd >= cfg.planingSpeedMs {
                return true
            }
        }
        return !sawFix
    }

    private func waterAnchor(at t: TimeInterval) -> Double? {
        guard !baro.isEmpty else { return nil }
        var pts: [Double] = []
        for sample in baro.reversed() {
            if sample.t > t - 0.3 {
                continue
            }
            if t - sample.t > cfg.anchorMaxAgeSec {
                break
            }
            pts.append(sample.alt)
        }
        guard pts.count >= max(1, cfg.anchorMinSamples) else {
            guard !cfg.requireBaroAnchor else { return nil }
            return baro.last?.alt
        }
        pts.sort()
        return pts[Int(Double(pts.count) * 0.25)]
    }

    private func fitHeight(landingT: TimeInterval) -> (h: Double,
                                                        apexT: TimeInterval,
                                                        arcPts: Int,
                                                        takeoffAlt: Double,
                                                        apexAlt: Double,
                                                        landingAlt: Double?) {
        var maxRel = 0.0
        var apexT = tTO
        var apexAlt = anchorB
        var landingAlt: Double?
        var arcPts = 0
        for sample in baro {
            guard sample.t >= tTO, sample.t <= landingT else { continue }
            arcPts += 1
            landingAlt = sample.alt
            let rel = sample.alt - anchorB
            if rel >= maxRel {
                maxRel = rel
                apexT = sample.t
                apexAlt = sample.alt
            }
        }
        let clamped = min(max(maxRel, 0), cfg.maxJumpHeightM)
        return (clamped, apexT, arcPts, anchorB, apexAlt, landingAlt)
    }

    private func horizontalMetrics(landingT: TimeInterval) -> (distanceM: Double?,
                                                               takeoffSpeedMS: Double?,
                                                               landingSpeedMS: Double?) {
        func at(_ t: TimeInterval) -> LocPt? {
            var best: LocPt?
            var bestDelta = Double.infinity
            for loc in locs {
                let delta = abs(loc.t - t)
                if delta < bestDelta {
                    bestDelta = delta
                    best = loc
                }
            }
            return bestDelta <= 2.5 ? best : nil
        }

        if let takeoff = at(tTO),
           let landing = at(landingT),
           takeoff.lat != 0 || takeoff.lng != 0,
           landing.lat != 0 || landing.lng != 0 {
            let earthR = 6_371_000.0
            let dLat = (landing.lat - takeoff.lat) * .pi / 180
            let dLng = (landing.lng - takeoff.lng) * .pi / 180
            let h = sin(dLat / 2) * sin(dLat / 2)
                + cos(takeoff.lat * .pi / 180)
                * cos(landing.lat * .pi / 180)
                * sin(dLng / 2)
                * sin(dLng / 2)
            let distance = (2 * earthR * asin(h.squareRoot()) * 10).rounded() / 10
            return (distance, takeoff.spd, landing.spd)
        }

        if let takeoff = at(tTO) {
            let distance = (takeoff.spd * (landingT - tTO) * 10).rounded() / 10
            return (distance, takeoff.spd, at(landingT)?.spd)
        }
        return (nil, nil, at(landingT)?.spd)
    }

    private func finishJump(landingT: TimeInterval) {
        state = .idle
        guard anchorOk else { return }

        let totalAir = landingT - tTO
        guard totalAir >= cfg.minAirSec, totalAir <= cfg.maxAirSec else { return }

        let fit = fitHeight(landingT: landingT)
        guard !cfg.enforceMinJumpHeight || fit.h >= cfg.minJumpHeightM else {
            onDebug(landingT, "REJECT belowMinHeight h=\(rounded(fit.h, decimals: 2))")
            return
        }
        let horizontal = horizontalMetrics(landingT: landingT)

        var confidence = 0.55
        if fit.arcPts >= 1 { confidence += 0.15 }
        if fit.arcPts >= 2 { confidence += 0.10 }
        if chop < preChop * 0.9 { confidence += 0.05 }

        let jump = V12Jump(
            heightM: rounded(fit.h, decimals: 2),
            airtimeSec: rounded(totalAir, decimals: 2),
            distanceM: horizontal.distanceM,
            takeoffAltitudeM: rounded(fit.takeoffAlt, decimals: 2),
            apexAltitudeM: rounded(fit.apexAlt, decimals: 2),
            landingAltitudeM: fit.landingAlt.map { rounded($0, decimals: 2) },
            takeoffSpeedMS: horizontal.takeoffSpeedMS.map { rounded($0, decimals: 2) },
            landingSpeedMS: horizontal.landingSpeedMS.map { rounded($0, decimals: 2) },
            takeoffT: tTO,
            landingT: landingT,
            apexT: fit.apexT,
            confidence: min(confidence, 1),
            arcBaroPoints: fit.arcPts,
            refined: false,
            driftSuspect: false,
            rtzM: nil
        )
        delegate?.jumpDetected(jump)
        pendingRefine = (jump, landingT + cfg.refineDelaySec)
        onDebug(landingT, "JUMP real absolute h=\(jump.heightM)m startAlt=\(jump.takeoffAltitudeM)m apexAlt=\(jump.apexAltitudeM)m landAlt=\(jump.landingAltitudeM ?? -1)m air=\(jump.airtimeSec)s dist=\(jump.distanceM ?? -1)m speed=\(jump.takeoffSpeedMS ?? -1)m/s arcPts=\(jump.arcBaroPoints)")
    }

    private func refine(now: TimeInterval) {
        guard let pending = pendingRefine else { return }
        pendingRefine = nil

        var post: [BaroPt] = []
        for sample in baro where sample.t > pending.jump.landingT + 0.4 && sample.t <= now {
            post.append(sample)
        }

        guard !post.isEmpty else {
            delegate?.jumpRefined(reissue(pending.jump, h: pending.jump.heightM, drift: false, rtz: nil))
            return
        }

        let vals = post.map(\.alt).sorted()
        let rearAnchor = vals[vals.count / 2]
        let frontAnchor = anchorB(for: pending.jump)
        let rtz = rearAnchor - frontAnchor

        let drift = abs(rtz) > cfg.rtzCorrectM
        let confidence = cfg.enforceMinJumpHeight && pending.jump.heightM < cfg.minJumpHeightM
            ? min(pending.jump.confidence, 0.3)
            : pending.jump.confidence
        delegate?.jumpRefined(reissue(
            pending.jump,
            h: pending.jump.heightM,
            drift: drift,
            rtz: rounded(rtz, decimals: 2),
            confidence: confidence
        ))
        onDebug(now, "JUMP refined absolute h=\(pending.jump.heightM) rtz=\(rounded(rtz, decimals: 2)) drift=\(drift)")
    }

    private func anchorB(for jump: V12Jump) -> Double {
        var pts: [Double] = []
        for sample in baro.reversed() {
            if sample.t > jump.takeoffT - 0.3 {
                continue
            }
            if jump.takeoffT - sample.t > cfg.anchorMaxAgeSec {
                break
            }
            pts.append(sample.alt)
            if pts.count >= cfg.anchorSamples {
                break
            }
        }
        guard !pts.isEmpty else { return anchorB }
        pts.sort()
        return pts[pts.count / 2]
    }

    private func reissue(_ jump: V12Jump,
                         h: Double,
                         drift: Bool,
                         rtz: Double?,
                         confidence: Double? = nil) -> V12Jump {
        V12Jump(
            heightM: h,
            airtimeSec: jump.airtimeSec,
            distanceM: jump.distanceM,
            takeoffAltitudeM: jump.takeoffAltitudeM,
            apexAltitudeM: jump.apexAltitudeM,
            landingAltitudeM: jump.landingAltitudeM,
            takeoffSpeedMS: jump.takeoffSpeedMS,
            landingSpeedMS: jump.landingSpeedMS,
            takeoffT: jump.takeoffT,
            landingT: jump.landingT,
            apexT: jump.apexT,
            confidence: confidence ?? jump.confidence,
            arcBaroPoints: jump.arcBaroPoints,
            refined: true,
            driftSuspect: drift,
            rtzM: rtz
        )
    }

    private func rounded(_ value: Double, decimals: Int) -> Double {
        let factor = pow(10.0, Double(decimals))
        return (value * factor).rounded() / factor
    }
}
