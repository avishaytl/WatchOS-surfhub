//
//  V11SelfTest.swift
//  JumpReplay
//
//  Core-calculation unit tests for the v11 offline buffered engine. Run with
//  `JumpReplay --v11-selftest`. Covers:
//    • airtime
//    • estimated height (g·t²/8)
//    • rotation integration
//    • candidate segment detection
//    • false-positive rejection (accel-spike-only)
//    • duplicate segment rejection
//    • event buffer (range query, dedupe, prune)
//

import Foundation

enum V11SelfTest {

    private static var failures = 0
    private static var passes = 0

    static func run(_ stdout: inout StdoutStream) -> Bool {
        failures = 0; passes = 0
        print("v11 self-test", to: &stdout)
        print("=============", to: &stdout)

        testBufferRangeAndPrune(&stdout)
        testBufferDedupe(&stdout)
        testSegmentDetectionFullJump(&stdout)
        testAirtimeAndHeight(&stdout)
        testRotationIntegration(&stdout)
        testFalsePositiveAccelSpikeOnly(&stdout)
        testInertialHeightKnown(&stdout)
        testInertialHeightBiasAndWaterline(&stdout)
        testInertialNoMotionLowQuality(&stdout)
        testInertialHeightSelected(&stdout)
        testBlendedHeightSelected(&stdout)
        testBaroHeightPrimary(&stdout)
        testClusteringNMS(&stdout)
        testMinAirtimeFilter(&stdout)
        testDuplicateRejection(&stdout)
        testHeightFormulaPure(&stdout)

        print("", to: &stdout)
        print("\(passes) passed, \(failures) failed", to: &stdout)
        return failures == 0
    }

    // MARK: - Assertions

    private static func check(_ cond: Bool, _ name: String, _ stdout: inout StdoutStream, _ detail: @autoclosure () -> String = "") {
        if cond { passes += 1; print("  ✓ \(name)", to: &stdout) }
        else { failures += 1; print("  ✗ \(name)  \(detail())", to: &stdout) }
    }

    private static func approx(_ a: Double, _ b: Double, _ tol: Double) -> Bool { abs(a - b) <= tol }

    // MARK: - Synthetic event builders

    /// Build one normalized event with fully-specified physics fields (bypasses
    /// the normalization layer so each signal can be controlled in isolation).
    private static func ev(_ t: Double,
                           accel: Double = 0.1,
                           vert: Double = 1.0,
                           gx: Double = 0, gy: Double = 0, gz: Double = 0,
                           gps: Double? = 8.0,
                           fresh: Bool = true,
                           baro: Double? = nil) -> SurfSensorEventV11 {
        let rot = (gx * gx + gy * gy + gz * gz).squareRoot()
        return SurfSensorEventV11(
            t: t, ax: 0, ay: 0, az: 0,
            accelMag: accel, gravMag: 1.0,
            gx: gx, gy: gy, gz: gz, rotMag: rot,
            gpsSpeed: gps, gpsLat: nil, gpsLon: nil, gpsAccuracy: 5.0, gpsCourse: nil,
            baro: baro,
            verticalAccelG: abs(vert),
            signedVerticalLoadG: vert,
            motionEnergy: accel * accel, rotationEnergy: rot * rot,
            speedAgeSec: fresh ? 0 : .infinity, speedFresh: fresh && gps != nil)
    }

