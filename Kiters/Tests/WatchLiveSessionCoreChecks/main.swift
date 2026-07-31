import Foundation
import WatchLiveSessionCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ message: String) {
    guard actual == expected else {
        fputs("FAIL: \(message). expected \(expected), got \(actual)\n", stderr)
        exit(1)
    }
}

func testStartIsDedupedAndRetriesAfterFailureWindow() {
    let state = LiveSessionUploadState()
    state.reset(sessionId: "local-1")
    let start = Date(timeIntervalSince1970: 1_000)

    expect(state.beginStartAttempt(sessionId: "local-1", now: start, lat: 32.1, lng: 34.8), "first start should fire")
    expect(state.isStartUploadInFlight, "start should be in flight")
    expectEqual(state.trackPoints, [[321000, 348000]], "start should append first track point")

    expect(!state.beginStartAttempt(sessionId: "local-1", now: start.addingTimeInterval(1), lat: 32.2, lng: 34.9), "duplicate in-flight start should not fire")
    expect(!state.acceptStart(sessionId: "old-session", sessId: 99), "stale start response should be ignored")

    state.failStart(sessionId: "local-1")
    expect(!state.beginStartAttempt(sessionId: "local-1", now: start.addingTimeInterval(4.9), lat: 32.2, lng: 34.9), "start retry should wait 5 seconds")
    expect(state.beginStartAttempt(sessionId: "local-1", now: start.addingTimeInterval(5), lat: 32.2, lng: 34.9), "start should retry after 5 seconds")

    expect(state.acceptStart(sessionId: "local-1", sessId: 123), "current start response should be accepted")
    expectEqual(state.currentServerSessId, 123, "accepted server session id should be stored")
    expect(!state.isStartUploadInFlight, "accepted start should clear in-flight flag")
}

func testFallbackStartUsesZeroCoordinateAndAcceptsLateServerId() {
    let state = LiveSessionUploadState()
    state.reset(sessionId: "gpsless-1")
    let start = Date(timeIntervalSince1970: 3_000)

    expect(state.beginStartAttemptWithFallback(sessionId: "gpsless-1", now: start), "fallback start should fire")
    expectEqual(state.trackPoints, [[0, 0]], "fallback start should append zero coordinate")
    expect(!state.beginStartAttemptWithFallback(sessionId: "gpsless-1", now: start.addingTimeInterval(1)), "fallback start should dedupe in-flight retry")
    expect(state.acceptStart(sessionId: "gpsless-1", sessId: 777), "late server id should be accepted for fallback start")
    expectEqual(state.currentServerSessId, 777, "fallback server session id should be stored")
}

func testPingTrackAndRecordGatingMatchLiveSessionContract() {
    let state = LiveSessionUploadState()
    state.reset(sessionId: "local-1")
    let start = Date(timeIntervalSince1970: 2_000)
    expect(state.beginStartAttempt(sessionId: "local-1", now: start, lat: 36.0128, lng: -5.6012), "start should fire")
    expect(state.acceptStart(sessionId: "local-1", sessId: 321), "start should be accepted")

    expect(!state.appendTrackIfDue(now: start.addingTimeInterval(4.9), lat: 36.0130, lng: -5.6014), "track should not append before 5 seconds")
    expect(state.appendTrackIfDue(now: start.addingTimeInterval(5), lat: 36.0130, lng: -5.6014), "track should append at 5 seconds")
    expectEqual(state.trackPoints, [[360128, -56012], [360130, -56014]], "track should use compact lat/lng format")

    expect(!state.shouldPing(now: start.addingTimeInterval(9.9)), "ping should not fire before 10 seconds")
    expect(state.shouldPing(now: start.addingTimeInterval(10)), "ping should fire at 10 seconds")
    expect(!state.shouldPing(now: start.addingTimeInterval(19.9)), "ping should reset its cadence")

    expectEqual(state.speedRecordIfImproved(kmh: 20.0), 20.0, "first speed should record")
    expectEqual(state.speedRecordIfImproved(kmh: 20.9), nil, "speed less than 1 km/h better should not record")
    expectEqual(state.speedRecordIfImproved(kmh: 21.1), 21.1, "speed more than 1 km/h better should record")

    expectEqual(state.distanceRecordIfImproved(distKm: 0.11), 0.11, "first coarse distance should record")
    expectEqual(state.distanceRecordIfImproved(distKm: 0.20), nil, "distance below threshold should not record")
    expectEqual(state.distanceRecordIfImproved(distKm: 0.211), 0.211, "distance above threshold should record")
}

