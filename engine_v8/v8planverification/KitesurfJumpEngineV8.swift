// ============================================================================
//  KitesurfJumpEngineV8.swift
//  Apple Watch S9 / Ultra · Kitesurf Jump Engine — v8 (baro-centric)
//
//  ALGORITHM v8 — single source of truth is core/jumpEngineV8.ts (TypeScript).
//  This Swift file is a LINE-FOR-LINE port; keep the two in sync.
//
//  WHY v8 (proven on real watch logs, see JUMP_V8_PLAN.md / ALGORITHM_V8_HEBREW.md):
//    • A kite lifts the rider in a smooth, canopy-borne rise; the WRIST feels
//      almost no vertical acceleration (the rise is NOT in the accelerometer —
//      integrated take-off impulse ≈ 0.02 m/s vs the 8.13 m/s the physics needs).
//      → HEIGHT must come from the BAROMETER, never from integrating wrist accel.
//    • AIRTIME is DERIVED from height (the 0.36 Hz baro can't time a 4 s arc and a
//      soft kite landing has no spike): airtime = kiteGlideFactor·2·√(2h/g).
//    • THROWS are a separate ballistic (time-of-flight) path, SPEED-DISJOINT from
//      the kite path (throws are standing; kite is planing) so they never collide.
//    • Cross-validation (airborne "calm window" + bar-pull) raises confidence and
//      survives a wet / wetsuit-covered baro; their absence never rejects a jump.
//
//  UNITS: accel g (gravity removed) · gyro rad/s · gravity g · baro hPa · t MS.
// ============================================================================

import Foundation

struct V8Sample {
    var t: Double          // milliseconds
    var ax: Double, ay: Double, az: Double   // userAcceleration (g)
    var aM: Double?        // |userAccel| (g)
    var gx: Double?, gy: Double?, gz: Double?
    var gM: Double?        // |gyro| (rad/s)
    var gvX: Double?, gvY: Double?, gvZ: Double?   // gravity unit vector (g)
    var baro: Double?      // hPa
    var spd: Double?       // GPS speed (m/s)
    var lat: Double?, lng: Double?
}

enum HeightSourceV8: String { case barometric, ballistic }

struct JumpResultV8 {
    var jumpHeightM: Double
    var airTimeSec: Double
    var apexTimeSec: Double
    var jumpDistanceM: Double?
    var maxSpeedKmh: Double
    var peakUpAccelG: Double
    var confidence: Double
    var heightSource: HeightSourceV8
    var takeoffTimeMs: Double?
    var landingTimeMs: Double?
    var measuredAirtimeSec: Double?
    var airborneConfirmed: Bool
    var barPullConfirmed: Bool
}

struct JumpEngineV8Params {
    var baselineHalfWinSec = 15.0
    var baselinePctile = 0.5
    var minJumpHeightM = 1.5
    var minAirTimeSec = 2.0
    var maxAirTimeSec = 25.0    // Big Air hangs 20+ s; bounds the on-water bracket (does NOT cap reported airtime)
    var jumpSepSec = 4.0
    var popUpG = 0.9
    var minRidingSpeed = 4.0
    var gyroIsDegPerSec: Bool? = false
    var kiteGlideFactor = 2.63
    var onWaterAltM = 0.4
    var maxPlausibleHeightM = 50.0   // kite WORLD RECORD ≈45 m — cap must not clip a real Big Air

    var jumpRunUpSpeed = 5.0
    var runUpWindowSec = 5.0
    var chopHalfWinSec = 0.2
    var airborneChopRatio = 0.85
    var barPullWindowSec = 1.0
    var barPullMinG = 0.45
    var detectThrows = true
    var throwMaxSpeed = 3.0
    var throwLaunchG = 2.5
    var throwLandG = 2.0
    var throwFreefallG = 0.5
    var throwFreefallMinSec = 0.8
    var throwMaxAirtimeSec = 2.5   // hand-throw flight ≤2.5 s (≈7.7 m); longer = a standing gap, not a flight
    var throwAscentFraction = 0.5
    var throwMaxHeightM = 8.0      // physical cap for a hand throw
    static let `default` = JumpEngineV8Params()
}

enum KitesurfJumpEngineV8 {
    static let G = 9.80665
    static let P2M = 8.43       // hPa → m near sea level
    static let DEG2RAD = Double.pi / 180