    /// A complete ride → takeoff → airborne → landing → post sequence at 50 Hz,
    /// including a barometric drop during the airborne window and recovery after
    /// landing (so the v11.1 baro-primary scorer sees a real altitude event).
    private static func fullJump(start: Double, airSec: Double, gz: Double = 0, gps: Double = 8.0) -> [SurfSensorEventV11] {
        let dt = 0.02
        let baseBaro = 1013.0
        let dropHPa = 0.22                 // ≈ 1.85 m altitude gain
        var out: [SurfSensorEventV11] = []
        var t = start
        // ride phase (1.5 s)
        for _ in 0..<75 { out.append(ev(t, accel: 0.12, vert: 1.0, gps: gps, baro: baseBaro)); t += dt }
        // takeoff spike (2 samples, strong accel + gyro)
        for _ in 0..<2 { out.append(ev(t, accel: 2.2, vert: 1.8, gz: 3.0, gps: gps, baro: baseBaro)); t += dt }
        // airborne (free-fall: accel ~1g, vertical-g ~0), pressure dips to baseline−drop
        let airN = Int((airSec / dt).rounded())
        for _ in 0..<airN { out.append(ev(t, accel: 1.0, vert: 0.05, gz: gz, gps: gps, baro: baseBaro - dropHPa)); t += dt }
        // landing impact spike
        for _ in 0..<2 { out.append(ev(t, accel: 2.6, vert: 2.2, gz: 1.0, gps: gps, baro: baseBaro)); t += dt }
        // post-landing ride (1.5 s) — pressure recovered to baseline
        for _ in 0..<75 { out.append(ev(t, accel: 0.12, vert: 1.0, gps: gps, baro: baseBaro)); t += dt }
        return out
    }

    /// Synthetic signed-load jump with known height. Height curve:
    /// h(t)=H/2*(1-cos(2πt/T)), so velocity is zero at takeoff and landing.
    private static func inertialJump(height h: Double, duration T: Double, bias: Double = 0) -> [SurfSensorEventV11] {
        let dt = 0.02
        var out: [SurfSensorEventV11] = []
        var t = 0.0
        for _ in 0..<75 {
            out.append(ev(t, accel: 0.12, vert: 1.0 + bias, gz: 0, baro: nil))
            t += dt
        }
        let n = Int((T / dt).rounded())
        for i in 0...n {
            let phase = Double(i) / Double(max(n, 1))
            let a = (h / 2.0) * pow(2.0 * .pi / T, 2) * cos(2.0 * .pi * phase)
            let signedLoad = 1.0 + bias + a / 9.80665
            let launchOrLand = i <= 1 || i >= n - 1
            out.append(ev(t,
                          accel: launchOrLand ? 2.6 : max(0.08, abs(signedLoad - 1.0)),
                          vert: signedLoad,
                          gz: launchOrLand ? 3.0 : 0,
                          baro: nil))
            t += dt
        }
        for _ in 0..<75 {
            out.append(ev(t, accel: 0.12, vert: 1.0 + bias, gz: 0, baro: nil))
            t += dt
        }
        return out
    }

    private static func flattenSignedLoad(_ events: [SurfSensorEventV11], to load: Double = 1.0) -> [SurfSensorEventV11] {
        events.map { e in
            SurfSensorEventV11(
                t: e.t,
                ax: e.ax, ay: e.ay, az: e.az,
                accelMag: e.accelMag, gravMag: e.gravMag,
                gx: e.gx, gy: e.gy, gz: e.gz, rotMag: e.rotMag,
                gpsSpeed: e.gpsSpeed, gpsLat: e.gpsLat, gpsLon: e.gpsLon,
                gpsAccuracy: e.gpsAccuracy, gpsCourse: e.gpsCourse,
                baro: e.baro,
                verticalAccelG: e.verticalAccelG,
                signedVerticalLoadG: load,
                motionEnergy: e.motionEnergy, rotationEnergy: e.rotationEnergy,
                speedAgeSec: e.speedAgeSec, speedFresh: e.speedFresh
            )
        }
    }

