//
//  JumpEngineV12.swift — the INSTANT event-driven pipeline: height + airtime +
//  distance on the wrist ≤2 s after landing. Apple Watch **Series 8 and later**
//  (watchOS 10+). NO Ultra-only hardware required — CMWaterSubmersionManager is
//  used opportunistically when present, never depended on.
//
//  Line-for-line twin of core/jumpEngineV12.ts — keep them in sync.
//
//  ═══════════════════════════════════════════════════════════════════════════
//  WHY (both facts measured against Surfr goldens on LOG2/LOG4):
//   1. HEIGHT lives ONLY in the barometer (a kite rise is canopy-borne; the
//      wrist IMU double-integrates to ~0, and CoreMotion attitude is corrupted
//      during sustained maneuvers — see research/fabel5/_v10imu.ts).
//   2. TIMING lives ONLY in the IMU: the take-off yank and the landing contact
//      at 800 Hz give the airtime to ~10 ms — the number Surfr shows.
//  V12 splits the roles: baro anchored to the ~4 s BEFORE the yank (drift there
//  is ±0.2–0.4 m even on a bad day) + measured airtime + endpoint-anchored arc
//  fit. No settle, no future baseline → the result is ready AT the landing.
//  ═══════════════════════════════════════════════════════════════════════════
//
//  Usage (no GUI here — wire the delegate to whatever HUD you have):
//
//      let engine = JumpSessionV12()
//      engine.delegate = self          // jumpDetected / jumpRefined
//      try await engine.start()        // needs an ACTIVE HKWorkoutSession
//      ...
//      engine.stop()
//

import CoreMotion
import CoreLocation
#if os(watchOS)
import WatchKit
#endif
import Foundation

// MARK: - Config (mirror of DEFAULT_V12_CONFIG in the TS twin)

public struct V12Config {
    // event detection (rotation-invariant |a| in g)
    public var yankG = 2.2            // take-off impulse floor (reals 2.0–5.9 g)
    public var crashG = 6.0           // ≥ this = water impact, not a take-off
    public var landImpactG = 2.0      // landing contact impulse
    public var chopWinSec = 0.3       // causal chop RMS window
    public var chopResumeFrac = 0.8   // landing when chop ≥ this × pre-take-off chop
    public var chopResumeHoldSec = 0.3
    public var minAirSec = 1.2
    public var maxAirSec = 8.0
    // riding gate (GPS)
    public var planingSpeedMs = 0.56  // 2 km/h — low enough to TEST by running +
                                      // throwing (a kite session is far above this;
                                      // raise toward ~3.5 for kite-only production).
    public var planingWinSec = 5.0
    // baro / height
    public var anchorSamples = 4      // on-water baro samples in the anchor median
    public var anchorMaxAgeSec = 8.0
    public var minJumpHeightM = 1.5   // display floor (Surfr filters < 1.5 m too)
    public var maxJumpHeightM = 12.0
    public var kiteGlideFactor = 2.63
    // refinement (post-landing drift check)
    public var refineDelaySec = 3.0
    public var rtzCorrectM = 0.25
    // crash cooldown (a wet baro port paints fake humps for ~30 s)
    public var crashCooldownSec = 30.0
    public init() {}
}

// MARK: - Output

public struct V12Jump {
    public let heightM: Double        // apex above the water anchor
    public let airtimeSec: Double     // MEASURED take-off → landing (IMU)
    public let distanceM: Double?     // GPS displacement (fallback v·t)
    public let takeoffT: TimeInterval // seconds, CACurrentMediaTime-style monotonic
    public let landingT: TimeInterval
    public let apexT: TimeInterval
    public let confidence: Double
    public let arcBaroPoints: Int     // baro samples inside the arc (quality)
    public let refined: Bool
    public let driftSuspect: Bool
    public let rtzM: Double?          // measured net drift across the arc
}

public protocol JumpPipelineV12Delegate: AnyObject {
    /// ≤~0.5 s after the landing evidence — the on-wrist display number.
    func jumpDetected(_ jump: V12Jump)
    /// ~refineDelaySec later — drift-checked (possibly corrected) value.
    func jumpRefined(_ jump: V12Jump)
}

// MARK: - Pipeline (pure logic — feed it samples; testable without sensors)

public final class JumpPipelineV12 {
    public weak var delegate: JumpPipelineV12Delegate?
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
    private var submerged: Bool? = nil

    /// state-machine trace (V12DebugSnapshot feed) — takeoffs, landings, aborts.
    public var onDebug: (TimeInterval, String) -> Void = { _, _ in }

