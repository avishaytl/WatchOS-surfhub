// ================================================================
//  KitesurfJumpEngine.swift
//  Apple Watch S9 · Kitesurf Jump Engine — v7 (sensor-grounded)
//
//  ════════════════════════════════════════════════════════════════
//  WHY v7 IS DIFFERENT FROM THE "v6 baro-primary" PORT
//  ════════════════════════════════════════════════════════════════
//  Real watch logs (calib-log, 50Hz, S9) prove two hard facts that
//  the simulator-tuned v6 algorithm got wrong:
//
//    1. The watch barometer CANNOT see a ≤4 m jump.
//       Measured quantum ≈ 0.01 hPa ≈ 8 cm/step, ZOH-held for
//       ~0.3–0.5 s at a time. A 4 m jump (ΔP≈0.47 hPa) produced
//       NO measurable drop in the real log. So baro must NOT be the
//       primary height source for small/medium jumps — it is only
//       trustworthy once ΔP rises well clear of the noise floor
//       (≈0.06 hPa ≈ 50 cm), which happens on big (kite-lofted)
//       jumps. Below that we use time-of-flight (kinematic).
//
//    2. userAcceleration has gravity REMOVED, so a watch sitting
//       STILL reads |a|≈0 g — identical to true free-fall. You
//       therefore CANNOT detect "airborne" from a low-g threshold
//       alone (the old lowGCeiling=0.4 g approach is unreliable on
//       a wrist). Detection here is TRANSITION-based:
//          release spike → ballistic phase → landing spike/settle,
//       with the gyroscope as the discriminator (a real take-off and
//       in-air rotation carry high ω; a watch resting on a table
//       does not).
//
//  HEIGHT STRATEGY — adaptive hybrid:
//       small jump  → kinematic (g·t²/8) from air time
//       big   jump  → barometric (ΔP·8.43) once ΔP is significant
//       between     → trust-weighted blend
//
//  KITE-AWARE EVENT MODEL (wrist-mounted, choppy sea, hand moving):
//       • adaptive ride baseline (μ,σ of recent |a|) → spike floor
//         rides with the chop instead of a fixed 1.5 g threshold.
//       • freezing baro baseline only during the jump, slow EMA
//         otherwise → survives weather/thermal drift over a session.
//       • landing = impact spike OR baro recovery OR sustained
//         settle — covers HARD landings, SOFT landings, and long
//         kite glides (watchdog).
//       • gyro integral → rotation count (spins).
//       • refractory window after each jump → no double-count on
//         landing bounce.
//
//  Data flow (unchanged, correct):
//       50 Hz CoreMotion ─┐
//                         ├─► KitesurfSession.onSample (streaming FSM)
//       1 Hz CoreLocation ┘            │ on landing
//                                      ▼
//                         KitesurfJumpEngineV7.process (offline, <10 ms)
//                                      ▼
//                         JumpResult ──► Watch UI (~0.6 s after landing)
//
//  UNITS (watch-native — see surfhub-watch/core/types.ts):
//       accel  : g, gravity REMOVED (userAcceleration)
//       gyro   : rad/s
//       gravity: g (unit-ish vector)
//       baro   : hPa
// ================================================================

import Foundation

// ================================================================
// MARK: - Constants
// ================================================================
private enum K {
    static let g: Double          = 9.81
    static let p2m: Double        = 8.43       // hPa → metres (sea level)
    static let sampleRate: Double = 50.0
    static let dt: Double         = 1.0 / 50.0
    static let ms2kn: Double      = 1.94384
    static let ms2kmh: Double     = 3.6
    static let deg2rad: Double    = .pi / 180.0
    static let twoPi: Double      = 2.0 * .pi
}

// ================================================================
// MARK: - Sensor Sample (watch-native units)
// ================================================================
struct SensorSample {
    /// Monotonic seconds since session start (use CMDeviceMotion.timestamp,
    /// NOT wall-clock — wall-clock is non-monotonic under NTP correction).
    let t: Double

    /// Linear acceleration in g, gravity already removed (userAcceleration).
    let ax, ay, az: Double
    /// Optional precomputed |a| in g. If nil it is derived from ax/ay/az.
    let aM: Double?

    /// Gyroscope in rad/s.
    let gx, gy, gz: Double
    /// Optional precomputed |ω| in rad/s.
    let gM: Double?

    /// Gravity unit-ish vector in g (for projecting vertical accel).
    let gravX, gravY, gravZ: Double

    /// Barometric pressure in hPa (nil when no fresh baro sample).
    let baro: Double?

    /// GPS (nil between 1 Hz updates).
    let gpsSpeedMS: Double?
    let gpsLat: Double?
    let gpsLon: Double?
    let gpsAccuracyM: Double?

    /// |a| in g, derived if not provided.
    var accelMagG: Double { aM ?? (ax * ax + ay * ay + az * az).squareRoot() }
    /// |ω| in rad/s, derived if not provided.
    var gyroMag: Double { gM ?? (gx * gx + gy * gy + gz * gz).squareRoot() }
}

// ================================================================
// MARK: - Jump Result
// ================================================================
struct JumpResult {
    let jumpHeightMeters: Double        // fused (kinematic ⇄ baro, adaptive)
    let baroHeightMeters: Double        // barometric estimate (may be ~0)
    let kinematicHeightMeters: Double   // time-of-flight estimate
    let airTimeSeconds: Double
    let apexTimeSeconds: Double?
    let rotations: Int                  // full 360° spins (gyro integral)
    let jumpDistanceMeters: Double?     // GPS speed × air time (primary)
    let jumpDistanceGPSMeters: Double?  // GPS position haversine (secondary)
    let maxSessionSpeedKnots: Double
    let maxSessionSpeedKmh: Double
    let confidence: Double              // 0…1
    let landingKind: LandingKind
    let heightSource: HeightSource
    // Diagnostics
    let deltaPressureHPa: Double
    let peakTakeoffG: Double
    let peakGyro: Double
    let avgGyroQuality: Double
    let takeoffIndex: Int
    let landingIndex: Int