func testJumpRecordsQueueAndFlushOnlySessionBests() {
    let state = LiveSessionUploadState()
    state.reset(sessionId: "local-1")

    let first = state.jumpRecordIfImproved(heightM: 2.0, airS: 1.5)
    expectEqual(first, PendingLiveRecord(jumpM: 2.0, airS: 1.5), "first jump should record jump and air")
    if let first { state.enqueue(first) }

    expectEqual(state.jumpRecordIfImproved(heightM: 1.9, airS: 1.4), nil, "lower jump should not record")
    let airOnly = state.jumpRecordIfImproved(heightM: 1.95, airS: 1.8)
    expectEqual(airOnly, PendingLiveRecord(jumpM: nil, airS: 1.8), "air-only session best should record only air")
    if let airOnly { state.enqueue(airOnly) }

    let jumpOnly = state.jumpRecordIfImproved(heightM: 2.4, airS: 1.7)
    expectEqual(jumpOnly, PendingLiveRecord(jumpM: 2.4, airS: nil), "jump-only session best should record only jump")
    if let jumpOnly { state.enqueue(jumpOnly) }

    expectEqual(state.claimPendingRecord(sessionId: "local-1"), PendingLiveRecord(jumpM: 2.4, airS: 1.8), "pending records should coalesce to best values")
    expectEqual(state.claimPendingRecord(sessionId: "local-1"), nil, "pending record should be cleared after claim")
    expectEqual(state.claimPendingRecord(sessionId: "other"), nil, "wrong session should not claim pending records")
}

func testGPSStationaryGateOnlyAppliesWhenReliableGPSExists() {
    expect(
        !V7GPSStationaryGate.accepts(heightMeters: 1.3, movementDistanceMeters: 0.6, hasReliableGPS: true),
        "reliable GPS stationary jump under 1.5m should be rejected"
    )
    expect(
        V7GPSStationaryGate.accepts(heightMeters: 1.6, movementDistanceMeters: 0.6, hasReliableGPS: true),
        "reliable GPS stationary jump at/above 1.5m should be accepted"
    )
    expect(
        V7GPSStationaryGate.accepts(heightMeters: 1.1, movementDistanceMeters: 1.2, hasReliableGPS: true),
        "reliable GPS moving jump above 1m should be accepted"
    )
    expect(
        V7GPSStationaryGate.accepts(heightMeters: 1.3, movementDistanceMeters: nil, hasReliableGPS: false),
        "no-GPS sensor-only jump should not be rejected by the GPS stationary gate"
    )
    expect(
        !V7GPSStationaryGate.accepts(heightMeters: 0.9, movementDistanceMeters: nil, hasReliableGPS: false),
        "sensor-only sub-metre jump should still be rejected by the base height gate"
    )
}

func testBackgroundNoiseGateRequiresAllNoiseSignals() {
    expect(
        !V7BackgroundNoiseGate.accepts(heightMeters: 1.5, displayedAirTimeSeconds: 2.8, rotations: 0, regularDistanceMeters: 29.9),
        "short low non-rotating jump with regular distance under 30m should be rejected as background noise"
    )
    expect(
        V7BackgroundNoiseGate.accepts(heightMeters: 1.5, displayedAirTimeSeconds: 2.8, rotations: 0, regularDistanceMeters: nil),
        "no-GPS sensor-only jump should not be rejected by the regular-distance noise gate"
    )
    expect(
        V7BackgroundNoiseGate.accepts(heightMeters: 1.5, displayedAirTimeSeconds: 2.8, rotations: 1, regularDistanceMeters: 29.9),
        "rotation should keep the jump accepted"
    )
    expect(
        V7BackgroundNoiseGate.accepts(heightMeters: 1.5, displayedAirTimeSeconds: 3.0, rotations: 0, regularDistanceMeters: 29.9),
        "airtime at 3 seconds should keep the jump accepted"
    )
    expect(
        V7BackgroundNoiseGate.accepts(heightMeters: 2.0, displayedAirTimeSeconds: 2.8, rotations: 0, regularDistanceMeters: 29.9),
        "height at 2m should keep the jump accepted"
    )
    expect(
        V7BackgroundNoiseGate.accepts(heightMeters: 1.5, displayedAirTimeSeconds: 2.8, rotations: 0, regularDistanceMeters: 30.0),
        "distance at 30m should keep the jump accepted"
    )
}

final class V12Probe: JumpPipelineV12Delegate {
    var instant: [V12Jump] = []
    var refined: [V12Jump] = []