    private var state: State = .idle
    private var tTO: TimeInterval = 0
    private var anchorB = 0.0
    private var anchorOk = false
    private var landEvidenceT: TimeInterval = -1  // first landing evidence (impact/chop-hold/submersion)
    private var chopRunStart: TimeInterval = -1   // start of the current chop-resume run
    private var pendingRefine: (jump: V12Jump, dueT: TimeInterval)? = nil
    // arc-baro trackers (baro-aware landing): in-flight bar-work chop can exceed
    // a glassy-water run-up chop (LOG4 J2) — the ~1 Hz baro bounds the landing.
    private var arcLastBaroRel = Double.infinity
    private var arcPrevBaroRel = Double.infinity  // the one before it (flatness test)
    private var arcLastBaroT: TimeInterval = -1
    private var arcMaxBaroRel = 0.0
    private var arcBaroSeen = false

    /// "Back on the water" test for an in-arc baro sample: LOW relative to the
    /// arc (drift-tolerant — the water line may shift ~30 % of the arc height
    /// during the jump, measured on LOG4) AND FLAT (the arc's slope is gone).
    private func baroOnWater(strict: Bool) -> Bool {
        guard arcBaroSeen else { return false }
        let lowBar = strict ? max(0.35, 0.20 * arcMaxBaroRel) : max(0.60, 0.30 * arcMaxBaroRel)
        let flat = arcPrevBaroRel == .infinity ? true : abs(arcLastBaroRel - arcPrevBaroRel) <= 0.35
        return arcLastBaroRel <= lowBar && flat
    }

    public init(_ cfg: V12Config = V12Config()) { self.cfg = cfg }

    // ── inputs (timestamps in seconds, one monotonic clock for all streams) ──

    /// |a| in g — rotation-invariant, no attitude needed. Any rate ≥50 Hz; 800 Hz batched preferred.
    public func addAccel(t: TimeInterval, aMag: Double) {
        // causal chop: RMS deviation over the trailing chopWinSec
        accRing.append(AccPt(t: t, a: aMag))
        let lo = t - cfg.chopWinSec
        while let f = accRing.first, f.t < lo { accRing.removeFirst() }
        if accRing.count >= 4 {
            let m = accRing.reduce(0.0) { $0 + $1.a } / Double(accRing.count)
            let q = accRing.reduce(0.0) { $0 + ($1.a - m) * ($1.a - m) }
            chop = (q / Double(accRing.count)).squareRoot()
        }

        // CRASH marker (feeds the cooldown) ONLY while not airborne — a high-g
        // event DURING a jump is the landing impact (a hard touchdown / catch),
        // not a slam, and must not arm the cooldown that blocks the next take-off.
        if aMag >= cfg.crashG, state == .idle { lastCrashT = t }

        switch state {
        case .idle:
            // TAKE-OFF: a yank while planing, not a crash, outside any crash cooldown
            if aMag >= cfg.yankG, aMag < cfg.crashG,
               t - lastCrashT > cfg.crashCooldownSec,
               isPlaning(at: t),
               let anchor = waterAnchor(at: t) {
                state = .airborne
                tTO = t
                anchorB = anchor
                anchorOk = true
                preChop = max(chop, 0.02)
                landEvidenceT = -1; chopRunStart = -1
                arcLastBaroRel = .infinity; arcPrevBaroRel = .infinity; arcLastBaroT = -1
                arcMaxBaroRel = 0; arcBaroSeen = false
                onDebug(t, "TAKEOFF yank=\(aMag)")
            }
        case .airborne:
            let air = t - tTO
            if air > cfg.maxAirSec { state = .idle; onDebug(t, "ABORT maxAir"); break }
            if air < cfg.minAirSec * 0.5 { break }              // ignore the yank's own tail
            // A high-g event mid-flight is a crash ONLY if it is EARLY (before a
            // real airborne phase) or the arc never gained altitude — not a real
            // jump. Once a genuine altitude arc exists past minAirSec, a high-g is
            // the LANDING IMPACT (hard touchdown / catch) → the landing detector.
            let realArc = arcMaxBaroRel >= cfg.minJumpHeightM * 0.5
            if aMag >= cfg.crashG, (air < cfg.minAirSec || !realArc) {
                state = .idle; onDebug(t, "ABORT crashMidArc"); break
            }
            if aMag >= cfg.landImpactG, air >= cfg.minAirSec, landEvidenceT < 0 { landEvidenceT = t } // impact evidence

            // CANDIDATE RESTART: a fresh take-off-grade yank while the current
            // arc shows NO baro elevation = the candidate was a false start that
            // would otherwise swallow the real jump behind it. A real jump
            // cannot restart-loop: its arc elevates the baro within ~1 s.
            if aMag >= cfg.yankG, air >= 1.0, arcMaxBaroRel < 0.5, isPlaning(at: t),
               let anchor = waterAnchor(at: t) {
                tTO = t
                anchorB = anchor
                preChop = max(chop, 0.02)
                landEvidenceT = -1; chopRunStart = -1
                arcLastBaroRel = .infinity; arcPrevBaroRel = .infinity; arcLastBaroT = -1
                arcMaxBaroRel = 0; arcBaroSeen = false
                onDebug(t, "RESTART yank=\(aMag)")
                break
            }

            // ── TWO-STAGE LANDING: the IMU gives the precise TIME (evidence),
            //    the baro CONFIRMS the water contact. A mid-flight bar spike
            //    raises evidence too — but the baro stays high, the evidence
            //    goes stale after 2 s, and the arc continues. Evidence cannot
            //    precede minAirSec (the yank's own tail is not a landing). ──
            if air >= cfg.minAirSec {
                if chop >= preChop * cfg.chopResumeFrac {                       // chop-resume
                    if chopRunStart < 0 { chopRunStart = t }
                    if t - chopRunStart >= cfg.chopResumeHoldSec, landEvidenceT < 0 {
                        landEvidenceT = chopRunStart
                    }
                } else { chopRunStart = -1 }
                if submerged == true, landEvidenceT < 0 { landEvidenceT = t }    // Ultra
                if landEvidenceT > 0 {
                    let baroSilent = arcLastBaroT < 0 ? air > 2.5 : (t - arcLastBaroT) > 2.5
                    // the confirming baro sample must be CLOSE to the evidence
                    // (≤1.3 s ≈ one baro interval) — a later confirm belongs to
                    // a later landing (mid-flight-spike protection).
                    let closeInTime = abs(arcLastBaroT - landEvidenceT) <= 1.3
                    let baroConfirms = (baroOnWater(strict: false) && closeInTime)
                        || submerged == true
                        || baroSilent // sensor gap → trust the IMU alone
                    if baroConfirms { finishJump(landingT: landEvidenceT); break }
                    if t - landEvidenceT > 2.0 { // stale — a mid-flight spike
                        landEvidenceT = -1; chopRunStart = -1
                    }
                }
            }
        }

        if let pr = pendingRefine, t >= pr.dueT { refine(now: t) }
    }