    private static func withBaroDrop(_ events: [SurfSensorEventV11],
                                     takeoffT: Double,
                                     landingT: Double,
                                     heightMeters: Double) -> [SurfSensorEventV11] {
        let base = 1013.0
        let drop = heightMeters / 8.43
        return events.map { e in
            let p = (e.t >= takeoffT && e.t <= landingT) ? base - drop : base
            return SurfSensorEventV11(
                t: e.t,
                ax: e.ax, ay: e.ay, az: e.az,
                accelMag: e.accelMag, gravMag: e.gravMag,
                gx: e.gx, gy: e.gy, gz: e.gz, rotMag: e.rotMag,
                gpsSpeed: e.gpsSpeed, gpsLat: e.gpsLat, gpsLon: e.gpsLon,
                gpsAccuracy: e.gpsAccuracy, gpsCourse: e.gpsCourse,
                baro: p,
                verticalAccelG: e.verticalAccelG,
                signedVerticalLoadG: e.signedVerticalLoadG,
                motionEnergy: e.motionEnergy, rotationEnergy: e.rotationEnergy,
                speedAgeSec: e.speedAgeSec, speedFresh: e.speedFresh
            )
        }
    }

    // MARK: - Tests

    private static func testBufferRangeAndPrune(_ stdout: inout StdoutStream) {
        print("[buffer range + prune]", to: &stdout)
        let buf = JumpEventBufferV11()
        for i in 0..<100 { buf.append(ev(Double(i) * 0.1)) }   // t = 0 … 9.9
        let mid = buf.getEventsBetween(2.0, 3.0)
        check(mid.allSatisfy { $0.t >= 2.0 && $0.t <= 3.0 }, "getEventsBetween bounds", &stdout)
        check(mid.count == 11, "getEventsBetween count", &stdout, "got \(mid.count)")
        let recent = buf.getRecentEvents(1.0)
        check(recent.first.map { $0.t >= 8.9 } ?? false, "getRecentEvents window", &stdout)
        buf.pruneOldEvents(2.0)                                // keep last 2 s
        check(buf.events.first.map { $0.t >= 7.9 } ?? false, "pruneOldEvents drops old", &stdout, "first=\(buf.events.first?.t ?? -1)")
    }

    private static func testBufferDedupe(_ stdout: inout StdoutStream) {
        print("[buffer dedupe]", to: &stdout)
        let buf = JumpEventBufferV11()
        for i in 0..<100 { buf.append(ev(Double(i) * 0.1)) }
        buf.markSegmentAsProcessed(3.0, 4.0)
        check(buf.segmentWasProcessed(3.5, 3.8, tolerance: 0.1), "overlapping segment flagged processed", &stdout)
        check(!buf.segmentWasProcessed(6.0, 7.0, tolerance: 0.1), "distant segment not flagged", &stdout)
    }

    private static func testSegmentDetectionFullJump(_ stdout: inout StdoutStream) {
        print("[segment detection]", to: &stdout)
        let cfg = JumpEngineV11Config.default
        let seg = JumpCandidateSegmenterV11(cfg: cfg).findCandidateSegments(fullJump(start: 0, airSec: 1.6))
        check(seg.count == 1, "exactly one candidate", &stdout, "got \(seg.count)")
        if let s = seg.first {
            check(s.sawAirbornePhase, "airborne phase detected", &stdout)
            check(s.sawLandingImpact, "landing impact detected", &stdout)
            check(s.reasonCodes.contains("TAKEOFF_IMPULSE_DETECTED"), "takeoff reason code", &stdout)
        }
    }

    private static func testAirtimeAndHeight(_ stdout: inout StdoutStream) {
        print("[airtime + height]", to: &stdout)
        let cfg = JumpEngineV11Config.default
        let events = fullJump(start: 0, airSec: 1.6)
        let segs = JumpCandidateSegmenterV11(cfg: cfg).findCandidateSegments(events)
        guard let cand = segs.first,
              let p = JumpPhysicsAnalyzerV11(cfg: cfg).analyzeSegment(events, candidate: cand) else {
            check(false, "physics produced a result", &stdout); return
        }
        // takeoff→landing spans the 0.6 s air phase plus the 2-sample landing tail.
        check(approx(p.airTimeSec, 1.64, 0.12), "airtime ≈ 1.64 s", &stdout, "got \(p.airTimeSec)")
        let expectedH = 9.80665 * p.airTimeSec * p.airTimeSec / 8.0
        check(approx(p.heightFromAirtime, expectedH, 0.02), "height = g·t²/8", &stdout, "got \(p.heightFromAirtime) want \(expectedH)")
        check(p.speedBeforeTakeoff ?? 0 >= 7.0, "speed-before captured", &stdout, "got \(String(describing: p.speedBeforeTakeoff))")
    }