    func jumpDetected(_ jump: V12Jump) {
        instant.append(jump)
    }

    func jumpRefined(_ jump: V12Jump) {
        refined.append(jump)
    }
}

func testV12PipelineEmitsInstantAndRefinedJump() {
    let pipeline = JumpPipelineV12()
    let probe = V12Probe()
    pipeline.delegate = probe

    for t in stride(from: 0.0, through: 4.9, by: 0.1) {
        pipeline.addAccel(t: t, aMag: 0.08)
    }
    for t in stride(from: 0.0, through: 12.0, by: 1.0) {
        pipeline.addLocation(t: t, lat: 32.0, lng: 34.0 + t * 0.00003, speedMs: 8.0)
    }
    for t in [0.0, 1.0, 2.0, 3.0, 4.0] {
        pipeline.addBaro(t: t, relAltM: 0)
    }

    pipeline.addAccel(t: 5.0, aMag: 2.5)
    pipeline.addBaro(t: 6.0, relAltM: 1.6)
    pipeline.addBaro(t: 7.0, relAltM: 2.4)
    pipeline.addBaro(t: 8.0, relAltM: 1.6)

    for t in stride(from: 5.1, through: 8.1, by: 0.1) {
        pipeline.addAccel(t: t, aMag: 0.03)
    }
    pipeline.addAccel(t: 8.2, aMag: 2.1)
    pipeline.addBaro(t: 8.4, relAltM: 0.2)
    pipeline.addBaro(t: 8.9, relAltM: 0.1)

    expectEqual(probe.instant.count, 1, "V12 should emit one instant jump")
    let instant = probe.instant[0]
    expect(instant.heightM >= 1.5, "V12 instant jump should clear display height")
    expect(abs(instant.airtimeSec - 3.2) < 0.11, "V12 instant airtime should use IMU landing evidence")
    expect(instant.arcBaroPoints >= 2, "V12 should use barometer arc points for height")

    pipeline.addBaro(t: 9.5, relAltM: 0.0)
    pipeline.addBaro(t: 10.5, relAltM: 0.0)
    pipeline.addAccel(t: 11.3, aMag: 0.06)

    expectEqual(probe.refined.count, 1, "V12 should emit one refined jump")
    expect(probe.refined[0].refined, "V12 refined emission should be marked refined")
    expect(probe.refined[0].heightM >= 1.5, "V12 refined jump should remain valid")
}

func testV12RejectsSubMeterAbsoluteJump() {
    let pipeline = JumpPipelineV12()
    let probe = V12Probe()
    pipeline.delegate = probe

    for t in [0.0, 1.0, 2.0, 3.0] {
        pipeline.addBaro(t: t, relAltM: 0)
    }

    pipeline.addAccel(t: 4.0, aMag: 2.4)
    pipeline.addBaro(t: 4.4, relAltM: 0.35)
    pipeline.addBaro(t: 5.0, relAltM: 0.80)
    pipeline.addBaro(t: 5.6, relAltM: 0.20)
    pipeline.addAccel(t: 5.7, aMag: 2.1)
    pipeline.addBaro(t: 5.8, relAltM: 0.05)

    expectEqual(probe.instant.count, 0, "V12 should reject absolute jumps below 1m")
    expectEqual(probe.refined.count, 0, "V12 should not refine rejected sub-metre jumps")
}

// ── V13 pure engine (recall-first, post-landing classification) ───────────

final class V13Probe: JumpEngineV13Delegate {
    var jumps: [V13Jump] = []
    func jumpDetected(_ jump: V13Jump) {
        jumps.append(jump)
    }
}