    enum LandingKind: String { case hardImpact, baroRecovery, settle, timeout }
    enum HeightSource: String { case kinematic, barometric, blended }
}

// ================================================================
// MARK: - DSP Primitives
// ================================================================
enum DSP {

    /// Sliding-median spike removal.
    /// - causal=true : window [i-2w … i]  (real-time safe, ~w delay)
    /// - causal=false: window [i-w … i+w] (offline, zero-phase)
    static func medianFilter(_ data: [Double], halfWindow hw: Int, causal: Bool = false) -> [Double] {
        guard !data.isEmpty else { return [] }
        let w = max(1, hw)
        return data.indices.map { i in
            let lo: Int, hi: Int
            if causal { lo = max(0, i - 2 * w); hi = i }
            else      { lo = max(0, i - w);     hi = min(data.count - 1, i + w) }
            var slice = Array(data[lo...hi]); slice.sort()
            let m = slice.count / 2
            return slice.count % 2 == 0 ? (slice[m - 1] + slice[m]) / 2 : slice[m]
        }
    }

    /// First-order IIR low-pass.
    static func lowPass(_ data: [Double], alpha: Double) -> [Double] {
        guard !data.isEmpty else { return [] }
        let a = max(0.001, min(1.0, alpha))
        var out = [data[0]]; out.reserveCapacity(data.count)
        for i in 1..<data.count { out.append(a * data[i] + (1 - a) * out[i - 1]) }
        return out
    }

    static func median(_ a: ArraySlice<Double>) -> Double { median(Array(a)) }
    static func median(_ a: [Double]) -> Double {
        guard !a.isEmpty else { return 0 }
        var s = a; s.sort(); let m = s.count / 2
        return s.count % 2 == 0 ? (s[m - 1] + s[m]) / 2 : s[m]
    }

    static func mean(_ a: ArraySlice<Double>) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
    static func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }

    /// Sample standard deviation (population).
    static func std(_ a: ArraySlice<Double>) -> Double {
        guard a.count > 1 else { return 0 }
        let m = mean(a); return (a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(a.count)).squareRoot()
    }

    static func dot3(_ ax: Double, _ ay: Double, _ az: Double, _ bx: Double, _ by: Double, _ bz: Double) -> Double {
        ax * bx + ay * by + az * bz
    }
    static func normalize3(_ x: Double, _ y: Double, _ z: Double) -> (Double, Double, Double) {
        let m = (x * x + y * y + z * z).squareRoot()
        return m > 0.001 ? (x / m, y / m, z / m) : (0, 0, -1)
    }
    static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { max(lo, min(hi, v)) }
}

// ================================================================
// MARK: - GPS Utilities
// ================================================================
enum GPSUtil {
    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return r * 2 * atan2(a.squareRoot(), (1 - a).squareRoot())
    }
}

// ================================================================
// MARK: - V7 Offline Detector (sensor-grounded, adaptive hybrid)
//  Self-contained: derives its own pre-jump baseline + ride stats
//  from the captured buffer (first ~25% = pre-takeoff tail).
// ================================================================
final class KitesurfJumpEngineV7 {

    struct Config {
        // ── Baro pipeline ────────────────────────────────────────
        var baroMedianHalfWindow   = 7
        var baroLowPassAlpha1       = 0.30
        var baroLowPassAlpha2       = 0.15

        // ── Baro SIGNIFICANCE (sensor-grounded) ──────────────────
        // Real watch quantum ≈ 0.01 hPa. We require the drop to clear
        // the noise floor before barometric height is trusted at all.
        var baroNoiseFloorHPa       = 0.03   // ≈ 25 cm — below this baro is pure noise
        var baroTrustLoHPa          = 0.06   // ≈ 50 cm — baro starts to matter
        var baroTrustHiHPa          = 0.18   // ≈ 1.5 m — baro fully trusted

        // ── Event detection (adaptive, kite-aware) ───────────────
        var releaseSigmaK           = 3.5    // release spike = μ_ride + K·σ_ride …
        var releaseFloorG           = 1.30   // … but never below this (g)
        var landingSpikeG           = 1.60   // hard-landing impact (g)
        var settleTolG              = 0.35   // |a| within this of ride-mean = "settled"
        var settleSamplesNeeded     = 6      // of last 8 → soft landing
        var minAirTimeSec           = 0.30
        var maxAirTimeSec           = 14.0   // kite glide watchdog
        var minJumpHeightMeters     = 1.0    // ignore pop / wave-chop hops; real jumps ≥1 m

        // ── Gyro ─────────────────────────────────────────────────
        var gyroQualityThreshold    = 8.0    // rad/s — chaotic above (toss/tumble)
        var gyroIsDegPerSec: Bool?  = false  // watch reports rad/s; nil = auto-detect

        // ── Kinematic calibration ────────────────────────────────
        // Time-of-flight underestimates if release/land spikes clip the
        // true ballistic endpoints. >1 compensates. Tune from labelled logs.
        var kinematicCalibration    = 1.0

        var enableIMUBiasCorrection = true