    private static func testRotationIntegration(_ stdout: inout StdoutStream) {
        print("[rotation integration]", to: &stdout)
        let cfg = JumpEngineV11Config.default
        // 1.0 s airborne at gz = 2π rad/s (= 360°/s) → ~360° total yaw.
        let events = fullJump(start: 0, airSec: 1.0, gz: 2 * .pi)
        let segs = JumpCandidateSegmenterV11(cfg: cfg).findCandidateSegments(events)
        guard let cand = segs.first,
              let p = JumpPhysicsAnalyzerV11(cfg: cfg).analyzeSegment(events, candidate: cand) else {
            check(false, "physics produced a result", &stdout); return
        }
        check(approx(p.totalRotationDegrees, 360, 40), "≈360° integrated", &stdout, "got \(p.totalRotationDegrees)")
        check(p.rotationAxis == "yaw", "dominant axis = yaw", &stdout, "got \(p.rotationAxis)")
        check(p.rotations == 1, "1 full rotation", &stdout, "got \(p.rotations)")
    }

    private static func testFalsePositiveAccelSpikeOnly(_ stdout: inout StdoutStream) {
        print("[false-positive: accel spike only, no baro]", to: &stdout)
        let cfg = JumpEngineV11Config.default
        // ride, single hard spike with gyro, NO airborne, NO baro drop (carve/chop).
        let dt = 0.02
        var out: [SurfSensorEventV11] = []
        var t = 0.0
        for _ in 0..<75 { out.append(ev(t, accel: 0.12, vert: 1.0, baro: 1013.0)); t += dt }
        for _ in 0..<2 { out.append(ev(t, accel: 2.4, vert: 1.9, gz: 3.0, baro: 1013.0)); t += dt } // chop
        for _ in 0..<75 { out.append(ev(t, accel: 0.12, vert: 1.0, baro: 1013.0)); t += dt }         // back to riding
        let segs = JumpCandidateSegmenterV11(cfg: cfg).findCandidateSegments(out)
        guard let cand = segs.first,
              let p = JumpPhysicsAnalyzerV11(cfg: cfg).analyzeSegment(out, candidate: cand) else {
            check(true, "no acceptable segment (best outcome)", &stdout); return
        }
        let qs = CandidateRankingScorerV11(cfg: cfg).score(physics: p, candidate: cand, recentEmittedTakeoffs: [])
        check(qs.total < cfg.rankAcceptScore, "scored below accept threshold", &stdout, "score \(qs.total)")
        check(qs.reasonCodes.contains("NO_BARO_PROFILE"), "flags no-baro-profile", &stdout)
        check(p.baroHeightMeters == nil, "no barometric height (flat pressure)", &stdout)
    }

    private static func inertialBounds(_ events: [SurfSensorEventV11], duration: Double) -> (Int, Int) {
        let takeoff = events.firstIndex { $0.t >= 1.5 } ?? 0
        let landingT = events[takeoff].t + duration
        let landing = events.lastIndex { $0.t <= landingT + 0.001 } ?? (events.count - 1)
        return (takeoff, landing)
    }