/// Feeds one synthetic kite jump: flat water at `base`, IMU pop at `takeoff`,
/// a parabolic absolute-altitude arc peaking at `apexM`, an impact at `landing`,
/// then flat water at `base + driftM` (linear drift across the flight).
/// 25 Hz IMU, 3 Hz altimeter, deterministic integer-step timeline.
func feedV13Arc(_ engine: JumpEngineV13,
                takeoff: Double = 12.0,
                landing: Double = 15.0,
                apexM: Double = 2.6,
                base: Double = 100.0,
                driftM: Double = 0.0,
                endT: Double = 20.0,
                gyroTriggerOnly: Bool = false,
                spikeOnlyAt: Double? = nil,
                withGPS: Bool = true) {
    let dt = 0.04
    var nextAltT = 0.0
    let steps = Int((endT / dt).rounded())
    for i in 0...steps {
        let t = Double(i) * dt

        var accel = 0.1
        var gyro = 0.3
        if abs(t - takeoff) < dt / 2 {
            accel = gyroTriggerOnly ? 0.1 : 2.6
            gyro = 5.0
        } else if abs(t - landing) < dt / 2 {
            accel = gyroTriggerOnly ? 0.1 : 2.9
            gyro = 2.0
        } else if t > takeoff, t < landing {
            accel = 0.05
            gyro = 1.0
        }
        engine.addIMU(t: t, accelG: accel, gyroRadS: gyro)

        if t + 1e-9 >= nextAltT {
            let alt: Double
            if let spikeT = spikeOnlyAt {
                // Flat water with one glitched altimeter reading.
                alt = abs(t - spikeT) <= 1.0 / 6.0 ? base + 3.0 : base
            } else if t > takeoff, t < landing {
                let p = (t - takeoff) / (landing - takeoff)
                alt = base + driftM * p + apexM * 4 * p * (1 - p)
            } else if t >= landing {
                alt = base + driftM
            } else {
                alt = base
            }
            engine.addAltitude(t: t, altitudeM: alt)
            nextAltT += 1.0 / 3.0
        }

        if withGPS, i % 25 == 0 {
            engine.addGPS(t: t, lat: 32.0, lng: 34.0 + t * 0.00003, speedMS: 9.0)
        }
    }
}

func testV13DetectsCleanJumpAfterLanding() {
    let engine = JumpEngineV13()
    let probe = V13Probe()
    engine.delegate = probe

    feedV13Arc(engine, withGPS: true)

    expectEqual(probe.jumps.count, 1, "V13 should classify exactly one jump after landing")
    guard let jump = probe.jumps.first else { return }
    expect(abs(jump.heightM - 2.57) <= 0.3, "V13 height should match the synthetic apex, got \(jump.heightM)")
    expect(abs(jump.airtimeSec - 3.0) <= 0.7, "V13 airtime should span the takeoff window start to baseline return, got \(jump.airtimeSec)")
    expect(jump.emittedAtT - jump.landingT <= 5.0, "V13 must emit within 5 s of landing (§1), got \(jump.emittedAtT - jump.landingT)")
    expect(jump.emittedAtT >= jump.landingT, "V13 classification must run after landing")
    expect(jump.baselinePostM != nil, "V13 should compute a post-landing baseline")
    expect(jump.triggerSource == .altitude, "V13 candidate should be opened by absolute-altitude rise")
    expect(jump.confidence >= 0.7, "V13 clean arc should be high confidence, got \(jump.confidence)")
    expect((jump.distanceM ?? 0) > 2, "V13 should derive horizontal distance from GPS")
    expect(jump.altitudePointCount >= 3, "V13 should keep the altitude arc points, got \(jump.altitudePointCount)")
}

func testV13RequiresConfiguredTakeoffWindow() {
    let engine = JumpEngineV13()
    let probe = V13Probe()
    engine.delegate = probe

    engine.addAltitude(t: 0.00, altitudeM: 100.0)
    engine.addAltitude(t: 0.33, altitudeM: 103.0)
    engine.addAltitude(t: 0.66, altitudeM: 100.0)
    engine.addAltitude(t: 0.99, altitudeM: 100.0)

    expectEqual(probe.jumps.count, 0, "V13 must not open a jump before the configured takeoff window elapsed")
}

func testV13CountedHeightDoesNotChangeCandidateDetection() {
    var oneMetreConfig = V13Config()
    oneMetreConfig.minCountedHeightM = 1.0
    let oneMetreEngine = JumpEngineV13(oneMetreConfig)
    let oneMetreProbe = V13Probe()
    var oneMetreCandidateT: TimeInterval?
    oneMetreEngine.delegate = oneMetreProbe
    oneMetreEngine.onDebug = { t, event in
        if event.hasPrefix("CANDIDATE"), oneMetreCandidateT == nil {
            oneMetreCandidateT = t
        }
    }

    var twoMetreConfig = V13Config()
    twoMetreConfig.minCountedHeightM = 2.0
    let twoMetreEngine = JumpEngineV13(twoMetreConfig)
    let twoMetreProbe = V13Probe()
    var twoMetreCandidateT: TimeInterval?
    twoMetreEngine.delegate = twoMetreProbe
    twoMetreEngine.onDebug = { t, event in
        if event.hasPrefix("CANDIDATE"), twoMetreCandidateT == nil {
            twoMetreCandidateT = t
        }
    }

    // Both engines receive the same valid 1.6 m arc. They must open the same
    // candidate at the same time; only the final user-count decision differs.
    feedV13Arc(oneMetreEngine, apexM: 1.6, withGPS: false)
    feedV13Arc(twoMetreEngine, apexM: 1.6, withGPS: false)

    expect(oneMetreCandidateT != nil, "1 m count threshold should open an altitude candidate")
    expect(twoMetreCandidateT != nil, "2 m count threshold must not suppress the same candidate")
    if let oneMetreCandidateT, let twoMetreCandidateT {
        expect(abs(oneMetreCandidateT - twoMetreCandidateT) < 0.001,
               "count threshold must not move takeoff timing")
    }
    expectEqual(oneMetreProbe.jumps.count, 1, "1.6 m jump should count at the 1 m preference")
    expectEqual(twoMetreProbe.jumps.count, 0, "1.6 m jump should not count at the 2 m preference")
}