    /// CMAltimeter relativeAltitude in METRES with its own timestamp (~1 Hz). NEVER resample.
    public func addBaro(t: TimeInterval, relAltM: Double) {
        baro.append(BaroPt(t: t, alt: relAltM))
        let keep = max(cfg.anchorMaxAgeSec + cfg.maxAirSec + cfg.refineDelaySec, 30)
        let lo = t - keep
        while let f = baro.first, f.t < lo { baro.removeFirst() }
        if state == .airborne {
            let rel = relAltM - anchorB
            arcPrevBaroRel = arcLastBaroRel
            arcLastBaroRel = rel; arcLastBaroT = t
            if rel > arcMaxBaroRel { arcMaxBaroRel = rel }
            arcBaroSeen = true
            let air = t - tTO
            // pending IMU evidence + this on-water sample close to it → CONFIRMED
            if landEvidenceT > 0, air >= cfg.minAirSec, baroOnWater(strict: false),
               abs(t - landEvidenceT) <= 1.3 {
                finishJump(landingT: landEvidenceT)
                return
            }
            // BARO-RETURN (no IMU evidence — the soft glassy-water landing): the
            // arc was genuinely elevated and this sample is low AND flat.
            if air >= cfg.minAirSec, arcMaxBaroRel >= 1.0, baroOnWater(strict: true) {
                finishJump(landingT: t)
            }
        }
    }

    /// GPS fix (~1 Hz): position + speed (m/s).
    public func addLocation(t: TimeInterval, lat: Double, lng: Double, speedMs: Double) {
        locs.append(LocPt(t: t, lat: lat, lng: lng, spd: max(speedMs, 0)))
        let lo = t - 30
        while let f = locs.first, f.t < lo { locs.removeFirst() }
    }

    /// OPTIONAL (Ultra) — direct out-of-water signal. Never required.
    public func addSubmersion(t: TimeInterval, submerged: Bool) { self.submerged = submerged }

    /// Session end — flush a due refinement.
    public func flush(t: TimeInterval) { if pendingRefine != nil { refine(now: t) } }

    // ── internals ────────────────────────────────────────────────────────────

    private func isPlaning(at t: TimeInterval) -> Bool {
        // PERMISSIVE on missing GPS: reject only when GPS is PRESENT and too slow.
        // With no recent fix (GPS gap / cold start / garden test) we can't disprove
        // planing, so we allow it — the real anti-false-positive is the 1.5 m
        // altitude-arc + airtime gate downstream, which hand motion never clears.
        let lo = t - cfg.planingWinSec
        var sawFix = false
        for l in locs.reversed() {
            if l.t < lo { break }
            sawFix = true
            if l.spd >= cfg.planingSpeedMs { return true }
        }
        return !sawFix  // present+slow → false; absent → true
    }

    /// Water-level anchor: median of the last anchorSamples baro points BEFORE
    /// the yank — the ONLY "baseline" V12 ever needs (≈4 s of past → drift-tight).
    private func waterAnchor(at t: TimeInterval) -> Double? {
        // BASE LEVEL = LOW PERCENTILE (~25th) of the anchor window: the rider spends
        // the pre-jump window near the water/hand-carry level and only goes UP, so a
        // low percentile is immune to the exact yank timing and to a running-test
        // candidate that re-anchors on arm-swing noise (a median at a noisy yank
        // drifted the anchor up and collapsed the height to 0). Riding unaffected.
        var pts: [Double] = []
        for b in baro.reversed() {
            if b.t > t - 0.3 { continue }                       // exclude the rise itself
            if t - b.t > cfg.anchorMaxAgeSec { break }
            pts.append(b.alt)
        }
        guard pts.count >= 2 else { return nil }
        pts.sort()
        return pts[Int(Double(pts.count) * 0.25)]               // 25th percentile
    }