        // ── KITE-AWARE HEIGHT (asymmetric arc) ───────────────────
        // A kite holds the rider up → descent LONGER than ascent, so total
        // airtime OVER-estimates height via symmetric g·t²/8. Height comes from
        // the RISE time (take-off → apex): h = ½·g·t_rise². The consistency gate
        // rejects a baro reading that exceeds the airtime envelope (drift/spike).
        var airtimeCeilingTolerance = 1.25  // baroH may exceed sym-kin height ≤ this×
        var maxPlausibleHeightM     = 500.0 // effectively uncapped
        var symmetricAscentFraction = 0.5   // ascent fraction when no apex found

        static let `default` = Config()
    }

    private let cfg: Config
    init(config: Config = .default) { self.cfg = config }

    // ── Public entry: analyse a captured jump buffer ─────────────
    func process(_ rawSamples: [SensorSample],
                 takeoffHint t0HintRaw: Int? = nil,
                 maxSessionSpeedMS: Double) -> JumpResult? {
        // Drop non-advancing timestamps (duplicate rows / stuttered batches
        // produce zero-dt gaps that corrupt the air-time integration) and remap
        // the take-off hint onto the deduped indices.
        let (samples, indexMap) = Self.dedupeByTime(rawSamples)
        let t0Hint: Int? = t0HintRaw.flatMap { ($0 >= 0 && $0 < indexMap.count) ? indexMap[$0] : nil }
        let n = samples.count
        guard n >= 12 else { return nil }
        let dt = estimateDt(samples)

        // ── BARO PIPELINE (median → LP1 → LP2). May be flat/absent. ──
        let haveBaro = samples.contains { $0.baro != nil }
        let baroRaw  = samples.map { $0.baro ?? Double.nan }
        let baroSmooth: [Double]
        if haveBaro {
            let filled = fillForward(baroRaw)
            let m  = DSP.medianFilter(filled, halfWindow: cfg.baroMedianHalfWindow)
            let p1 = DSP.lowPass(m,  alpha: cfg.baroLowPassAlpha1)
            baroSmooth = DSP.lowPass(p1, alpha: cfg.baroLowPassAlpha2)
        } else {
            baroSmooth = [Double](repeating: 0, count: n)
        }

        // ── ACCEL / GYRO magnitudes ───────────────────────────────
        let accMag = samples.map { $0.accelMagG }
        let gyroScale = resolveGyroScale(samples)
        let gyroMag = samples.map { $0.gyroMag * gyroScale }

        // ── RIDE BASELINE (pre-takeoff tail = first 25%) ──────────
        let baseWindow = max(4, n / 4)
        let rideMeanA  = DSP.median(Array(accMag[0..<baseWindow]))
        let rideStdA   = DSP.std(accMag[0..<baseWindow])
        let baselineP  = haveBaro ? DSP.median(Array(baroSmooth[0..<baseWindow])) : 0

        // ── TAKEOFF: adaptive release spike + airborne confirmation ──
        let releaseThr = max(cfg.releaseFloorG, rideMeanA + cfg.releaseSigmaK * max(rideStdA, 0.05))
        var t0 = -1
        if let hint = t0Hint, hint > 1, hint < n - 4 {
            t0 = hint
        } else {
            for i in 2..<(n - 4) where accMag[i] >= releaseThr {
                // confirm a take-off: gyro energy OR a baro dip follows (rules out
                // a stationary jolt). A real launch spins the wrist.
                let gyroAhead = gyroMag[i...min(n - 1, i + 6)].max() ?? 0
                if gyroAhead >= cfg.gyroQualityThreshold * 0.4 || (haveBaro && willBaroDrop(baroSmooth, from: i, baseline: baselineP)) {
                    t0 = i; break
                }
            }
        }
        guard t0 != -1 else { return nil }

        // ── LANDING: impact spike OR baro recovery OR settle OR watchdog ──
        let minAS = Int(cfg.minAirTimeSec / dt)
        let maxAS = Int(cfg.maxAirTimeSec / dt)
        var tl = -1
        var landingKind: JumpResult.LandingKind = .timeout
        var jumpMinP = haveBaro ? baselineP : 0

        var settleRun = 0
        var i = t0 + 1
        while i < n && (i - t0) <= maxAS {
            if haveBaro { jumpMinP = min(jumpMinP, baroSmooth[i]) }
            let air = Double(i - t0) * dt

            if air >= cfg.minAirTimeSec {
                // (a) hard impact
                if accMag[i] >= cfg.landingSpikeG {
                    tl = i; landingKind = .hardImpact; break
                }
                // (b) baro recovery (only meaningful if a real drop occurred)
                if haveBaro {
                    let drop = baselineP - jumpMinP
                    if drop > cfg.baroNoiseFloorHPa {
                        let recover = max(drop * 0.08, cfg.baroNoiseFloorHPa)
                        if baroSmooth[i] >= baselineP - recover {
                            tl = i; landingKind = .baroRecovery; break
                        }
                    }
                }
                // (c) settle: |a| back near ride-mean for a sustained run (soft landing)
                if abs(accMag[i] - rideMeanA) < cfg.settleTolG && gyroMag[i] < cfg.gyroQualityThreshold {
                    settleRun += 1
                    if settleRun >= cfg.settleSamplesNeeded && (i - t0) > minAS {
                        tl = i - settleRun + 1; landingKind = .settle; break
                    }
                } else {
                    settleRun = 0
                }
            }
            i += 1
        }
        if tl == -1 { tl = min(n - 1, t0 + maxAS); landingKind = .timeout }
        guard tl > t0 else { return nil }

        let airTimeSec = Double(tl - t0) * dt

        // ── GPS metrics (computed before height gate) ─────────────
        let jumpDistSpeedTime = distanceSpeedTime(samples, t0: t0, airTimeSec: airTimeSec)
        let jumpDistGPS       = distanceGPS(samples, t0: t0, tl: tl)

        // ── BAROMETRIC HEIGHT (may be ~0 — that is expected & fine) ──
        let dP    = haveBaro ? max(0, baselineP - jumpMinP) : 0
        let baroH = dP > cfg.baroNoiseFloorHPa ? dP * K.p2m : 0

        // ── KINEMATIC HEIGHTS (KITE-AWARE, asymmetric arc) ──────────
        // Symmetric ceiling = the MOST a free-fall arc of this airtime could
        // reach (apex at midpoint). Real kite jumps sit below it (kite extends
        // the descent) → it is a physical UPPER BOUND used by the gate below.
        let symCeilingH = K.g * airTimeSec * airTimeSec / 8.0
        // Rise-time height: h = ½·g·t_rise², apex from the baro minimum (the
        // true top); falls back to the symmetric ascent fraction otherwise.
        var tRise = airTimeSec * cfg.symmetricAscentFraction
        if haveBaro && dP > cfg.baroNoiseFloorHPa {
            var minIdx = t0, mp = Double.greatestFiniteMagnitude
            for i in t0...tl where baroSmooth[i] < mp { mp = baroSmooth[i]; minIdx = i }
            let tr = Double(minIdx - t0) * dt
            if tr > 0.1 && tr < airTimeSec - 0.05 { tRise = tr }
        }
        let riseH = cfg.kinematicCalibration * 0.5 * K.g * tRise * tRise

        // ── PHYSICAL CONSISTENCY GATE (the kite-log fix) ───────────
        // baroH is believable only if it does not exceed the airtime envelope.
        // A 22 m baro reading on a 0.4 s airtime (ceiling ≈ 0.2 m) is drift/
        // spike noise → reject baro and use the rise-time estimate.
        let airtimeCeiling = symCeilingH * cfg.airtimeCeilingTolerance
        let baroConsistent = baroH > 0 && baroH <= airtimeCeiling

        // ── HEIGHT SELECTION ───────────────────────────────────────
        let heightM: Double
        let source: JumpResult.HeightSource
        if baroConsistent {
            let baroTrust = DSP.clamp((dP - cfg.baroTrustLoHPa) / (cfg.baroTrustHiHPa - cfg.baroTrustLoHPa), 0, 1)
            let baroClamped = min(baroH, airtimeCeiling)
            heightM = baroTrust * baroClamped + (1 - baroTrust) * riseH
            source = baroTrust >= 0.85 ? .barometric : (baroTrust <= 0.15 ? .kinematic : .blended)
        } else {
            heightM = riseH
            source = .kinematic
        }
        let fusedH = min(heightM, cfg.maxPlausibleHeightM)

        // ── HEIGHT GATE ───────────────────────────────────────────
        guard fusedH >= cfg.minJumpHeightMeters else { return nil }

        // ── APEX (integrate gravity-projected vertical accel) ─────
        let (apex, _) = integrateApex(samples, t0: t0, tl: tl, dt: dt)

        // ── ROTATIONS (gyro integral over the air phase) ──────────
        var totalRad = 0.0
        for k in (t0 + 1)...tl { totalRad += gyroMag[k] * dt }
        let rotations = Int((totalRad / K.twoPi).rounded(.down))

        // ── GYRO QUALITY (for confidence) ─────────────────────────
        let gyroQ = gyroMag.map { max(0, 1 - $0 / (cfg.gyroQualityThreshold * 2.5)) }
        let avgGyroQ = DSP.mean(gyroQ[t0...tl])
        let peakGyro = gyroMag[t0...tl].max() ?? 0
        let peakTakeoffG = accMag[max(0, t0 - 2)...min(n - 1, t0 + 4)].max() ?? 0

        // ── CONFIDENCE (physics-linked) ───────────────────────────
        var conf = 0.55
        // baro & rise-time kinematic agree → strong evidence of a real jump.
        if baroConsistent && abs(baroH - riseH) / max(baroH, riseH, 0.1) < 0.4 { conf += 0.20 }
        if peakTakeoffG >= releaseThr * 1.3 { conf += 0.15 } else if peakTakeoffG >= releaseThr { conf += 0.08 }
        if maxSessionSpeedMS >= 2.0 { conf += 0.10 }            // ride-away (not a stationary toss)
        if airTimeSec >= 1.0 { conf += 0.05 }
        if landingKind == .timeout { conf -= 0.20 }             // never saw a clean landing
        if peakGyro > cfg.gyroQualityThreshold * 2.5 { conf -= 0.15 } // chaotic tumble → maybe not a jump
        if haveBaro && baroH > 0 && !baroConsistent { conf -= 0.15 } // baro contradicts airtime → drift/spike
        conf -= (1 - avgGyroQ) * 0.10
        conf = DSP.clamp(conf, 0, 1)

        func r2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
        func r1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

        return JumpResult(
            jumpHeightMeters:      r2(DSP.clamp(fusedH, 0, 25)),
            baroHeightMeters:      r2(baroH),
            kinematicHeightMeters: r2(riseH),
            airTimeSeconds:        r2(airTimeSec),
            apexTimeSeconds:       apex.map(r2),
            rotations:             rotations,
            jumpDistanceMeters:    jumpDistSpeedTime,
            jumpDistanceGPSMeters: jumpDistGPS,
            maxSessionSpeedKnots:  r1(maxSessionSpeedMS * K.ms2kn),
            maxSessionSpeedKmh:    r1(maxSessionSpeedMS * K.ms2kmh),
            confidence:            (conf * 1000).rounded() / 1000,
            landingKind:           landingKind,
            heightSource:          source,
            deltaPressureHPa:      (dP * 10000).rounded() / 10000,
            peakTakeoffG:          r2(peakTakeoffG),
            peakGyro:              r2(peakGyro),
            avgGyroQuality:        (avgGyroQ * 1000).rounded() / 1000,
            takeoffIndex:          t0,
            landingIndex:          tl
        )
    }