func testV13CompensatesBaselineDriftAcrossJump() {
    let engine = JumpEngineV13()
    let probe = V13Probe()
    engine.delegate = probe

    // Water level drifts +0.9 m during the flight (swell). V13 measures height
    // against the pre-jump absolute baseline and keeps the landing baseline as
    // a drift diagnostic.
    feedV13Arc(engine, driftM: 0.9)

    expectEqual(probe.jumps.count, 1, "V13 should land the drifted jump on the shifted baseline")
    guard let jump = probe.jumps.first else { return }
    expect(jump.baselineShifted, "V13 should flag the shifted landing baseline")
    expect(!jump.driftSuspect, "0.9 m of drift is within the plausible-drift budget")
    expect(abs((jump.baselinePostM ?? 0) - 100.9) <= 0.15, "V13 post baseline should sit on the new level, got \(String(describing: jump.baselinePostM))")
    expect(jump.heightM > 2.6, "V13 height should stay referenced to the pre-jump baseline, got \(jump.heightM)")
    expect(jump.heightM < 3.3, "V13 drift diagnostic should keep the drifted arc in a plausible range, got \(jump.heightM)")
}

func testV13AllowsBarometerOnlyWithoutGPS() {
    let engine = JumpEngineV13()
    let probe = V13Probe()
    engine.delegate = probe

    feedV13Arc(engine, withGPS: false)
    expectEqual(probe.jumps.count, 1, "V13 should classify an altitude arc without riding-speed GPS")
}

func testV13AllowsBarometerOnlyWithoutInertialSpike() {
    let engine = JumpEngineV13()
    let probe = V13Probe()
    engine.delegate = probe

    feedV13Arc(engine, gyroTriggerOnly: true)
    expectEqual(probe.jumps.count, 1, "V13 should classify a clean altitude arc without takeoff/landing acceleration")
}

func testV13BaselineReturnEmitsBeforeLandingWindow() {
    let engine = JumpEngineV13()
    let probe = V13Probe()
    engine.delegate = probe

    // Session ends about 1 s after touchdown. V13 should close on absolute
    // baseline return and leave nothing pending for flush.
    feedV13Arc(engine, endT: 16.0)
    let late = engine.flush(now: 16.0)

    expectEqual(probe.jumps.count, 1, "V13 should emit on baseline return before the settle window closed")
    expectEqual(late.count, 0, "V13 flush should have no pending jump after baseline-return emission")
}

