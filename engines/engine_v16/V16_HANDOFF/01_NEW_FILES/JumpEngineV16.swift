//
//  JumpEngineV16.swift
//  Kiters Watch App
//
//  V16 — big-air-first jump engine. Swift twin of core/jumpEngineV16.ts; the
//  two must stay behaviourally identical (same replay, same numbers).
//
//  V16 abandons the barometer as a height source and reconstructs the vertical
//  channel from the IMU alone. Every decision below is backed by a measurement
//  on log 287 (14 Surfr goldens, 2.1–8.5 m) and a negative-control session
//  (693 s of pops and waves containing ZERO real jumps):
//
//   1. TRIGGER — a pop >= popMinG. Big-air takeoffs are NOT violent: the
//      goldens measured 1.4–4.7 g, so V15's 3.0 g floor discarded half of them.
//
//   2. CONFIRM — the LIFT PLATEAU. During a kite jump the canopy pulls the
//      rider up for a full second or more and world-vertical acceleration
//      stays positive in a sustained shelf. A wave or chop bump is an impulse
//      that is over within 0.6 s. Measured: real jumps 0.9–2.8 s of shelf,
//      control session max 0.6 s across 19 pops. At the 0.9 s threshold this
//      one test keeps 14/14 real jumps and admits 0/19 control pops — the
//      phantom firewall, no GPS needed.
//
//   3. HEIGHT — bounded double integration of world-vertical acceleration over
//      a FIXED window around the pop, with z(0)=z(T)=0. The apex is then a
//      LINEAR FUNCTIONAL of the acceleration with support T, and two jumps
//      compare only if the SAME functional is applied — i.e. the same T. With
//      a per-jump window (even the TRUE airtime) each jump gets a different
//      operator and the correlation collapses to r~0; with the fixed window
//      it is r=0.95. This is a matched filter, not a
//      trajectory reconstruction, and its output is mapped to metres by a
//      linear calibration. Validated: MAE 0.52 m over all 14 goldens spanning
//      2.1–8.5 m (LOO 0.57 m on the 12-jump subset it was fitted on); adding
//      the two largest goldens did not move the slope.
//
//   4. AIRTIME — LOW CONFIDENCE. The landing rule tracks shelf -> dip ->
//      sustained float, but its measured MAE is 0.54 s while a constant
//      predictor scores 0.78 s, so it barely beats a constant. Never gate on
//      `airtimeSec`; show it with a caveat or not at all.
//
//   5. DISTANCE — derived, so it INHERITS the airtime error: haversine between
//      the GPS fix before the pop and the one at the estimated landing. With
//      the true airtime it measures 2.78 m MAE; with V16's own airtime, 6.27 m
//      (0.54 s x ~8 m/s). takeoffSpeedMS by contrast is read straight from GPS
//      before the pop and is accurate to 0.64 m/s.
//
//  NOT used, and why (measured, not assumed):
//   • absoluteAltitude — passes a health gate on only 7/21 goldens and, even
//     when it passes, produced −6.4 m and −2.1 m errors (a negative apex for a
//     real jump = water over the port). Nothing available predicts when it is
//     trustworthy, so fusing it injects metre-scale error into a 0.57 m
//     estimator.
//   • relativeAltitude / raw pressure — alive (71 % distinct, max 5 s freeze)
//     but useless per jump: 67 of the 68 inter-sample steps above 3 m fall
//     OUTSIDE any jump. Noise exceeds signal in the same band, so no filter or
//     drift reset recovers it (measured r = 0.19–0.31).
//
//  SCOPE: V16 is tuned for big air. On small-jump sessions (1.3–2.5 m) its
//  recall is low by design; keep JumpEngineV15 for those until a combined
//  operating point is validated.
//
//  SAMPLE RATE: the calibration was fitted on 200 Hz logs. MotionSampler runs
//  at 50 Hz; a trapezoidal double integral is insensitive to that, but the
//  calibration should be re-checked if the rate changes.
//
//  INPUT DOMAIN: `loadG` is |userAcceleration| in g (gravity removed, ~0 at
//  rest) — the same quantity MotionSampler already publishes. `accel` is the
//  device-frame userAcceleration in g and `quat` the attitude quaternion;
//  both are required for height. Attitude gaps are tolerated in the wide
//  shelf/landing scan (a gap breaks any lift run through it) but NOT inside the
//  apex window, where the integral cannot bridge a hole.
//

