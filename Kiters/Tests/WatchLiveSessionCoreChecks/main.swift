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
testV13CompensatesBaselineDriftAcrossJump()
testV13AllowsBarometerOnlyWithoutGPS()
testV13AllowsBarometerOnlyWithoutInertialSpike()
testV13BaselineReturnEmitsBeforeLandingWindow()
print("WatchLiveSessionCoreChecks passed")