func testV13StructuredAuditCoversSessionAndDecisionChain() {
    let audit = V13CalculationLogService.shared
    let cfg = V13Config()
    var records: [V13AuditRecord] = []

    audit.beginSession(sessionID: "audit-check", t: 0)
    audit.configure(cfg, t: 0.01)

    // Attach after schema/config to verify that the pre-file prefix is buffered
    // and drained rather than being lost at session startup.
    audit.attachSink { records.append($0) }

    let engine = JumpEngineV13(cfg)
    engine.onAudit = { audit.record($0) }
    engine.reset()
    feedV13Arc(engine, withGPS: true)
    audit.endSession(t: 21, durationSec: 21, reportedJumpCount: 1)
    audit.detachSink()

    expect(!records.isEmpty, "V13 audit should emit structured records")
    expectEqual(records.first?.kind, "schema", "V13 audit should begin with its self-describing schema")
    expect(records.first.flatMap { try? JSONEncoder().encode($0) } != nil,
           "V13 audit schema should be JSON encodable for KSLG storage")
    expect(records.first?.definitions.contains(where: { !$0.descriptionHe.isEmpty }) == true,
           "V13 audit schema should include Hebrew parameter explanations")
    expect(records.allSatisfy { $0.sessionID == "audit-check" },
           "every V13 audit record should carry the session id")
    expect(records.enumerated().allSatisfy { index, record in record.sequence == UInt64(index + 1) },
           "V13 audit sequence should remain gap-free across buffered and live records")

    let candidateEvaluation = records.first {
        $0.stage == "takeoff" && $0.action == "evaluateCandidate"
    }
    expect(candidateEvaluation?.conditions.contains(where: { $0.id == "baselineNoise" }) == true,
           "takeoff audit should expose the baseline-noise condition")
    expect(candidateEvaluation?.conditions.contains(where: { $0.id == "shortWindowRise" }) == true,
           "takeoff audit should expose the short-window rise condition")
    expect(records.contains(where: { $0.stage == "apex" && $0.decision == "newApex" }),
           "V13 audit should record maximum-height transitions")
    expect(records.contains(where: { $0.stage == "landing" && $0.action == "landingDetected" }),
           "V13 audit should record the landing transition")
    expect(records.contains(where: { $0.stage == "result" && $0.decision == "accepted" }),
           "V13 audit should record the accepted final calculation")
    let imuAuditCount = records.filter { $0.action == "integrateIMU" }.count
    expect(imuAuditCount >= 5 && imuAuditCount <= 16,
           "V13 structured IMU audit should be throttled near 4 Hz, got \(imuAuditCount) records")
    expectEqual(records.last?.kind, "summary", "V13 audit should end with a session summary")
}

// ── V14 hybrid engine (IMU+pressure detection, on-demand absolute) ────────

final class V14Probe: JumpEngineV14Delegate {
    var jumps: [V14Jump] = []
    var windowEvents: [Bool] = []
    func jumpDetected(_ jump: V14Jump) {
        jumps.append(jump)
    }
}

/// Drives a clean synthetic kite jump through the pure V14 engine:
/// riding at 1 g → pop → 1.4 s unweight with a 2 m pressure arc → impact →
/// stable landing baseline. The absolute stream is fed only while the engine
/// keeps its on-demand window open, exactly like the live adapter.
func feedV14Jump(_ engine: JumpEngineV14,
                 probe: V14Probe,
                 withGPS: Bool,
                 absoluteAt: ((TimeInterval) -> Double)?) {
    var windowOpen = false
    engine.onAbsoluteWindowRequest = { open, _ in
        windowOpen = open
        probe.windowEvents.append(open)
    }

    let takeoff = 12.0
    let landing = 13.4
    var nextRelT = 0.0
    var nextAbsT = 0.0
    var t = 0.0
    while t <= 22.0 {
        var load = 1.0
        if t >= takeoff - 0.12, t < takeoff { load = 2.4 }
        else if t >= takeoff, t < landing { load = 0.05 }
        else if t >= landing, t < landing + 0.1 { load = 3.2 }
        engine.addIMU(t: t, verticalLoadG: load, gyroRadS: 0.6)

        if t + 1e-9 >= nextRelT {
            let p = (t - takeoff) / (landing - takeoff)
            let arc = (t > takeoff && t < landing) ? 2.0 * 4 * p * (1 - p) : 0.0
            engine.addRelativeAltitude(t: t, altitudeM: arc)
            nextRelT += 0.5
        }
        if let absoluteAt, windowOpen, t + 1e-9 >= nextAbsT {
            engine.addAbsoluteAltitude(t: t, altitudeM: absoluteAt(t))
            nextAbsT = t + 1.0
        }
        if withGPS, t.truncatingRemainder(dividingBy: 1.0) < 0.011 {
            engine.addGPS(t: t, lat: 32.0, lng: 34.0 + t * 0.00003, speedMS: 8.5)
        }
        t += 0.02
    }
}