    // ── helpers ──────────────────────────────────────────────────────────────
    static func median(_ a: [Double]) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted(); return s[s.count >> 1]
    }
    static func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0,+) / Double(a.count) }

    /// World-vertical (up) component of userAcceleration (g): up = −gravity_unit.
    static func vertAccelG(_ s: V8Sample) -> Double {
        let gx = s.gvX ?? 0, gy = s.gvY ?? 0, gz = s.gvZ ?? -1
        let m = (gx*gx + gy*gy + gz*gz).squareRoot()
        let mm = m == 0 ? 1 : m
        return -((s.ax*gx + s.ay*gy + s.az*gz) / mm)
    }
    static func gyroMag(_ s: V8Sample) -> Double {
        if let g = s.gM { return g }
        let x = s.gx ?? 0, y = s.gy ?? 0, z = s.gz ?? 0
        return (x*x + y*y + z*z).squareRoot()
    }
    static func accMag(_ s: V8Sample) -> Double {
        if let a = s.aM { return a }
        return (s.ax*s.ax + s.ay*s.ay + s.az*s.az).squareRoot()
    }
    static func estimateDtMs(_ s: [V8Sample]) -> Double {
        if s.count < 6 { return 20 }
        var d: [Double] = []
        for i in 1..<min(60, s.count) { let x = s[i].t - s[i-1].t; if x > 5 && x < 500 { d.append(x) } }
        return d.count > 3 ? median(d) : 20
    }
    static func dedupeByTime(_ s: [V8Sample]) -> [V8Sample] {
        var out: [V8Sample] = []; var last = -Double.infinity
        for x in s where x.t > last { out.append(x); last = x.t }
        return out
    }

    // ── Barometric altitude (robust high-pressure-percentile baseline) ─────────
    static func baroAltitudeSeries(_ s: [V8Sample], _ p: JumpEngineV8Params) -> [Double] {
        let n = s.count
        var baro = [Double](repeating: 1013.25, count: n)
        var last = s.first(where: { $0.baro != nil })?.baro ?? 1013.25
        for i in 0..<n { if let b = s[i].baro { last = b }; baro[i] = last }

        var upIdx: [Int] = []; var upVal: [Double] = []
        for i in 0..<n { if let b = s[i].baro, upVal.isEmpty || b != upVal.last! { upIdx.append(i); upVal.append(b) } }
        let W = p.baselineHalfWinSec * 1000
        var baseUp = [Double](repeating: 0, count: upVal.count)
        for k in 0..<upVal.count {
            var w: [Double] = []
            for j in 0..<upVal.count where abs(s[upIdx[j]].t - s[upIdx[k]].t) <= W { w.append(upVal[j]) }
            w.sort()
            baseUp[k] = w[min(w.count - 1, Int(Double(w.count) * p.baselinePctile))]
        }
        var base = [Double](repeating: 0, count: n); var k = 0
        for i in 0..<n {
            while k + 1 < upIdx.count && upIdx[k + 1] <= i { k += 1 }
            base[i] = upIdx.isEmpty ? baro[i] : baseUp[k]
        }
        return (0..<n).map { (base[$0] - baro[$0]) * P2M }
    }

    // ── Whole-session detection ────────────────────────────────────────────────
    static func detectJumps(_ samplesIn: [V8Sample], _ params: JumpEngineV8Params = .default) -> [JumpResultV8] {
        let s = dedupeByTime(samplesIn)
        let n = s.count
        if n < 24 { return [] }
        let dt = estimateDtMs(s) / 1000
        let gscale = params.gyroIsDegPerSec == true ? DEG2RAD : 1

        let haveBaro = s.contains { $0.baro != nil }
        let alt = haveBaro ? baroAltitudeSeries(s, params) : [Double](repeating: 0, count: n)

        let aRaw = s.map { vertAccelG($0) }
        var calm: [Double] = []
        for i in 0..<n where gyroMag(s[i]) * gscale < 1.0 && (s[i].aM ?? 0) < 0.6 && (s[i].spd ?? 0) > params.minRidingSpeed { calm.append(aRaw[i]) }
        let bias = calm.isEmpty ? 0 : mean(calm)

        var maxSpeed = 0.0
        do { var top: [Double] = []; for x in s { if let v = x.spd, v > 0 { top.append(v); top.sort(by: >); if top.count > 3 { top.removeLast() } } }; maxSpeed = top.isEmpty ? 0 : mean(top) }

        // chop = rolling std of |userAccel| (quieter while airborne — no water chop)
        let accMagAll = s.map { accMag($0) }
        let chopHW = max(3, Int((params.chopHalfWinSec / dt).rounded()))
        var chop = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var sum = 0.0, sq = 0.0, cnt = 0.0
            for j in max(0, i - chopHW)...min(n - 1, i + chopHW) { sum += accMagAll[j]; sq += accMagAll[j]*accMagAll[j]; cnt += 1 }
            chop[i] = (max(0, sq/cnt - (sum/cnt)*(sum/cnt))).squareRoot()
        }

        var upIdx: [Int] = []; var upAlt: [Double] = []
        for i in 0..<n { if let b = s[i].baro, upIdx.isEmpty || b != s[upIdx.last!].baro { upIdx.append(i); upAlt.append(alt[i]) } }

        var out: [JumpResultV8] = []
        var lastApexT = -Double.infinity
        let sepMs = params.jumpSepSec * 1000
        let maxAirSamp = Int((params.maxAirTimeSec / dt).rounded())

        if upIdx.count >= 3 {
            for u in 1..<(upIdx.count - 1) {
                let i = upIdx[u]
                if alt[i] < params.minJumpHeightM { continue }
                if !(upAlt[u] >= upAlt[u-1] && upAlt[u] >= upAlt[u+1]) { continue }
                if s[i].t - lastApexT < sepMs {
                    if let lastJ = out.last, alt[i] > lastJ.jumpHeightM { out.removeLast() } else { continue }
                }
                // parabolic apex
                let y0 = upAlt[u-1], y1 = upAlt[u], y2 = upAlt[u+1]
                let den = y0 - 2*y1 + y2
                var apexH = y1
                if abs(den) > 1e-6 { let d = 0.5*(y0 - y2)/den; apexH = y1 - 0.25*(y0 - y2)*d }
                apexH = min(max(apexH, y1), params.maxPlausibleHeightM)

                // airtime from physics (height-derived)
                let airTimeSec = params.kiteGlideFactor * 2 * (2*apexH/G).squareRoot()
                if airTimeSec < params.minAirTimeSec { continue }

                // on-water bracket (for pop/timing only)
                var t0 = max(0, i - maxAirSamp)
                var k = i; while k > max(0, i - maxAirSamp) { if alt[k] < params.onWaterAltM { t0 = k; break }; k -= 1 }
                var tl = min(n - 1, i + maxAirSamp)
                k = i; while k < min(n - 1, i + maxAirSamp) { if alt[k] < params.onWaterAltM { tl = k; break }; k += 1 }

                // (a) run-up speed gate — the only hard filter besides ≥1.5 m height
                let runUpSamp = Int((params.runUpWindowSec / dt).rounded())
                var runUpSpeed = 0.0
                for kk in max(0, i - runUpSamp)...i { if let sp = s[kk].spd, sp > runUpSpeed { runUpSpeed = sp } }
                if runUpSpeed < params.jumpRunUpSpeed { continue }

                // (b) baro support (soft, confidence only)
                var support = 0
                for d in 1...3 {
                    if u - d >= 0 && upAlt[u - d] >= apexH/3 { support += 1 }
                    if u + d < upAlt.count && upAlt[u + d] >= apexH/3 { support += 1 }
                }

                // take-off pop (timing/diagnostic)
                let popLo = max(0, max(t0, i - Int((3.0/dt).rounded())))
                var peakUp = 0.0, popIdx = popLo
                for kk in popLo...i { let a = aRaw[kk] - bias; if a > peakUp { peakUp = a; popIdx = kk } }
                let apexTimeSec = max(0, Double(i - popIdx) * dt)

                // cross-validation: airborne calm window (local chop contrast)
                let arcLo = max(0, t0), arcHi = min(n - 1, tl)
                var arcSum = 0.0, arcN = 0.0; for kk in arcLo...arcHi { arcSum += chop[kk]; arcN += 1 }
                let arcChop = arcN > 0 ? arcSum/arcN : 0
                let ruLo = max(0, t0 - Int((params.runUpWindowSec/dt).rounded()))
                var ruSum = 0.0, ruN = 0.0; if ruLo < t0 { for kk in ruLo..<t0 { ruSum += chop[kk]; ruN += 1 } }
                let runUpChop = ruN > 0 ? ruSum/ruN : arcChop
                let airborneConfirmed = arcChop < runUpChop * params.airborneChopRatio
                let localThr = (arcChop + runUpChop) / 2
                var bestLen = 0, runStart = -1, bestA = i, bestB = i
                let scanLo = max(0, t0 - Int((0.5/dt).rounded())), scanHi = min(n - 1, tl + Int((0.5/dt).rounded()))
                for kk in scanLo...scanHi {
                    if chop[kk] < localThr { if runStart < 0 { runStart = kk }; if kk - runStart > bestLen { bestLen = kk - runStart; bestA = runStart; bestB = kk } }
                    else { runStart = -1 }
                }
                let measuredAirtime = (s[bestB].t - s[bestA].t) / 1000

                // cross-validation: bar-pull before take-off
                let bpLo = max(0, popIdx - Int((params.barPullWindowSec/dt).rounded()))
                var bpHeld = 0.0; if bpLo < popIdx { for kk in bpLo..<popIdx where accMagAll[kk] >= params.barPullMinG { bpHeld += 1 } }
                let barPullConfirmed = bpHeld * dt >= params.barPullWindowSec * 0.5

                // distance
                var spd: Double? = nil; var bd = Double.infinity
                for x in s { if let v = x.spd { let d = abs(x.t - s[t0].t); if d < bd { bd = d; spd = v } } }
                let distanceM = spd != nil ? (spd! * airTimeSec * 10).rounded() / 10 : nil

                // confidence (multi-signal agreement)
                var conf = 0.35
                if runUpSpeed >= params.jumpRunUpSpeed + 2 { conf += 0.15 }
                if apexH >= params.minJumpHeightM + 0.5 { conf += 0.12 }
                if peakUp >= params.popUpG { conf += 0.12 }
                if support >= 2 { conf += 0.08 }
                if airborneConfirmed { conf += 0.15 }
                if barPullConfirmed { conf += 0.08 }
                if airborneConfirmed && abs(measuredAirtime - airTimeSec) < 1.5 { conf += 0.05 }
                conf = max(0, min(1, conf))

                lastApexT = s[i].t
                func r2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
                out.append(JumpResultV8(
                    jumpHeightM: r2(apexH), airTimeSec: r2(airTimeSec), apexTimeSec: r2(apexTimeSec),
                    jumpDistanceM: distanceM, maxSpeedKmh: (maxSpeed * 3.6 * 10).rounded() / 10,
                    peakUpAccelG: r2(peakUp), confidence: (conf * 1000).rounded() / 1000,
                    heightSource: .barometric, takeoffTimeMs: s[t0].t, landingTimeMs: s[tl].t,
                    measuredAirtimeSec: airborneConfirmed ? r2(measuredAirtime) : nil,
                    airborneConfirmed: airborneConfirmed, barPullConfirmed: barPullConfirmed))
            }
        }

        // ── BALLISTIC THROW PATH (speed-disjoint from the kite path) ──
        if params.detectThrows { out.append(contentsOf: detectThrowsBallistic(s, params, dt, out)) }
        out.sort { ($0.takeoffTimeMs ?? 0) < ($1.takeoffTimeMs ?? 0) }
        return out
    }

    // ── Ballistic throw detector (standing-only; never fires during kite riding) ──
    static func detectThrowsBallistic(_ s: [V8Sample], _ params: JumpEngineV8Params, _ dt: Double, _ kiteJumps: [JumpResultV8]) -> [JumpResultV8] {
        let n = s.count
        let throwMinAir = Int((params.throwFreefallMinSec / dt).rounded())
        let throwMaxAirSamp = Int((params.throwMaxAirtimeSec / dt).rounded())
        var out: [JumpResultV8] = []
        var i = 3
        while i < n - 5 {
            if accMag(s[i]) >= params.throwLaunchG && accMag(s[i]) - accMag(s[i-3]) >= 1.0 {
                // first landing impact within a physical flight bound (first, not last)
                var last = -1
                var k = i + throwMinAir
                while k < min(n, i + throwMaxAirSamp) { if accMag(s[k]) >= params.throwLandG { last = k; break }; k += 1 }
                if last > 0 {
                    // diagnostic: did a free-fall window occur? (true for clean throws)
                    var run = 0, freefall = 0
                    for kk in i...last { if accMag(s[kk]) < params.throwFreefallG { run += 1; freefall = max(freefall, run) } else { run = 0 } }
                    var spd = 0.0
                    for kk in max(0, i - 50)...last { if let v = s[kk].spd, v > spd { spd = v } }
                    let airtime = (s[last].t - s[i].t) / 1000
                    let h = min(0.5 * G * pow(params.throwAscentFraction * airtime, 2), params.throwMaxHeightM)
                    let overlapsKite = kiteJumps.contains { abs(($0.takeoffTimeMs ?? 0) - s[i].t) < 2000 }
                    if spd <= params.throwMaxSpeed && h >= params.minJumpHeightM && !overlapsKite {
                        var peakUp = 0.0; for kk in max(0, i-2)..<min(n, i+6) { peakUp = max(peakUp, accMag(s[kk])) }
                        func r2(_ x: Double) -> Double { (x*100).rounded()/100 }
                        out.append(JumpResultV8(
                            jumpHeightM: r2(h), airTimeSec: r2(airtime), apexTimeSec: r2(airtime * params.throwAscentFraction),
                            jumpDistanceM: nil, maxSpeedKmh: 0, peakUpAccelG: r2(peakUp), confidence: 0.5,
                            heightSource: .ballistic, takeoffTimeMs: s[i].t, landingTimeMs: s[last].t,
                            measuredAirtimeSec: r2(airtime), airborneConfirmed: Double(freefall) * dt >= params.throwFreefallMinSec,
                            barPullConfirmed: false))
                        i = last + Int((1.0/dt).rounded()); continue
                    }
                }
            }
            i += 1
        }
        return out
    }
}