import Foundation

// MARK: - Configuration

public struct V16Config {
    /// Takeoff pop floor (g). Goldens measured 1.4–4.7 g.
    public var popMinG = 1.4
    /// Two pops closer than this are one takeoff; the stronger anchors t0.
    public var popClusterSec: TimeInterval = 2.0

    /// World-vertical acceleration above this counts as lift (m/s²).
    public var liftThreshMS2 = 1.5
    /// Half-width of the box smoother applied to the lift signal (s).
    public var liftSmoothSec: TimeInterval = 0.2
    /// The phantom firewall: required continuous lift shelf (s).
    /// Swept over four logs: 0.9 keeps 14/14 big air with ZERO control false
    /// positives; 0.6 admits the first control phantom, 1.0 costs a real jump.
    public var minLiftPlateauSec: TimeInterval = 0.9
    /// How far past the pop the shelf is searched for (s).
    public var plateauScanSec: TimeInterval = 8.0

    /// Fixed apex window before/after the pop (s). Do NOT tune without
    /// re-fitting heightScale/heightOffsetM — the calibration is tied to it.
    public var apexPreSec: TimeInterval = 2.5
    public var apexPostSec: TimeInterval = 2.0
    /// height = heightScale * apex + heightOffsetM
    public var heightScale = 1.91
    public var heightOffsetM = 1.50

    /// Jumps below this are not reported (m).
    public var minReportM = 1.5
    /// Emissions closer than this are the same jump; the higher wins.
    public var dedupSec: TimeInterval = 8.0
    /// A candidate is judged this long after its pop — covers the shelf scan
    /// and the landing search.
    public var evalDelaySec: TimeInterval = 9.0

    // Landing / airtime (low confidence — see file header).
    public var landLiftThreshMS2 = 0.5
    public var landMinPlateauSec: TimeInterval = 0.4
    public var landDipMS2 = -1.0
    public var landSettleFrac = 0.6
    public var landSettleSec: TimeInterval = 1.0
    public var landOffsetSec: TimeInterval = 0.4
    /// |a| at or below this counts as free-flight float (g).
    public var floatLoadG = 0.6

    /// Largest tolerated hole between two attitude-carrying samples inside the
    /// apex window (s). Scattered jitter is integrated straight through — the
    /// trapezoid rule handles uneven spacing — but a hole longer than this
    /// cannot be integrated across and rejects the candidate. 0.15 s = 7 missed
    /// samples at the watch's 50 Hz.
    public var maxAttitudeGapSec: TimeInterval = 0.15
    /// Ring horizon (s). Must exceed apexPreSec + evalDelaySec.
    public var historySec: TimeInterval = 14.0

    public init() {}
}

// MARK: - Output

public struct V16Jump {
    /// Calibrated height (m).
    public let heightM: Double
    /// Raw matched-filter apex before calibration (m) — diagnostics only.
    public let apexRawM: Double
    /// LOW CONFIDENCE (see header). nil when the landing was never resolved.
    public let airtimeSec: Double?
    public let takeoffT: TimeInterval
    /// Measured lift-shelf length (s) — the confirmation statistic.
    public let liftPlateauSec: Double
    public let yankG: Double
    public let peakG: Double
    public let floatFraction: Double
    public let maxGyroRadS: Double
    public let takeoffSpeedMS: Double?
    public let distanceM: Double?
    /// 0.75 with a strong shelf, 0.55 at the threshold.
    public let confidence: Double
}

public protocol JumpEngineV16Delegate: AnyObject {
    func jumpDetected(_ jump: V16Jump)
}

// MARK: - Engine

public final class JumpEngineV16 {

    public weak var delegate: JumpEngineV16Delegate?
    /// Diagnostics sink. Keep it cheap — it is called on the sampling queue.
    public var onDebug: (TimeInterval, String) -> Void = { _, _ in }

    private let cfg: V16Config
    private let g0 = 9.80665

    private struct Sample {
        let t: TimeInterval
        let load: Double
        /// World-vertical acceleration (m/s²); .nan when attitude was absent.
        let az: Double
        let gyro: Double
    }
    private struct GpsPt {
        let t: TimeInterval
        let lat: Double
        let lng: Double
        let spd: Double
    }
    private struct Candidate {
        var t0: TimeInterval
        var yankG: Double
    }