func testV14PrefersRelativeHeightOverHealthyAbsoluteCrossCheck() {
    // Both channels are healthy and agree on the same arc. Relative altitude
    // is the primary height source (V14_RELATIVE_HEIGHT_UPGRADE_PLAN.md §10)
    // — absolute is an opportunistic fallback / diagnostic value only, never
    // preferred even when healthy.
    let engine = JumpEngineV14()
    let probe = V14Probe()
    engine.delegate = probe
    feedV14Jump(engine, probe: probe, withGPS: true, absoluteAt: { t in
        if t > 12.0, t < 13.4 {
            let p = (t - 12.0) / 1.4
            return 100.0 + 2.0 * 4 * p * (1 - p)
        }
        return 100.0 + (Int(t) % 2 == 0 ? 0.02 : -0.02)
    })

    expectEqual(probe.jumps.count, 1, "V14 should emit exactly one jump")
    let jump = probe.jumps[0]
    expectEqual(jump.heightSource, .relativeAltitude, "V14 height should prefer the relative channel even with a healthy absolute cross-check")
    expect(abs(jump.heightM - 2.0) <= 0.6, "V14 relative height should match the arc, got \(jump.heightM)")
    expect(abs(jump.airtimeSec - 1.4) <= 0.3, "V14 airtime should span the unweight, got \(jump.airtimeSec)")
    expect(jump.landingConfirmed, "V14 landing should confirm on the stable baseline")
    expect(jump.detectionConfidence > 0, "V14 detection confidence should be positive (IMU signature alone)")
    expect(jump.heightConfidence > 0, "V14 height confidence should be positive for a well-measured relative height")
    expectEqual(probe.windowEvents.first, true, "V14 must open the absolute window at takeoff")
    expectEqual(probe.windowEvents.last, false, "V14 must close the absolute window after landing")
}

func testV14FrozenAbsoluteFallsBackToRelativeHeight() {
    let engine = JumpEngineV14()
    let probe = V14Probe()
    engine.delegate = probe
    feedV14Jump(engine, probe: probe, withGPS: true, absoluteAt: { _ in 100.0 })

    expectEqual(probe.jumps.count, 1, "V14 should emit exactly one jump with a frozen absolute channel")
    expectEqual(probe.jumps[0].heightSource, .relativeAltitude,
                "V14 should fall back to the relative channel when absolute is frozen")
    expect(abs(probe.jumps[0].heightM - 2.0) <= 0.5,
           "V14 relative height should match the arc, got \(probe.jumps[0].heightM)")
}

func testV14DetectsWithoutGPSAndKeepsMetricsEmpty() {
    let engine = JumpEngineV14()
    let probe = V14Probe()
    engine.delegate = probe
    feedV14Jump(engine, probe: probe, withGPS: false, absoluteAt: nil)

    expectEqual(probe.jumps.count, 1, "V14 must detect without GPS")
    let jump = probe.jumps[0]
    expect(jump.takeoffSpeedMS == nil, "V14 takeoff speed must stay nil without GPS")
    expect(jump.distanceM == nil, "V14 distance must stay nil without GPS")
    expect(jump.heightM >= 1.0, "V14 height should still be measured without GPS, got \(jump.heightM)")
}

func testV14JumpCalculationIsGPSInvariant() {
    let gpsEngine = JumpEngineV14()
    let gpsProbe = V14Probe()
    gpsEngine.delegate = gpsProbe
    feedV14Jump(gpsEngine, probe: gpsProbe, withGPS: true, absoluteAt: nil)

    let noGPSEngine = JumpEngineV14()
    let noGPSProbe = V14Probe()
    noGPSEngine.delegate = noGPSProbe
    feedV14Jump(noGPSEngine, probe: noGPSProbe, withGPS: false, absoluteAt: nil)

    expectEqual(gpsProbe.jumps.count, noGPSProbe.jumps.count,
                "V14 jump count must be identical with and without GPS")
    guard let withGPS = gpsProbe.jumps.first, let withoutGPS = noGPSProbe.jumps.first else { return }
    expectEqual(withGPS.heightM, withoutGPS.heightM, "V14 height must not depend on GPS")
    expectEqual(withGPS.airtimeSec, withoutGPS.airtimeSec, "V14 airtime must not depend on GPS")
    expectEqual(withGPS.heightSource, withoutGPS.heightSource, "V14 height source must not depend on GPS")
    expectEqual(withGPS.confidence, withoutGPS.confidence, "V14 confidence must not depend on GPS")
}

// ── V15 clean engine (IMU-led detection, continuous pressure measurement) ─

final class V15Probe: JumpEngineV15Delegate {
    var jumps: [V15Jump] = []
    func jumpDetected(_ jump: V15Jump) {
        jumps.append(jump)
    }
}