    // ── Apex via gravity-projected vertical-accel integration ────
    private func integrateApex(_ s: [SensorSample], t0: Int, tl: Int, dt: Double) -> (Double?, Double) {
        // Bias = median of (gravity-projected accel) over quiet pre-jump, expected ≈ 0 g.
        let vert: [Double] = s.map { smp in
            let (gx, gy, gz) = DSP.normalize3(smp.gravX, smp.gravY, smp.gravZ)
            // Project the (gravity-removed) accel onto the up axis (−gravity). Units: g.
            return -DSP.dot3(smp.ax, smp.ay, smp.az, gx, gy, gz)
        }
        var bias = 0.0
        if cfg.enableIMUBiasCorrection, t0 > 3 { bias = DSP.median(Array(vert[0..<t0])) }
        var v = 0.0, prevV = 0.0, elapsed = 0.0, peakV = 0.0, apex: Double? = nil
        for k in (t0 + 1)...tl {
            let aMps2 = (vert[k] - bias) * K.g     // vertical accel in m/s²
            prevV = v; v += aMps2 * dt; elapsed += dt
            peakV = max(peakV, v)
            if apex == nil, prevV > 0.05, v <= 0.05 {
                let frac = DSP.clamp(prevV / (prevV - v + 1e-9), 0, 1)
                apex = elapsed - dt + frac * dt
            }
        }
        return (apex, peakV)
    }