    private static func manualCandidate(_ events: [SurfSensorEventV11], t0: Int, tl: Int) -> JumpCandidateSegmentV11 {
        let takeoffT = events[t0].t
        let landingT = events[tl].t
        return JumpCandidateSegmentV11(
            startTime: takeoffT,
            endTime: landingT,
            takeoffTime: takeoffT,
            landingTime: landingT,
            reasonCodes: ["TEST_MANUAL_CANDIDATE"],
            confidence: 1.0,
            supporting: .init(
                speedBefore: nil,
                speedAfter: nil,
                maxAcceleration: events[t0...tl].map { $0.accelMag }.max(),
                minVerticalG: events[t0...tl].map { $0.verticalAccelG }.min(),
                maxRotationRate: events[t0...tl].map { $0.rotMag }.max(),
                altitudeDelta: nil,
                estimatedAirTimeSec: landingT - takeoffT
            ),
            sawAirbornePhase: true,
            sawLandingImpact: true,
            landingKind: .hardImpact,
            lifecycle: []
        )
    }

    private static func testInertialHeightKnown(_ stdout: inout StdoutStream) {
        print("[inertial height: known synthetic]", to: &stdout)
        let cfg = JumpEngineV11Config.default
        let events = inertialJump(height: 2.0, duration: 2.6)
        let (t0, tl) = inertialBounds(events, duration: 2.6)
        guard let est = InertialHeightEstimatorV11.estimate(events, takeoffIndex: t0, landingIndex: tl, cfg: cfg) else {
            check(false, "inertial estimate produced a result", &stdout); return
        }
        check(approx(est.heightMeters, 2.0, 0.25), "height ≈ 2.0 m", &stdout, "got \(est.heightMeters)")
        check(est.quality >= 0.55, "quality passes selection threshold", &stdout, "q \(est.quality)")
        check(approx(est.apexTimeSec ?? 0, 1.3, 0.2), "apex near mid-air", &stdout, "apex \(String(describing: est.apexTimeSec))")
    }

    private static func testInertialHeightBiasAndWaterline(_ stdout: inout StdoutStream) {
        print("[inertial height: bias + waterline]", to: &stdout)
        let cfg = JumpEngineV11Config.default
        let events = inertialJump(height: 2.4, duration: 2.8, bias: 0.08)
        let (t0, tl) = inertialBounds(events, duration: 2.8)
        guard let est = InertialHeightEstimatorV11.estimate(events, takeoffIndex: t0, landingIndex: tl, cfg: cfg) else {
            check(false, "inertial estimate produced a result", &stdout); return
        }
        check(approx(est.heightMeters, 2.4, 0.30), "height remains calibrated under bias", &stdout, "got \(est.heightMeters)")
        check(approx(est.biasG, 0.08, 0.02), "bias estimated from pre-window", &stdout, "bias \(est.biasG)")
        check(est.waterlineErrorMeters < 0.001, "height returns to waterline after correction", &stdout, "err \(est.waterlineErrorMeters)")
    }

    private static func testInertialNoMotionLowQuality(_ stdout: inout StdoutStream) {
        print("[inertial height: no-motion low quality]", to: &stdout)
        let cfg = JumpEngineV11Config.default
        let events = inertialJump(height: 0.0, duration: 2.6)
        let (t0, tl) = inertialBounds(events, duration: 2.6)
        guard let est = InertialHeightEstimatorV11.estimate(events, takeoffIndex: t0, landingIndex: tl, cfg: cfg) else {
            check(false, "inertial estimate produced a low-quality result", &stdout); return
        }
        check(est.heightMeters < 0.2, "no-motion height stays near zero", &stdout, "got \(est.heightMeters)")
        check(est.quality < 0.55, "no-motion quality below selection threshold", &stdout, "q \(est.quality)")
    }

    private static func testInertialHeightSelected(_ stdout: inout StdoutStream) {
        print("[inertial height: selected headline]", to: &stdout)
        let cfg = JumpEngineV11Config.default
        let events = inertialJump(height: 2.0, duration: 2.6)
        let (t0, tl) = inertialBounds(events, duration: 2.6)
        let cand = manualCandidate(events, t0: t0, tl: tl)
        guard let p = JumpPhysicsAnalyzerV11(cfg: cfg).analyzeSegment(events, candidate: cand) else {
            check(false, "physics produced a result", &stdout); return
        }
        check(p.heightSource == .inertial, "height source = inertial", &stdout, "got \(p.heightSource)")
        check(approx(p.estimatedHeightMeters, 2.0, 0.25), "headline height ≈ inertial height", &stdout, "got \(p.estimatedHeightMeters)")
        check((p.inertialHeightMeters ?? 0) > 0, "inertial height exposed on physics result", &stdout)
    }