    /// Height from the arc's baro points.
    /// ≥2 interior points → TAKE-OFF-ANCHORED FREE PARABOLA z = b·τ + c·τ²
    /// (z(0)=0): the apex = the vertex, INDEPENDENT of the landing-time estimate
    /// — a soft landing detected ±1 s late cannot bias the height.
    /// 1 point → endpoint-anchored 1-parameter basis. 0 points → glide model.
    private func fitHeight(landingT: TimeInterval) -> (h: Double, apexT: TimeInterval, arcPts: Int) {
        let T = landingT - tTO
        var pts: [(tau: Double, z: Double)] = []
        for b in baro {
            guard b.t > tTO + 0.2, b.t < landingT - 0.1 else { continue }
            pts.append((b.t - tTO, b.alt - anchorB))
        }
        let arcPts = pts.count
        var h: Double? = nil
        var apexT = tTO + T / 2
        if arcPts >= 2 {
            var s2 = 0.0, s3 = 0.0, s4 = 0.0, sz1 = 0.0, sz2 = 0.0
            for p in pts { let t2 = p.tau * p.tau; s2 += t2; s3 += t2 * p.tau; s4 += t2 * t2; sz1 += p.z * p.tau; sz2 += p.z * t2 }
            let det = s2 * s4 - s3 * s3
            if abs(det) > 1e-9 {
                let bC = (sz1 * s4 - sz2 * s3) / det
                let cC = (sz2 * s2 - sz1 * s3) / det
                if cC < -1e-6 {
                    let tauApex = -bC / (2 * cC)
                    if tauApex > 0, tauApex < T + 1.0 { // vertex physically inside the arc
                        h = bC * tauApex + cC * tauApex * tauApex
                        apexT = tTO + tauApex
                    }
                }
            }
        }
        if h == nil, arcPts >= 1 {
            var num = 0.0, den = 0.0
            for p in pts { let phi = 4 * p.tau * (T - p.tau) / (T * T); num += p.z * phi; den += phi * phi }
            if den > 1e-9 { h = num / den }
        }
        let g = 9.80665
        var hh = h ?? (g / 8) * (T / cfg.kiteGlideFactor) * (T / cfg.kiteGlideFactor)  // glide fallback
        // FLOOR at the highest OBSERVED arc point: a parabola through a real arc
        // recovers the apex BETWEEN samples, i.e. ≥ the max sampled point; if the
        // concave fit failed (noisy/asymmetric arc — a running-test throw), never
        // report LESS than what the barometer actually saw.
        for p in pts where p.z > hh { hh = p.z }
        let hv = min(max(hh, 0), cfg.maxJumpHeightM)
        return (hv, apexT, arcPts)
    }

    private func distance(landingT: TimeInterval) -> Double? {
        func at(_ t: TimeInterval) -> LocPt? {
            var best: LocPt? = nil; var bd = Double.infinity
            for l in locs { let d = abs(l.t - t); if d < bd { bd = d; best = l } }
            return bd <= 2.5 ? best : nil
        }
        // lat=lng=0 means "speed-only fix" (some loggers have no position) → fall back
        if let a = at(tTO), let b = at(landingT), a.lat != 0 || a.lng != 0, b.lat != 0 || b.lng != 0 {
            let R = 6_371_000.0
            let dLat = (b.lat - a.lat) * .pi / 180, dLng = (b.lng - a.lng) * .pi / 180
            let q = sin(dLat / 2) * sin(dLat / 2)
                  + cos(a.lat * .pi / 180) * cos(b.lat * .pi / 180) * sin(dLng / 2) * sin(dLng / 2)
            return (2 * R * asin(q.squareRoot()) * 10).rounded() / 10
        }
        if let a = at(tTO) { return (a.spd * (landingT - tTO) * 10).rounded() / 10 }
        return nil
    }

    private func finishJump(landingT: TimeInterval) {
        state = .idle
        guard anchorOk else { return }
        let T = landingT - tTO
        guard T >= cfg.minAirSec, T <= cfg.maxAirSec else { return }
        let (h, apexT, arcPts) = fitHeight(landingT: landingT)
        guard h >= cfg.minJumpHeightM else { return }           // Surfr-style display floor
        var conf = 0.55
        if arcPts >= 1 { conf += 0.15 }
        if arcPts >= 2 { conf += 0.10 }
        if chop < preChop * 0.9 { conf += 0.05 }
        let jump = V12Jump(
            heightM: (h * 100).rounded() / 100,
            airtimeSec: (T * 100).rounded() / 100,
            distanceM: distance(landingT: landingT),
            takeoffT: tTO, landingT: landingT, apexT: apexT,
            confidence: min(conf, 1),
            arcBaroPoints: arcPts,
            refined: false, driftSuspect: false, rtzM: nil)
        delegate?.jumpDetected(jump)                            // ← the ≤2 s wrist number
        pendingRefine = (jump, landingT + cfg.refineDelaySec)
    }