/// Drives the same sensor arc twice: once without GPS and once with a
/// deliberately unusable low-speed GPS stream. Detection and all physical
/// calculations must be identical; only optional result metrics may differ.
func feedV15Jump(_ engine: JumpEngineV15, probe: V15Probe, withLowSpeedGPS: Bool) {
    let takeoff = 10.0
    let landing = 13.2
    var nextAbsT = 0.0
    var nextRelT = 0.0
    var nextGPST = 0.0
    var t = 0.0

    while t <= 18.0 {
        if t + 1e-9 >= nextAbsT {
            let p = (t - takeoff) / (landing - takeoff)
            let arc = (t > takeoff && t < landing) ? 2.0 * 4 * p * (1 - p) : 0.0
            engine.addAbsoluteAltitude(t: t, altitudeM: 100.0 + arc, accuracyM: 4.0)
            nextAbsT += 0.2
        }
        if t + 1e-9 >= nextRelT {
            let p = (t - takeoff) / (landing - takeoff)
            let arc = (t > takeoff && t < landing) ? 2.0 * 4 * p * (1 - p) : 0.0
            engine.addRelativeAltitude(t: t, altitudeM: arc)
            nextRelT += 0.5
        }
        if withLowSpeedGPS, t + 1e-9 >= nextGPST {
            engine.addGPS(t: t, lat: 32.0, lng: 34.0 + t * 0.000001,
                          speedMS: 0.2, courseDeg: 90)
            nextGPST += 1.0
        }

        let load: Double
        if t >= takeoff, t < takeoff + 0.08 {
            load = 1.8
        } else if t >= takeoff + 0.08, t < landing {
            load = 0.8
        } else if t >= landing, t < landing + 0.08 {
            load = 4.0
        } else {
            load = 1.0
        }
        engine.addIMU(t: t, verticalLoadG: load, gyroRadS: 0.5)
        t += 0.02
    }
}

func testV15JumpCalculationIsGPSInvariant() {
    let gpsEngine = JumpEngineV15()
    let gpsProbe = V15Probe()
    gpsEngine.delegate = gpsProbe
    feedV15Jump(gpsEngine, probe: gpsProbe, withLowSpeedGPS: true)

    let noGPSEngine = JumpEngineV15()
    let noGPSProbe = V15Probe()
    noGPSEngine.delegate = noGPSProbe
    feedV15Jump(noGPSEngine, probe: noGPSProbe, withLowSpeedGPS: false)

    expectEqual(gpsProbe.jumps.count, noGPSProbe.jumps.count,
                "V15 jump count must be identical with low-speed GPS and without GPS")
    expectEqual(gpsProbe.jumps.count, 1, "V15 sensor fixture should emit exactly one jump")
    guard let withGPS = gpsProbe.jumps.first, let withoutGPS = noGPSProbe.jumps.first else { return }
    expectEqual(withGPS.heightM, withoutGPS.heightM, "V15 height must not depend on GPS")
    expectEqual(withGPS.airtimeSec, withoutGPS.airtimeSec, "V15 airtime must not depend on GPS")
    expectEqual(withGPS.heightSource, withoutGPS.heightSource, "V15 height source must not depend on GPS")
    expectEqual(withGPS.confidence, withoutGPS.confidence, "V15 confidence must not depend on GPS")
    expectEqual(withGPS.takeoffT, withoutGPS.takeoffT, "V15 takeoff time must not depend on GPS")
    expectEqual(withGPS.landingT, withoutGPS.landingT, "V15 landing time must not depend on GPS")
}

testStartIsDedupedAndRetriesAfterFailureWindow()
testFallbackStartUsesZeroCoordinateAndAcceptsLateServerId()
testPingTrackAndRecordGatingMatchLiveSessionContract()
testJumpRecordsQueueAndFlushOnlySessionBests()
testGPSStationaryGateOnlyAppliesWhenReliableGPSExists()
testBackgroundNoiseGateRequiresAllNoiseSignals()
testV12PipelineEmitsInstantAndRefinedJump()
testV12RejectsSubMeterAbsoluteJump()
testV13DetectsCleanJumpAfterLanding()
testV13RequiresConfiguredTakeoffWindow()
testV13CountedHeightDoesNotChangeCandidateDetection()
testV13CompensatesBaselineDriftAcrossJump()
testV13AllowsBarometerOnlyWithoutGPS()
testV13AllowsBarometerOnlyWithoutInertialSpike()
testV13BaselineReturnEmitsBeforeLandingWindow()
testV13StructuredAuditCoversSessionAndDecisionChain()
testV14PrefersRelativeHeightOverHealthyAbsoluteCrossCheck()
testV14FrozenAbsoluteFallsBackToRelativeHeight()
testV14DetectsWithoutGPSAndKeepsMetricsEmpty()
testV14JumpCalculationIsGPSInvariant()
testV15JumpCalculationIsGPSInvariant()
print("WatchLiveSessionCoreChecks passed")