    private var ring: [Sample] = []
    private var ringHead = 0            // index of the first live element
    private var gpsHistory: [GpsPt] = []
    private var pending: [Candidate] = []
    private var lastImuT: TimeInterval = -.infinity
    private var lastGpsT: TimeInterval = -.infinity

    /// A confirmed jump is HELD before delivery: one takeoff raises several
    /// pops (a weak precursor, then the real load) and only the strongest may
    /// reach the consumer. Emitting immediately and "superseding" afterwards
    /// would deliver both.
    private var held: (jump: V16Jump, until: TimeInterval)?

    public init(_ cfg: V16Config = V16Config()) {
        self.cfg = cfg
        ring.reserveCapacity(4096)
        gpsHistory.reserveCapacity(256)
    }

    // MARK: Inputs

    /// - Parameters:
    ///   - loadG: |userAcceleration| in g (gravity removed).
    ///   - accel: device-frame userAcceleration in g — required for height.
    ///   - quat:  attitude quaternion (w, x, y, z) — required for height.
    public func addIMU(t: TimeInterval,
                       loadG: Double,
                       gyroRadS: Double = 0,
                       accel: (x: Double, y: Double, z: Double)? = nil,
                       quat: (w: Double, x: Double, y: Double, z: Double)? = nil) {
        guard t.isFinite, loadG.isFinite, t > lastImuT else { return }
        lastImuT = t

        let load = abs(loadG)
        var az = Double.nan
        if let accel, let quat {
            az = g0 * Self.worldZ(quat, accel.x, accel.y, accel.z)
        }
        ring.append(Sample(t: t, load: load, az: az, gyro: gyroRadS.isFinite ? gyroRadS : 0))
        trimRing(before: t - cfg.historySec)

        // Pop clustering: the strongest sample inside popClusterSec anchors t0.
        if load >= cfg.popMinG {
            if var last = pending.last, t - last.t0 < cfg.popClusterSec {
                if load > last.yankG {
                    last.t0 = t
                    last.yankG = load
                    pending[pending.count - 1] = last
                }
            } else {
                pending.append(Candidate(t0: t, yankG: load))
            }
        }

        // Judge candidates whose evaluation window has fully arrived. A pop may
        // have moved t0 forward while clustering, so re-check before removing.
        while let first = pending.first, t - first.t0 >= cfg.evalDelaySec {
            pending.removeFirst()
            evaluate(first, now: t)
        }

        releaseHeld(now: t)
    }

    public func addGPS(t: TimeInterval, lat: Double, lng: Double, speedMS: Double) {
        guard t.isFinite, t > lastGpsT else { return }
        lastGpsT = t
        gpsHistory.append(GpsPt(t: t, lat: lat, lng: lng, spd: max(0, speedMS)))
        while let f = gpsHistory.first, f.t < t - 120 { gpsHistory.removeFirst() }
    }

    /// Session end: judge everything still pending and release the held jump.
    public func flush(now: TimeInterval) {
        let rest = pending
        pending.removeAll(keepingCapacity: true)
        for c in rest { evaluate(c, now: now) }
        releaseHeld(now: .infinity)
    }

    // MARK: Ring maintenance

    /// Amortised O(1) eviction: advance a head index and compact only when the
    /// dead prefix grows large, so a 50 Hz feed never memmoves per sample.
    private func trimRing(before cutoff: TimeInterval) {
        while ringHead < ring.count, ring[ringHead].t < cutoff { ringHead += 1 }
        if ringHead > 2048 {
            ring.removeFirst(ringHead)
            ringHead = 0
        }
    }

    // MARK: Evaluation