    /// REFINEMENT (the ≤5 s DISPLAY number): a TWO-SIDED anchored refit. The
    /// post-landing on-water samples give a REAR anchor; front + rear anchors
    /// MEASURE the linear drift rate across the arc, which is removed from every
    /// arc point analytically before the endpoint-anchored refit — linear drift
    /// (the dominant wind/thermal component over 8–10 s) cancels exactly instead
    /// of being half-guessed (the old −rtz/2). Residual |rtz| after the linear
    /// model ⇒ non-linear drift ⇒ driftSuspect flag (never a rejection).
    private func refine(now: TimeInterval) {
        guard let pr = pendingRefine else { return }
        pendingRefine = nil
        // rear anchor: median + mean-time of the post-landing on-water samples
        var post: [BaroPt] = []
        for b in baro where b.t > pr.jump.landingT + 0.4 && b.t <= now { post.append(b) }
        guard !post.isEmpty else {
            delegate?.jumpRefined(reissue(pr.jump, h: pr.jump.heightM, drift: false, rtz: nil)); return
        }
        let vals = post.map(\.alt).sorted()
        let b1 = vals[vals.count / 2]
        let t1 = post.reduce(0.0) { $0 + $1.t } / Double(post.count)
        // front anchor: the jump's own take-off anchor + its mean time
        let b0 = anchorB(for: pr.jump)
        let t0 = pr.jump.takeoffT - 2.0 // ≈ centre of the 4-sample pre-take-off window
        let rtz = b1 - b0
        let d = (t1 - t0) > 1.0 ? rtz / (t1 - t0) : 0 // measured drift (m/s)
        // MODEL SELECTION between (a) no-drift and (b) linear-drift-across-the-
        // arc: a splash-triggered drift turns on only AT the landing (measured
        // on LOG4's post-jump ramps) — model (b) then over-corrects. The arc's
        // own residuals arbitrate: fit the take-off-anchored parabola under each
        // model and keep the one that explains the points better.
        let T = pr.jump.landingT - pr.jump.takeoffT
        func fitModel(_ drate: Double) -> (h: Double, sse: Double)? {
            var pts: [(tau: Double, z: Double)] = []
            for b in baro {
                guard b.t > pr.jump.takeoffT + 0.2, b.t < pr.jump.landingT - 0.1 else { continue }
                pts.append((b.t - pr.jump.takeoffT, b.alt - b0 - drate * (b.t - t0)))
            }
            guard !pts.isEmpty else { return nil }
            var h: Double? = nil, bC = 0.0, cC = 0.0
            if pts.count >= 2 {
                var s2 = 0.0, s3 = 0.0, s4 = 0.0, sz1 = 0.0, sz2 = 0.0
                for p in pts { let t2 = p.tau * p.tau; s2 += t2; s3 += t2 * p.tau; s4 += t2 * t2; sz1 += p.z * p.tau; sz2 += p.z * t2 }
                let det = s2 * s4 - s3 * s3
                if abs(det) > 1e-9 {
                    bC = (sz1 * s4 - sz2 * s3) / det
                    cC = (sz2 * s2 - sz1 * s3) / det
                    if cC < -1e-6 {
                        let ta = -bC / (2 * cC)
                        if ta > 0, ta < T + 1.0 { h = bC * ta + cC * ta * ta }
                    }
                }
            }
            if h == nil { // 1-parameter endpoint basis fallback
                var num = 0.0, den = 0.0
                for p in pts { let phi = 4 * p.tau * (T - p.tau) / (T * T); num += p.z * phi; den += phi * phi }
                guard den > 1e-9 else { return nil }
                h = num / den
                bC = 4 * h! / T; cC = -4 * h! / (T * T) // the basis as a parabola, for SSE
            }
            var sse = 0.0
            for p in pts { let e = p.z - (bC * p.tau + cC * p.tau * p.tau); sse += e * e }
            return (min(max(h!, 0), cfg.maxJumpHeightM), sse)
        }
        var h = pr.jump.heightM
        let mA = fitModel(0), mB = fitModel(d)
        if let a = mA, let b = mB { h = (b.sse < a.sse ? b : a).h }
        else if let a = mA { h = a.h }
        else if let b = mB { h = b.h }
        let drift = abs(rtz) > cfg.rtzCorrectM // large net drift measured — flag it
        // RETRACTION: the drift-corrected refit fell below the display floor —
        // the instant emission was a drift artifact; collapse the confidence.
        let conf = h < cfg.minJumpHeightM ? min(pr.jump.confidence, 0.3) : pr.jump.confidence
        delegate?.jumpRefined(reissue(pr.jump, h: (h * 100).rounded() / 100, drift: drift,
                                      rtz: (rtz * 100).rounded() / 100, confidence: conf))
    }