    // ── Distance: GPS speed × air time (best for short jumps) ────
    private func distanceSpeedTime(_ s: [SensorSample], t0: Int, airTimeSec: Double) -> Double? {
        let tT = s[t0].t
        var best: Double? = nil, bestDt = Double.infinity
        for smp in s {
            guard let spd = smp.gpsSpeedMS, spd.isFinite else { continue }
            let d = abs(smp.t - tT)
            if d < bestDt { bestDt = d; best = spd }
        }
        guard let spd = best, bestDt <= 3.0 else { return nil }
        return min(150, (spd * airTimeSec * 10).rounded() / 10)
    }

    // ── Distance: GPS position haversine (limited by 1 Hz) ───────
    private func distanceGPS(_ s: [SensorSample], t0: Int, tl: Int) -> Double? {
        struct P { let i: Int; let t, lat, lon: Double }
        let pts: [P] = s.enumerated().compactMap { idx, x in
            guard let la = x.gpsLat, let lo = x.gpsLon, la.isFinite, lo.isFinite else { return nil }
            return P(i: idx, t: x.t, lat: la, lon: lo)
        }
        guard pts.count >= 2 else { return nil }
        let tT = s[t0].t, tL = s[tl].t
        let nearT = pts.min { abs($0.t - tT) < abs($1.t - tT) }!
        var nearL = pts.min { abs($0.t - tL) < abs($1.t - tL) }!
        if nearT.i == nearL.i {
            guard let alt = pts.filter({ $0.i != nearT.i }).min(by: { abs($0.t - tL) < abs($1.t - tL) }) else { return nil }
            nearL = alt
        }
        return (GPSUtil.haversine(nearT.lat, nearT.lon, nearL.lat, nearL.lon) * 10).rounded() / 10
    }

    // ── Helpers ──────────────────────────────────────────────────
    private func willBaroDrop(_ baro: [Double], from i: Int, baseline: Double) -> Bool {
        let end = min(baro.count - 1, i + Int(2.0 / K.dt))
        guard end > i else { return false }
        let mn = baro[i...end].min() ?? baseline
        return (baseline - mn) > cfg.baroNoiseFloorHPa
    }

    /// Forward-fill NaNs (sparse baro → step-held), then back-fill any leading NaNs.
    private func fillForward(_ a: [Double]) -> [Double] {
        var out = a
        var last = a.first(where: { !$0.isNaN }) ?? 1013.25
        for k in out.indices { if out[k].isNaN { out[k] = last } else { last = out[k] } }
        return out
    }

    private func resolveGyroScale(_ s: [SensorSample]) -> Double {
        if let forced = cfg.gyroIsDegPerSec { return forced ? K.deg2rad : 1.0 }
        let mags = s.map { $0.gyroMag }
        return DSP.median(mags) > 10 ? K.deg2rad : 1.0
    }

    /// Drop samples whose timestamp does not advance. Returns the cleaned
    /// series plus indexMap[originalIdx] = newIdx (collapsed onto the last kept
    /// sample for dropped rows) so a take-off hint can be remapped.
    static func dedupeByTime(_ s: [SensorSample]) -> ([SensorSample], [Int]) {
        var out = [SensorSample](); out.reserveCapacity(s.count)
        var indexMap = [Int](repeating: -1, count: s.count)
        var lastT = -Double.infinity
        for i in s.indices {
            if s[i].t > lastT { indexMap[i] = out.count; out.append(s[i]); lastT = s[i].t }
            else { indexMap[i] = out.count - 1 }
        }
        return (out, indexMap)
    }

    private func estimateDt(_ s: [SensorSample]) -> Double {
        guard s.count >= 6 else { return K.dt }
        var diffs = [Double]()
        for i in 1..<min(40, s.count) {
            let d = s[i].t - s[i - 1].t
            if d > 0.005, d < 0.5 { diffs.append(d) }
        }
        return diffs.count > 3 ? DSP.median(diffs) : K.dt
    }
}