    private func evaluate(_ c: Candidate, now: TimeInterval) {
        let t0 = c.t0

        // 1. Lift shelf — the phantom firewall.
        guard let bins = liftBins(from: t0 - cfg.apexPreSec, to: t0 + cfg.plateauScanSec) else {
            onDebug(now, "REJECT t0=\(fmt(t0)) reason=noAttitude")
            return
        }
        let shelf = Self.longestRun(bins.az, bins.t, from: t0, above: cfg.liftThreshMS2)
        guard shelf >= cfg.minLiftPlateauSec else {
            onDebug(now, "REJECT t0=\(fmt(t0)) reason=noLiftPlateau shelf=\(fmt(shelf))s yank=\(fmt(c.yankG))g")
            return
        }

        // 2. Height from the fixed-support matched filter.
        guard let apex = apex(from: t0 - cfg.apexPreSec, span: cfg.apexPreSec + cfg.apexPostSec) else {
            onDebug(now, "REJECT t0=\(fmt(t0)) reason=apexWindowIncomplete")
            return
        }
        let heightM = cfg.heightScale * apex + cfg.heightOffsetM
        guard heightM >= cfg.minReportM else {
            onDebug(now, "REJECT t0=\(fmt(t0)) reason=belowMinReport h=\(fmt(heightM))m")
            return
        }

        // 3. Airtime (low confidence).
        let landingT = landing(bins, t0: t0)

        // 4. Flight statistics.
        let tEnd = landingT ?? (t0 + cfg.apexPostSec)
        var peakG = 0.0, maxGyro = 0.0, floatN = 0, n = 0
        for i in ringHead..<ring.count {
            let s = ring[i]
            if s.t < t0 { continue }
            if s.t > tEnd { break }
            n += 1
            peakG = max(peakG, s.load)
            maxGyro = max(maxGyro, s.gyro)
            if s.load <= cfg.floatLoadG { floatN += 1 }
        }
        let launch = gpsPoint(near: t0 - 1.0)
        let land = gpsPoint(near: tEnd)
        var distanceM: Double?
        if let launch, let land, (launch.lat != 0 || launch.lng != 0), (land.lat != 0 || land.lng != 0) {
            distanceM = Self.haversineM(launch.lat, launch.lng, land.lat, land.lng)
        } else if let launch, let landingT {
            distanceM = launch.spd * (landingT - t0)
        }

        let jump = V16Jump(
            heightM: round2(heightM),
            apexRawM: round2(apex),
            airtimeSec: landingT.map { round2($0 - t0) },
            takeoffT: t0,
            liftPlateauSec: round2(shelf),
            yankG: round2(c.yankG),
            peakG: round2(peakG),
            floatFraction: n > 0 ? round2(Double(floatN) / Double(n)) : 0,
            maxGyroRadS: round2(maxGyro),
            takeoffSpeedMS: launch.map { round2($0.spd) },
            distanceM: distanceM.map(round2),
            confidence: shelf >= cfg.minLiftPlateauSec * 1.5 ? 0.75 : 0.55
        )

        // 5. Dedup: one takeoff raises several pops — hold, keep the strongest.
        if let h = held, t0 - h.jump.takeoffT < cfg.dedupSec {
            if heightM <= h.jump.heightM {
                onDebug(now, "MERGE t0=\(fmt(t0)) into \(fmt(h.jump.takeoffT)) (\(fmt(heightM))m <= \(fmt(h.jump.heightM))m)")
                held = (h.jump, holdUntil(t0))
                return
            }
            onDebug(now, "MERGE t0=\(fmt(h.jump.takeoffT)) into \(fmt(t0)) (\(fmt(h.jump.heightM))m < \(fmt(heightM))m)")
            held = nil
        }
        releaseHeld(now: .infinity)   // anything older than the dedup span is final
        held = (jump, holdUntil(t0))
    }

    /// A rival pop up to dedupSec after `t0` is itself judged evalDelaySec after
    /// ITS pop, so the hold must span both delays or it expires before the rival
    /// is even evaluated.
    private func holdUntil(_ t0: TimeInterval) -> TimeInterval {
        t0 + cfg.dedupSec + cfg.evalDelaySec
    }

    /// Deliver a held jump once no later pop can still supersede it.
    private func releaseHeld(now: TimeInterval) {
        guard let h = held, now >= h.until else { return }
        held = nil
        delegate?.jumpDetected(h.jump)
        onDebug(now, "JUMP t0=\(fmt(h.jump.takeoffT)) h=\(fmt(h.jump.heightM))m "
            + "shelf=\(fmt(h.jump.liftPlateauSec))s "
            + "air=\(h.jump.airtimeSec.map(fmt) ?? "n/a")s yank=\(fmt(h.jump.yankG))g")
    }

    // MARK: Signal helpers

    private struct Bins {
        let t: [TimeInterval]
        let az: [Double]
        let fl: [Double]
    }