    private func anchorB(for j: V12Jump) -> Double {
        var pts: [Double] = []
        for b in baro.reversed() {
            if b.t > j.takeoffT - 0.3 { continue }
            if j.takeoffT - b.t > cfg.anchorMaxAgeSec { break }
            pts.append(b.alt)
            if pts.count >= cfg.anchorSamples { break }
        }
        guard !pts.isEmpty else { return anchorB }
        pts.sort()
        return pts[pts.count / 2]
    }

    private func reissue(_ j: V12Jump, h: Double, drift: Bool, rtz: Double?,
                         confidence: Double? = nil) -> V12Jump {
        V12Jump(heightM: h, airtimeSec: j.airtimeSec, distanceM: j.distanceM,
                takeoffT: j.takeoffT, landingT: j.landingT, apexT: j.apexT,
                confidence: confidence ?? j.confidence, arcBaroPoints: j.arcBaroPoints,
                refined: true, driftSuspect: drift, rtzM: rtz)
    }
}

// MARK: - Sensor acquisition (Series 8+, watchOS 10+)
//
// IMPORTANT: CMBatchedSensorManager requires an ACTIVE HKWorkoutSession — start
// yours before calling start(). All streams are stamped on ONE monotonic clock
// (the CoreMotion/kernel timestamp), never resampled.
//
// ⚠️ CRITICAL — ONE CLOCK (real-log bug, 2026-07-05): CMDeviceMotion.timestamp
// and CMAltitudeData.timestamp are BOTH seconds-since-boot — the SAME clock.
// Two field logs recorded motion at ~0–215 s but baro/absAlt at ~8e8 s → a
// separate origin AND a per-session RANDOM skew (−1.5 to −1.8 s), which broke
// the fusion (the altitude arc never bracketed the IMU yank → 0 jumps). Feed the
// pipeline the RAW `data.timestamp` of EACH stream unchanged (as below); do NOT
// re-zero one stream and not another. Also write a SYNC record at session start
// (wall clock + a triple wrist-tap) so any residual skew is recoverable offline.
//
// ⚠️ LOW POWER (real-log bug): both field logs ran in Low Power Mode the whole
// session, throttling relativeAltitude to 0.39 Hz. Detect it
// (ProcessInfo.isLowPowerModeEnabled), warn the user to disable it, keep an
// active HKWorkoutSession (removes app throttling), and prefer absoluteAltitude
// (survived at 3 Hz even under Low Power). See V12_WATCH_APP_REVIEW_AND_SPEC §3–4.

@available(watchOS 10.0, *)
public final class JumpSessionV12: NSObject, CLLocationManagerDelegate {
    public let pipeline: JumpPipelineV12
    public weak var delegate: JumpPipelineV12Delegate? {
        get { pipeline.delegate } set { pipeline.delegate = newValue }
    }

    private let batched = CMBatchedSensorManager()
    private let altimeter = CMAltimeter()
    private let location = CLLocationManager()
    private var submersion: CMWaterSubmersionManager? = nil
    private var accelTask: Task<Void, Never>? = nil
    private var statusTimer: Timer? = nil
    private var lastBaroT: TimeInterval = -1
    private var baroHzEwma = 0.0
    private let bootWallClock = Date().timeIntervalSince1970 - ProcessInfo.processInfo.systemUptime

    /// HEIGHT SOURCE — three views of the SAME barometer, different smoothing/rate.
    /// A jump only needs the DELTA, and V12 anchors every jump to a local water
    /// level, so any slow reference offset CANCELS in the subtraction — the source
    /// just has to surface the barometer's FAST component with least lag:
    ///
    ///  • `.relativeAltitude` — Apple's cumulative, drift-managed, SMOOTHED value.
    ///     Field-observed to change only every 2–3 s (the smoothing, not the
    ///     sensor). Safe but LAGGED for a 1–2 s jump.
    ///  • `.pressureDerived` — altitude from the raw `pressure` field
    ///     (Δh ≈ −8.43 m/hPa · Δp). Closer to raw; same callback.
    ///  • `.absoluteAltitude` — the sea-level value from a SEPARATE, faster stream
    ///     (`startAbsoluteAltitudeUpdates`). Its slow reference offset is constant
    ///     across a jump → cancels against the water anchor, leaving the fast
    ///     barometric delta. Field-observed (Barometer apps) to track height
    ///     changes FAST regardless of movement — the likely reason Surfr shows an
    ///     accurate height in 3–5 s on this hardware. `Needs Verification` of the
    ///     exact on-device rate; all three are recorded to LOG5 so the field data
    ///     picks the lowest-lag channel, then this default is set to it.
    public enum BaroSource { case relativeAltitude, pressureDerived, absoluteAltitude }
    public var baroSource: BaroSource = .absoluteAltitude
    private var pressureAnchorHpa: Double? = nil
    private var absAnchorM: Double? = nil