// ================================================================
// MARK: - Circular Buffer
// ================================================================
final class CircularBuffer<T> {
    private var storage: [T?]
    private var head = 0
    private var filled = 0
    let capacity: Int

    init(capacity: Int) { self.capacity = capacity; storage = Array(repeating: nil, count: capacity) }

    func push(_ e: T) {
        storage[head] = e
        head = (head + 1) % capacity
        filled = min(filled + 1, capacity)
    }

    /// Last `count` elements in chronological order.
    func last(_ count: Int) -> [T] {
        let take = min(count, filled)
        guard take > 0 else { return [] }
        var result = [T](); result.reserveCapacity(take)
        var idx = ((head - take) % capacity + capacity) % capacity
        for _ in 0..<take { if let e = storage[idx] { result.append(e) }; idx = (idx + 1) % capacity }
        return result
    }

    func clear() { storage = Array(repeating: nil, count: capacity); head = 0; filled = 0 }
}

// ================================================================
// MARK: - Real-Time Session Manager (streaming trigger)
//  The FSM only TRIGGERS analysis; the V7 detector does the math.
//  All timing is in SECONDS, derived from the actual sample rate —
//  NOT fixed sample counts (the batched CoreMotion API is not 50 Hz).
// ================================================================
final class KitesurfSession {

    enum State { case idle, riding, airborne, analyzing }

    // ── Time-based tunables (seconds / Hz-independent) ───────────
    private let preTailSec          = 2.0     // pre-takeoff tail handed to V7
    private let postLandingSec      = 1.0     // post-landing tail for apex/settle
    private let rollingSec          = 6.0     // circular buffer span
    private let baselineWarmupSec   = 8.0     // collect before baseline is usable
    // These are derived in init from the same KitesurfJumpEngineV7.Config used
    // by the offline analyser, so the streaming trigger and analyser agree.
    private let takeoffReleaseFloorG: Double  // matches V7 release floor (adaptive on top)
    private let releaseSigmaK: Double
    private let minAirSec: Double
    private let maxAirborneSec: Double         // kite-glide watchdog
    private let refractorySec: Double          // no re-trigger right after landing

    // ── Derived from measured rate ───────────────────────────────
    private var dt = K.dt
    private var hz = K.sampleRate
    private var rateLocked = false
    private var rateSamples = [Double]()
    private var lastT: Double?

    private func samples(_ sec: Double) -> Int { max(1, Int((sec * hz).rounded())) }

    // ── State ────────────────────────────────────────────────────
    private(set) var state: State = .idle
    private var rollingBuffer: CircularBuffer<SensorSample>
    private var jumpBuffer = [SensorSample]()
    private let detector: KitesurfJumpEngineV7
    private let analysisQueue = DispatchQueue(label: "kite.jump.analysis", qos: .userInitiated)
    private var isAnalyzing = false
    private let synchronousAnalysis: Bool

    // ── Adaptive ride statistics (for release threshold) ─────────
    private var rideWindow = [Double]()           // recent |a| (g)
    private let rideWindowSec = 1.5

    // ── Adaptive baro baseline (slow EMA; frozen during a jump) ──
    private var sessionBaselineP = 0.0
    private var baselineWarmCount = 0
    private var baselineReady = false
    private var baselineFrozen = false
    private let baselineEMA = 0.01                // ~ slow tracking of weather/thermal drift

    private var jumpMinPressure = Double.greatestFiniteMagnitude
    private var baselineAtTakeoff = 0.0
    private var takeoffT = 0.0
    private var takeoffIndexInBuffer = -1
    private var maxSessionSpeedMS = 0.0
    private var speedTop3 = [Double]()            // median-of-top-3 (robust max speed)
    private var refractoryUntil = -Double.infinity
    private var postCountdown = 0
    private var settleRun = 0

    // ── Output ───────────────────────────────────────────────────
    var onJumpDetected: ((JumpResult) -> Void)?
    var onSpeedUpdate:  ((_ knots: Double) -> Void)?
    var onStateChange:  ((State) -> Void)?

    init(detectorConfig: KitesurfJumpEngineV7.Config = .default,
         refractorySec: Double = 1.0,
         synchronousAnalysis: Bool = false) {
        self.detector = KitesurfJumpEngineV7(config: detectorConfig)
        self.takeoffReleaseFloorG = detectorConfig.releaseFloorG
        self.releaseSigmaK = detectorConfig.releaseSigmaK
        self.minAirSec = detectorConfig.minAirTimeSec
        self.maxAirborneSec = detectorConfig.maxAirTimeSec
        self.detectorLandingSpikeG = detectorConfig.landingSpikeG
        self.detectorNoiseFloorHPa = detectorConfig.baroNoiseFloorHPa
        self.refractorySec = max(0, refractorySec)
        self.synchronousAnalysis = synchronousAnalysis
        self.rollingBuffer = CircularBuffer<SensorSample>(capacity: Int((6.0 * K.sampleRate).rounded()))
    }

    // ── Lifecycle ────────────────────────────────────────────────
    func start() {
        rollingBuffer.clear()
        jumpBuffer.removeAll(keepingCapacity: true)
        rideWindow.removeAll(keepingCapacity: true)
        sessionBaselineP = 0; baselineWarmCount = 0
        baselineReady = false; baselineFrozen = false
        jumpMinPressure = .greatestFiniteMagnitude
        maxSessionSpeedMS = 0; speedTop3.removeAll()
        refractoryUntil = -.infinity; isAnalyzing = false
        rateLocked = false; rateSamples.removeAll(); lastT = nil; dt = K.dt; hz = K.sampleRate
        transition(to: .riding)
    }