    /// 0.1 s bins of world-vertical acceleration and float fraction, smoothed.
    /// Returns nil when any bin lacks attitude — height would be meaningless.
    private func liftBins(from: TimeInterval, to: TimeInterval) -> Bins? {
        let step = 0.1
        let nBins = Int(((to - from) / step).rounded())
        guard nBins >= 10 else { return nil }

        var azRaw = [Double](repeating: 0, count: nBins)
        var flRaw = [Double](repeating: 0, count: nBins)
        var cnt = [Int](repeating: 0, count: nBins)
        var attCnt = [Int](repeating: 0, count: nBins)
        for i in ringHead..<ring.count {
            let s = ring[i]
            if s.t < from { continue }
            if s.t >= to { break }
            let k = Int((s.t - from) / step)
            guard k >= 0, k < nBins else { continue }
            if s.az.isFinite { azRaw[k] += s.az; attCnt[k] += 1 }
            if s.load <= cfg.floatLoadG { flRaw[k] += 1 }
            cnt[k] += 1
        }
        // A bin with no attitude sample becomes NaN, which breaks any lift run
        // passing through it (a shelf cannot be verified across a gap) without
        // discarding the whole evaluation. The apex window is protected
        // separately and far more strictly: apex() refuses if ANY of its
        // samples lacks attitude, because an integral cannot bridge a hole.
        //   (An earlier version compared the total attitude SAMPLE count to the
        //   BIN count — at 200 Hz that is 2100 vs 105, so the guard passed even
        //   when most samples had no attitude; and requiring every bin outright
        //   let one dropped 0.1 s of CMDeviceMotion silently kill a real jump.)
        var t = [TimeInterval](repeating: 0, count: nBins)
        for k in 0..<nBins {
            t[k] = from + Double(k) * step
            azRaw[k] = attCnt[k] > 0 ? azRaw[k] / Double(attCnt[k]) : Double.nan
            flRaw[k] = cnt[k] > 0 ? flRaw[k] / Double(cnt[k]) : 0
        }
        let w = max(0, Int((cfg.liftSmoothSec / step).rounded()))
        return Bins(t: t, az: Self.boxSmooth(azRaw, halfWidth: w), fl: Self.boxSmooth(flRaw, halfWidth: 5))
    }

    /// Landing: lift shelf opens and closes, then the first dip, confirmed by
    /// sustained float after it. LOW CONFIDENCE — see the file header.
    private func landing(_ bins: Bins, t0: TimeInterval) -> TimeInterval? {
        var i0 = 0
        while i0 < bins.t.count, bins.t[i0] < t0 { i0 += 1 }

        var plateauEnd = -1
        var run = 0
        var i = i0
        while i < bins.t.count {
            if bins.az[i] > cfg.landLiftThreshMS2 {
                run += 1
            } else {
                if Double(run) * 0.1 >= cfg.landMinPlateauSec { plateauEnd = i; break }
                run = 0
            }
            i += 1
        }
        guard plateauEnd >= 0 else { return nil }

        let settleFrom = Int((1.0 / 0.1).rounded())
        let settleLen = Int((cfg.landSettleSec / 0.1).rounded())
        var j = plateauEnd
        while j < bins.t.count {
            defer { j += 1 }
            guard bins.az[j] < cfg.landDipMS2 else { continue }   // NaN gap is not a dip
            let a = j + settleFrom, b = a + settleLen
            guard b < bins.t.count else { return nil }
            var settled = true
            for k in a..<b where bins.fl[k] < cfg.landSettleFrac { settled = false; break }
            if settled { return bins.t[j] + cfg.landOffsetSec }
        }
        return nil
    }