    /// Optional LOG5 recorder hooks — the app's SessionLogger wires these to write
    /// the KSLG v2 streams. Nil = no logging (live-only). Recording is what proves
    /// the acquisition actually got the full rate (see STATUS).
    public var recordBaro: ((_ t: TimeInterval, _ relAltM: Double, _ pressureHpa: Double) -> Void)? = nil
    public var recordAbsAlt: ((_ t: TimeInterval, _ altM: Double, _ accuracyM: Double, _ precisionM: Double) -> Void)? = nil
    public var recordStatus: ((_ t: TimeInterval, _ thermal: Int, _ lowPower: Bool, _ batteryPct: Int, _ baroSource: Int, _ baroHz: Double) -> Void)? = nil
    /// DEDICATED max-QoS queue for altimeter callbacks — never .main. Under UI /
    /// Bluetooth load a main-queue handler can be delayed tens of ms and, worse,
    /// a SUSPENDED app loses callbacks entirely (the measured 0.36 Hz logs are
    /// exactly that pathology). The physics uses `data.timestamp` (stamped at
    /// measurement time), so queue jitter never corrupts the fit — this queue
    /// exists to guarantee DELIVERY, not timing. (An OperationQueue, not a
    /// DispatchQueue: startRelativeAltitudeUpdates(to:) takes an OperationQueue;
    /// a serial OperationQueue at userInteractive IS the right primitive here.)
    private let altQueue: OperationQueue = {
        let q = OperationQueue()
        q.name = "v12.altimeter"
        q.qualityOfService = .userInteractive
        q.maxConcurrentOperationCount = 1
        return q
    }()

    public init(_ cfg: V12Config = V12Config()) {
        pipeline = JumpPipelineV12(cfg)
        super.init()
    }

    /// Fired when a condition that DEGRADES detection is detected at start
    /// (Low Power Mode throttles the barometer). The app should surface it.
    public var onWarning: (String) -> Void = { _ in }