    func stop() { transition(to: .idle) }

    // ================================================================
    // MARK: Sample Ingestion
    // ================================================================
    func onSample(_ s: SensorSample) {
        lockRate(s.t)

        // (1) GPS speed — robust max (median of top-3), independent of state.
        if let spd = s.gpsSpeedMS, spd.isFinite, spd > 0 {
            updateMaxSpeed(spd)
            onSpeedUpdate?(maxSessionSpeedMS * K.ms2kn)
        }

        // (2) Adaptive baro baseline — slow EMA, frozen during a jump.
        if let p = s.baro, p > 0, !baselineFrozen {
            if !baselineReady {
                sessionBaselineP = baselineWarmCount == 0 ? p : (sessionBaselineP + p) / 2
                baselineWarmCount += 1
                if Double(baselineWarmCount) >= baselineWarmupSec * hz { baselineReady = true }
            } else {
                sessionBaselineP = (1 - baselineEMA) * sessionBaselineP + baselineEMA * p
            }
        }

        // (3) FSM
        switch state {

        case .idle:
            break

        case .riding:
            rollingBuffer.push(s)
            pushRide(s.accelMagG)
            guard s.t >= refractoryUntil, baselineReady || s.baro == nil else { return }

            if isReleaseSpike(s) {
                // Snapshot a clean pre-jump tail so V7 computes its own baseline.
                jumpBuffer = rollingBuffer.last(samples(preTailSec))
                // The current sample is already the last element of that tail
                // (it was pushed above) — do NOT append it again.
                takeoffIndexInBuffer = jumpBuffer.count - 1
                takeoffT = s.t
                baselineAtTakeoff = sessionBaselineP
                jumpMinPressure = s.baro ?? sessionBaselineP
                baselineFrozen = true
                settleRun = 0
                transition(to: .airborne)
            }

        case .airborne:
            rollingBuffer.push(s)
            jumpBuffer.append(s)
            if let p = s.baro { jumpMinPressure = min(jumpMinPressure, p) }

            let air = s.t - takeoffT
            if air > maxAirborneSec { beginAnalyzing(); return }
            if air >= minAirSec, landingDetected(s, air: air) { beginAnalyzing(); return }

        case .analyzing:
            // Keep recording the post-landing tail for apex/settle.
            rollingBuffer.push(s)
            jumpBuffer.append(s)
            postCountdown -= 1
            if postCountdown <= 0, !isAnalyzing { runDetector() }
        }
    }

    // ================================================================
    // MARK: Trigger helpers
    // ================================================================
    private func beginAnalyzing() {
        postCountdown = samples(postLandingSec)
        transition(to: .analyzing)
    }

    /// Adaptive release spike: rides with the chop (μ+Kσ) but never below a floor.
    private func isReleaseSpike(_ s: SensorSample) -> Bool {
        let a = s.accelMagG
        guard a >= takeoffReleaseFloorG else { return false }
        guard rideWindow.count > 10 else { return a >= takeoffReleaseFloorG }
        let mu = median(rideWindow)
        let sd = std(rideWindow, mean: mean(rideWindow))
        let thr = max(takeoffReleaseFloorG, mu + releaseSigmaK * max(sd, 0.05))
        // Require gyro energy too — a real launch spins the wrist; a knock does not.
        return a >= thr && s.gyroMag >= 1.5
    }

    /// Landing: hard impact OR (significant) baro recovery OR sustained settle.
    private func landingDetected(_ s: SensorSample, air: Double) -> Bool {
        // (a) hard impact
        if s.accelMagG >= detectorLandingSpikeG { return true }

        // (b) baro recovery — only when a real drop occurred (clears noise floor).
        if let p = s.baro {
            let drop = baselineAtTakeoff - jumpMinPressure
            if drop > detectorNoiseFloorHPa {
                let recover = max(drop * 0.08, detectorNoiseFloorHPa)
                if p >= baselineAtTakeoff - recover { return true }
            }
        }

        // (c) settle: |a| back near ride-mean with calm gyro for a sustained run.
        let rideMean = rideWindow.isEmpty ? 0.1 : median(rideWindow)
        if abs(s.accelMagG - rideMean) < 0.35 && s.gyroMag < 8.0 {
            settleRun += 1
            if settleRun >= 6 { return true }
        } else {
            settleRun = 0
        }
        return false
    }

    // Mirror of the detector's gates so the trigger and analyser agree.
    private let detectorLandingSpikeG: Double
    private let detectorNoiseFloorHPa: Double

    // ================================================================
    // MARK: Offline Analysis (background thread)
    // ================================================================
    private func runDetector() {
        isAnalyzing = true
        let buffer = jumpBuffer                  // value copy → thread-safe
        let hint = takeoffIndexInBuffer
        let peakSpeed = maxSessionSpeedMS

        if synchronousAnalysis {
            let result = detector.process(buffer, takeoffHint: hint >= 0 ? hint : nil,
                                          maxSessionSpeedMS: peakSpeed)
            if let r = result, r.confidence >= 0.40 { onJumpDetected?(r) }
            jumpBuffer.removeAll(keepingCapacity: true)
            takeoffIndexInBuffer = -1
            jumpMinPressure = .greatestFiniteMagnitude
            baselineFrozen = false
            settleRun = 0
            isAnalyzing = false
            refractoryUntil = (lastT ?? 0) + refractorySec
            transition(to: .riding)
            return
        }

        analysisQueue.async { [weak self] in
            guard let self else { return }
            let result = self.detector.process(buffer, takeoffHint: hint >= 0 ? hint : nil,
                                               maxSessionSpeedMS: peakSpeed)
            DispatchQueue.main.async {
                if let r = result, r.confidence >= 0.40 { self.onJumpDetected?(r) }
                // Reset for next jump; unfreeze baseline so it re-tracks drift.
                self.jumpBuffer.removeAll(keepingCapacity: true)
                self.takeoffIndexInBuffer = -1
                self.jumpMinPressure = .greatestFiniteMagnitude
                self.baselineFrozen = false
                self.settleRun = 0
                self.isAnalyzing = false
                self.refractoryUntil = (self.lastT ?? 0) + self.refractorySec
                self.transition(to: .riding)
            }
        }
    }