    /// Bounded double integration over [from, from+span] with z(0)=z(T)=0.
    ///
    ///   a_meas = a_true + b          (b = constant bias: attitude error,
    ///                                 sensor offset, gravity residual)
    ///   W(t)   = II a_meas          = z_true(t) + v0*t + 0.5*b*t^2
    ///   z(t)   = W(t) - (t/T)*W(T)  forces z(0)=z(T)=0
    ///          = z_true(t) - (t/T)*z_true(T) + 0.5*b*t*(t-T)
    ///
    /// The unknown initial vertical velocity v0 cancels EXACTLY (it is linear
    /// in t). The bias term becomes 0.5*b*t*(t-T): zero at both ends, extremum
    /// -b*T^2/8 at midpoint. A bias that would otherwise diverge quadratically
    /// is BOUNDED by b*T^2/8 — with T=4.5 s that is 2.5*b, so 0.1 m/s^2 of bias
    /// costs 0.25 m. No bias estimation is needed.
    private func apex(from: TimeInterval, span: TimeInterval) -> Double? {
        let to = from + span
        // Collect the attitude-carrying samples in the window. Scattered
        // dropouts are integrated through with their real spacing; only a hole
        // longer than maxAttitudeGapSec is unbridgeable.
        var ts: [TimeInterval] = []
        var azs: [Double] = []
        ts.reserveCapacity(1024)
        azs.reserveCapacity(1024)
        for i in ringHead..<ring.count {
            let s = ring[i]
            if s.t < from { continue }
            if s.t > to { break }
            guard s.az.isFinite else { continue }
            if let lastT = ts.last, s.t - lastT > cfg.maxAttitudeGapSec { return nil }
            ts.append(s.t)
            azs.append(s.az)
        }
        let n = ts.count
        guard n >= 20 else { return nil }
        // the window must also be covered at its edges, not just in the middle
        guard ts[0] - from <= cfg.maxAttitudeGapSec else { return nil }
        guard to - ts[n - 1] <= cfg.maxAttitudeGapSec else { return nil }

        var W = [Double](repeating: 0, count: n)
        var Ts = [Double](repeating: 0, count: n)
        var v = 0.0, z = 0.0
        let t0 = ts[0]
        for i in 0..<n {
            let dt = i == 0 ? 0 : ts[i] - ts[i - 1]
            v += azs[i] * dt
            z += v * dt
            W[i] = z
            Ts[i] = ts[i] - t0
        }
        let tf = Ts[n - 1]
        guard tf > 0 else { return nil }
        let wt = W[n - 1]
        var apex = -Double.infinity
        for i in 0..<n {
            let q = W[i] - (Ts[i] / tf) * wt
            if q > apex { apex = q }
        }
        return apex.isFinite ? apex : nil
    }

    private func gpsPoint(near t: TimeInterval) -> GpsPt? {
        var best: GpsPt?
        var bd = 3.0
        for g in gpsHistory {
            let d = abs(g.t - t)
            if d < bd { bd = d; best = g }
        }
        return best
    }

    // MARK: Static maths

    /// World-Z component of a device-frame vector rotated by the attitude quaternion.
    private static func worldZ(_ q: (w: Double, x: Double, y: Double, z: Double),
                               _ vx: Double, _ vy: Double, _ vz: Double) -> Double {
        2 * (q.x * q.z - q.w * q.y) * vx
            + 2 * (q.y * q.z + q.w * q.x) * vy
            + (1 - 2 * (q.x * q.x + q.y * q.y)) * vz
    }

    private static func boxSmooth(_ src: [Double], halfWidth: Int) -> [Double] {
        let n = src.count
        guard halfWidth > 0, n > 0 else { return src }
        var out = [Double](repeating: 0, count: n)
        var sum = 0.0
        for i in 0...min(n - 1, halfWidth) { sum += src[i] }
        for i in 0..<n {
            let lo = i - halfWidth, hi = i + halfWidth
            out[i] = sum / Double(min(n - 1, hi) - max(0, lo) + 1)
            if hi + 1 < n { sum += src[hi + 1] }
            if lo >= 0 { sum -= src[lo] }
        }
        return out
    }

    /// Longest continuous run above `thresh` from `from` onward, in seconds.
    /// Counted in whole BINS and scaled once: accumulating 0.1 ten times gives
    /// 0.9999999999999999, which silently failed a `>= 1.0` shelf gate.
    private static func longestRun(_ az: [Double], _ t: [TimeInterval],
                                   from: TimeInterval, above thresh: Double) -> Double {
        var best = 0, run = 0
        for i in 0..<az.count {
            if t[i] < from { continue }
            // NaN (an attitude gap) fails the comparison and resets the run —
            // a shelf is never credited across a hole.
            if az[i] > thresh {
                run += 1
                if run > best { best = run }
            } else {
                run = 0
            }
        }
        return Double(best) * 0.1
    }

    private static func haversineM(_ lat1: Double, _ lng1: Double,
                                   _ lat2: Double, _ lng2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLng = (lng2 - lng1) * .pi / 180
        let h = pow(sin(dLat / 2), 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * pow(sin(dLng / 2), 2)
        return 2 * r * asin(min(1, h.squareRoot()))
    }

    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
    private func fmt(_ v: Double) -> String { String(format: "%.2f", v) }
}