    /// Call with an ACTIVE HKWorkoutSession (CMBatchedSensorManager requires it).
    public func start() throws {
        // ⚠️ Low Power Mode throttles relativeAltitude to ~0.36 Hz (measured on
        //    field logs) — detection needs the full rate. We can't disable it from
        //    code; warn so the user turns it off. (absoluteAltitude survived at
        //    ~3 Hz even under Low Power, which is why it is the default source.)
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            onWarning("Low Power Mode is ON — turn it off for accurate jump detection.")
        }
        // ── 200 Hz batched device motion (Series 8+) — the TIMING sensor.
        //    userAcceleration (gravity removed) keeps |a| on the SAME scale every
        //    threshold in this engine was calibrated on (the logs' `aM` column).
        //    200 Hz resolves the take-off yank / landing contact to ±5 ms — the
        //    800 Hz raw-accelerometer stream is available too, but its |a|
        //    includes gravity (≈1 g at rest) and would shift all thresholds. ──
        guard CMBatchedSensorManager.isDeviceMotionSupported else {
            throw NSError(domain: "V12", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "CMBatchedSensorManager unavailable — needs Series 8+ / watchOS 10+ and an active HKWorkoutSession"])
        }
        accelTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            do {
                for try await batch in self.batched.deviceMotionUpdates() {
                    for m in batch {
                        let u = m.userAcceleration
                        let aMag = (u.x * u.x + u.y * u.y + u.z * u.z).squareRoot()
                        self.pipeline.addAccel(t: m.timestamp, aMag: aMag)
                    }
                }
            } catch { /* stream ended (workout stopped) */ }
        }

        // ── ~1 Hz relative altitude — the HEIGHT sensor. Log every callback with
        //    ITS OWN timestamp; never poll, never resample. ──
        guard CMAltimeter.isRelativeAltitudeAvailable() else {
            throw NSError(domain: "V12", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "CMAltimeter unavailable"])
        }
        altimeter.startRelativeAltitudeUpdates(to: altQueue) { [weak self] data, _ in
            guard let self, let d = data else { return }
            // O(1) handler — feed EVERY callback with the sensor's own timestamp.
            let t = d.timestamp
            let relAlt = d.relativeAltitude.doubleValue
            let pressureHpa = d.pressure.doubleValue * 10.0 // kPa → hPa

            // pressure-derived relative altitude (anchored to the first sample):
            // Δh ≈ −8.43 m/hPa · (p − p0) near sea level — a lower-lag candidate.
            if self.pressureAnchorHpa == nil { self.pressureAnchorHpa = pressureHpa }
            let pDerivedRelAlt = -(pressureHpa - (self.pressureAnchorHpa ?? pressureHpa)) * 8.43

            // feed the pipeline from this stream only when it is the chosen source
            // (absolute is fed from its own, faster stream below).
            if self.baroSource == .relativeAltitude { self.pipeline.addBaro(t: t, relAltM: relAlt) }
            else if self.baroSource == .pressureDerived { self.pipeline.addBaro(t: t, relAltM: pDerivedRelAlt) }
            self.recordBaro?(t, relAlt, pressureHpa) // LOG5: rel + pressure, for the lag comparison

            if self.baroSource != .absoluteAltitude { self.tickBaroHz(t) }
        }

        // ── ABSOLUTE altitude — a SEPARATE, field-observed FASTER stream. Its slow
        //    sea-level reference offset cancels against the per-jump water anchor,
        //    so feeding it as the height source surfaces the barometer's fast delta
        //    with the least lag. This is the likely path to Surfr's 3–5 s accuracy. ──
        if CMAltimeter.isAbsoluteAltitudeAvailable() {
            altimeter.startAbsoluteAltitudeUpdates(to: altQueue) { [weak self] data, _ in
                guard let self, let d = data else { return }
                let t = d.timestamp
                let absM = d.altitude
                if self.absAnchorM == nil { self.absAnchorM = absM }
                // feed relative-to-session-start; the per-jump anchor cancels the rest
                if self.baroSource == .absoluteAltitude {
                    self.pipeline.addBaro(t: t, relAltM: absM - (self.absAnchorM ?? absM))
                    self.tickBaroHz(t)
                }
                self.recordAbsAlt?(t, absM, d.accuracy, d.precision) // LOG5: the fast channel
            }
        } else if baroSource == .absoluteAltitude {
            // absolute unavailable on this device → fall back to pressure-derived
            baroSource = .pressureDerived
        }

        // ── STATUS 0.5 Hz — the throttling state that DECIDES whether we actually
        //    receive the ~1 Hz baro (a suspended / Low-Power / thermally-throttled
        //    watch silently drops to 0.36 Hz). Recording it is how we PROVE max rate. ──
        statusTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let thermal: Int
            switch ProcessInfo.processInfo.thermalState {
            case .nominal: thermal = 0
            case .fair: thermal = 1
            case .serious: thermal = 2
            case .critical: thermal = 3
            @unknown default: thermal = 0
            }
            let low = ProcessInfo.processInfo.isLowPowerModeEnabled
            var batt = -1
            #if os(watchOS)
            WKInterfaceDevice.current().isBatteryMonitoringEnabled = true
            let lvl = WKInterfaceDevice.current().batteryLevel
            if lvl >= 0 { batt = Int((lvl * 100).rounded()) }
            #endif
            self.recordStatus?(ProcessInfo.processInfo.systemUptime, thermal, low, batt,
                               self.baroSource == .pressureDerived ? 1 : 0, self.baroHzEwma)
        }

        // ── GPS 1 Hz: planing gate + jump distance ──
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBest
        location.activityType = .otherNavigation
        location.startUpdatingLocation()

        // ── OPTIONAL Ultra bonus: hardware out-of-water events (never required) ──
        if CMWaterSubmersionManager.waterSubmersionAvailable {
            let m = CMWaterSubmersionManager()
            m.delegate = self
            submersion = m
        }
    }

    public func stop() {
        accelTask?.cancel()
        statusTimer?.invalidate(); statusTimer = nil
        altimeter.stopRelativeAltitudeUpdates()
        altimeter.stopAbsoluteAltitudeUpdates()
        location.stopUpdatingLocation()
        submersion = nil
        pipeline.flush(t: ProcessInfo.processInfo.systemUptime)
    }

    /// rolling altimeter cadence (EWMA) for the STATUS / acceptance check.
    private func tickBaroHz(_ t: TimeInterval) {
        if lastBaroT >= 0 {
            let hz = 1.0 / max(0.05, t - lastBaroT)
            baroHzEwma = baroHzEwma == 0 ? hz : 0.7 * baroHzEwma + 0.3 * hz
        }
        lastBaroT = t
    }

    // CLLocation timestamps are wall-clock — convert to the boot-monotonic clock
    // the motion streams use, so all streams share one timeline.
    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        for l in locations {
            let tMono = l.timestamp.timeIntervalSince1970 - bootWallClock
            pipeline.addLocation(t: tMono, lat: l.coordinate.latitude,
                                 lng: l.coordinate.longitude, speedMs: max(l.speed, 0))
        }
    }
}

@available(watchOS 10.0, *)
extension JumpSessionV12: CMWaterSubmersionManagerDelegate {
    public func manager(_ manager: CMWaterSubmersionManager, didUpdate event: CMWaterSubmersionEvent) {
        let t = ProcessInfo.processInfo.systemUptime
        pipeline.addSubmersion(t: t, submerged: event.state == .submerged)
    }
    public func manager(_ manager: CMWaterSubmersionManager, didUpdate measurement: CMWaterSubmersionMeasurement) {}
    public func manager(_ manager: CMWaterSubmersionManager, didUpdate measurement: CMWaterTemperature) {}
    public func manager(_ manager: CMWaterSubmersionManager, errorOccurred error: Error) {}
}