    // ================================================================
    // MARK: Small utilities
    // ================================================================
    private func lockRate(_ t: Double) {
        guard !rateLocked else { return }
        if let prev = lastT {
            let d = t - prev
            if d > 0.005, d < 0.5 { rateSamples.append(d) }
            if rateSamples.count >= 20 {
                let m = median(rateSamples)
                if m > 0 { dt = m; hz = 1.0 / m }
                rateLocked = true
                // Resize the rolling buffer to the real rate if it drifted from 50 Hz.
                let want = Int((rollingSec * hz).rounded())
                if want != rollingBuffer.capacity { rollingBuffer = CircularBuffer<SensorSample>(capacity: want) }
            }
        }
        lastT = t
    }

    private func updateMaxSpeed(_ spd: Double) {
        speedTop3.append(spd)
        speedTop3.sort(by: >)
        if speedTop3.count > 3 { speedTop3.removeLast() }
        maxSessionSpeedMS = speedTop3.reduce(0, +) / Double(speedTop3.count)
    }

    private func pushRide(_ a: Double) {
        rideWindow.append(a)
        let cap = max(10, Int((rideWindowSec * hz).rounded()))
        if rideWindow.count > cap { rideWindow.removeFirst(rideWindow.count - cap) }
    }

    private func median(_ a: [Double]) -> Double { DSP.median(a) }
    private func mean(_ a: [Double]) -> Double { DSP.mean(a) }
    private func std(_ a: [Double], mean m: Double) -> Double {
        guard a.count > 1 else { return 0 }
        return (a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(a.count)).squareRoot()
    }

    private func transition(to s: State) { state = s; onStateChange?(s) }
}

// ================================================================
// MARK: - Usage (WatchKit / SwiftUI side)
// ================================================================
/*
 import CoreMotion
 import CoreLocation

 final class WorkoutController: NSObject, CLLocationManagerDelegate {

     private let session  = KitesurfSession()
     private let motion   = CMMotionManager()      // classic API → reliable 50 Hz
     private let altimeter = CMAltimeter()          // baro is a SEPARATE stream (~1–2 Hz)
     private let location = CLLocationManager()

     private var latestPressureHPa: Double?         // updated by CMAltimeter, ZOH onto IMU samples
     private var lastGPSSpeed, lastGPSLat, lastGPSLon, lastGPSAcc: Double?
     private var t0Mono: TimeInterval?              // first dm.timestamp (monotonic, from boot)

     func begin() {
         session.onJumpDetected = { r in
             JumpUI.show(height: r.jumpHeightMeters, airTime: r.airTimeSeconds,
                         rotations: r.rotations, distance: r.jumpDistanceMeters,
                         maxSpeedKn: r.maxSessionSpeedKnots, confidence: r.confidence,
                         source: r.heightSource.rawValue)
         }
         session.onSpeedUpdate = { kn in SpeedDial.update(kn) }
         session.start()

         // Barometer — its OWN stream. CMDeviceMotion does NOT carry pressure.
         if CMAltimeter.isRelativeAltitudeAvailable() {
             altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, _ in
                 if let p = data?.pressure { self?.latestPressureHPa = p.doubleValue * 10.0 } // kPa → hPa
             }
         }

         location.delegate = self
         location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
         location.startUpdatingLocation()

         // 50 Hz device-motion (gravity, userAcceleration in g, gyro rad/s).
         motion.deviceMotionUpdateInterval = 1.0 / 50.0
         motion.startDeviceMotionUpdates(to: .main) { [weak self] dm, _ in
             guard let self, let dm else { return }
             if self.t0Mono == nil { self.t0Mono = dm.timestamp }
             let s = SensorSample(
                 t:  dm.timestamp - (self.t0Mono ?? dm.timestamp),       // MONOTONIC seconds
                 ax: dm.userAcceleration.x, ay: dm.userAcceleration.y, az: dm.userAcceleration.z, // g, gravity removed
                 aM: nil,
                 gx: dm.rotationRate.x, gy: dm.rotationRate.y, gz: dm.rotationRate.z,              // rad/s
                 gM: nil,
                 gravX: dm.gravity.x, gravY: dm.gravity.y, gravZ: dm.gravity.z,                    // g
                 baro: self.latestPressureHPa,                                                     // ZOH from altimeter
                 gpsSpeedMS: self.lastGPSSpeed, gpsLat: self.lastGPSLat,
                 gpsLon: self.lastGPSLon, gpsAccuracyM: self.lastGPSAcc
             )
             self.session.onSample(s)
             self.lastGPSSpeed = nil; self.lastGPSLat = nil; self.lastGPSLon = nil  // one-shot GPS
         }
     }

     func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
         guard let loc = locs.last else { return }
         lastGPSSpeed = max(0, loc.speed); lastGPSLat = loc.coordinate.latitude
         lastGPSLon   = loc.coordinate.longitude; lastGPSAcc = loc.horizontalAccuracy
     }
 }
*/