    private static func testBlendedHeightSelected(_ stdout: inout StdoutStream) {
        print("[height fusion: blended headline]", to: &stdout)
        let cfg = JumpEngineV11Config.default
        let baseEvents = inertialJump(height: 2.0, duration: 2.6)
        let (t0, tl) = inertialBounds(baseEvents, duration: 2.6)
        let events = withBaroDrop(baseEvents,
                                  takeoffT: baseEvents[t0].t,
                                  landingT: baseEvents[tl].t,
                                  heightMeters: 2.1)
        let cand = manualCandidate(events, t0: t0, tl: tl)
        guard let p = JumpPhysicsAnalyzerV11(cfg: cfg).analyzeSegment(events, candidate: cand) else {
            check(false, "physics produced a result", &stdout); return
        }
        check(p.heightSource == .blended, "height source = blended", &stdout, "got \(p.heightSource)")
        check(approx(p.baroHeightMeters ?? 0, 2.1, 0.15), "baro height available", &stdout, "baro \(String(describing: p.baroHeightMeters))")
        check((p.baroQuality >= 0.55) && (p.inertialQuality >= 0.55), "both sources quality-pass", &stdout, "bq \(p.baroQuality) iq \(p.inertialQuality)")
        check(p.estimatedHeightMeters > 1.9 && p.estimatedHeightMeters < 2.2, "blended height stays between agreeing sources", &stdout, "h \(p.estimatedHeightMeters)")
    }

    private static func testBaroHeightPrimary(_ stdout: inout StdoutStream) {
        print("[barometric height primary]", to: &stdout)
        let cfg = JumpEngineV11Config.default
        let events = flattenSignedLoad(fullJump(start: 0, airSec: 2.4))   // long kite airtime, inertial intentionally unusable
        let segs = JumpCandidateSegmenterV11(cfg: cfg).findCandidateSegments(events)
        guard let cand = segs.first,
              let p = JumpPhysicsAnalyzerV11(cfg: cfg).analyzeSegment(events, candidate: cand) else {
            check(false, "physics produced a result", &stdout); return
        }
        // 0.22 hPa drop · 8.43 ≈ 1.85 m — NOT the ballistic g·t²/8 (≈7 m for 2.4 s).
        check(approx(p.baroHeightMeters ?? 0, 1.85, 0.2), "baro height ≈ 1.85 m", &stdout, "got \(String(describing: p.baroHeightMeters))")
        check(p.heightSource == .barometric, "height source = barometric", &stdout, "got \(p.heightSource)")
        let inertialSelectable = p.inertialQuality >= 0.55
            && (p.inertialHeightMeters ?? 0) >= 0.2
            && (p.inertialHeightMeters ?? 0) <= 8.0
        check(!inertialSelectable, "unselectable inertial falls back to baro", &stdout,
              "h \(String(describing: p.inertialHeightMeters)) q \(p.inertialQuality)")
        check(p.baroRecovered, "pressure recovery detected", &stdout)
        check(p.estimatedHeightMeters < 3.0, "headline height not ballistic-inflated", &stdout, "got \(p.estimatedHeightMeters)")
    }

    private static func testClusteringNMS(_ stdout: inout StdoutStream) {
        print("[clustering / NMS]", to: &stdout)
        let cfg = JumpEngineV11Config.default
        let scorer = CandidateRankingScorerV11(cfg: cfg)
        func candAt(_ start: Double) -> JumpRawCandidateV11 {
            let events = fullJump(start: start, airSec: 2.0)
            let cand = JumpCandidateSegmenterV11(cfg: cfg).findCandidateSegments(events).first!
            let p = JumpPhysicsAnalyzerV11(cfg: cfg).analyzeSegment(events, candidate: cand)!
            return JumpRawCandidateV11(physics: p, segment: cand, score: scorer.score(physics: p, candidate: cand, recentEmittedTakeoffs: []))
        }
        // 3 near-duplicates (one real jump split, within the cluster window) +
        // 1 well-separated jump.
        let raw = [candAt(2.0), candAt(5.0), candAt(8.0), candAt(120.0)]
        let clusters = JumpCandidateClustererV11(cfg: cfg).cluster(raw)
        check(clusters.count == 2, "4 candidates → 2 clusters", &stdout, "got \(clusters.count)")
        if clusters.count == 2 {
            check(clusters[0].members.count == 3, "first cluster grouped 3 near candidates", &stdout, "got \(clusters[0].members.count)")
            check(clusters[1].members.count == 1, "separated jump is its own cluster", &stdout)
        }
    }

    private static func testMinAirtimeFilter(_ stdout: inout StdoutStream) {
        print("[min-airtime hard filter (≥2s)]", to: &stdout)
        let cfg = JumpEngineV11Config.default
        // A clean jump but only ~1.0s airborne — below the 2s validity filter.
        let events = fullJump(start: 0, airSec: 1.0)
        let segs = JumpCandidateSegmenterV11(cfg: cfg).findCandidateSegments(events)
        guard let cand = segs.first,
              let p = JumpPhysicsAnalyzerV11(cfg: cfg).analyzeSegment(events, candidate: cand) else {
            check(true, "no segment (acceptable)", &stdout); return
        }
        let qs = CandidateRankingScorerV11(cfg: cfg).score(physics: p, candidate: cand, recentEmittedTakeoffs: [])
        check(p.airTimeSec < 2.0, "airtime under 2s", &stdout, "got \(p.airTimeSec)")
        check(qs.total == 0, "short jump hard-zeroed", &stdout, "score \(qs.total)")
        check(qs.reasonCodes.contains("REJECT_AIRTIME_BELOW_MIN"), "flags airtime-below-min", &stdout)
    }

    private static func testDuplicateRejection(_ stdout: inout StdoutStream) {
        print("[duplicate penalty]", to: &stdout)
        let cfg = JumpEngineV11Config.default
        let events = fullJump(start: 0, airSec: 2.2)   // ≥ minValidAirtimeSec
        let segs = JumpCandidateSegmenterV11(cfg: cfg).findCandidateSegments(events)
        guard let cand = segs.first,
              let p = JumpPhysicsAnalyzerV11(cfg: cfg).analyzeSegment(events, candidate: cand) else {
            check(false, "physics produced a result", &stdout); return
        }
        let first = CandidateRankingScorerV11(cfg: cfg).score(physics: p, candidate: cand, recentEmittedTakeoffs: [])
        check(first.total >= cfg.rankAcceptScore, "first occurrence accepted", &stdout, "score \(first.total)")
        let dup = CandidateRankingScorerV11(cfg: cfg).score(physics: p, candidate: cand, recentEmittedTakeoffs: [p.takeoffTime + 0.4])
        check(dup.reasonCodes.contains("REJECT_DUPLICATE_SEGMENT"), "duplicate flagged", &stdout)
        check(dup.total < first.total, "duplicate penalised", &stdout, "first \(first.total) dup \(dup.total)")
    }

    private static func testHeightFormulaPure(_ stdout: inout StdoutStream) {
        print("[height formula]", to: &stdout)
        // h = g · t² / 8   (spec). 0.8 s → 0.784 m.
        let g = 9.80665
        let t = 0.8
        let h = g * t * t / 8.0
        check(approx(h, 0.7845, 0.001), "0.8 s → 0.78 m", &stdout, "got \(h)")
    }
}
