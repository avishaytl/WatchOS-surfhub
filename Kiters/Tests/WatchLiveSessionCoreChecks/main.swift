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

testStartIsDedupedAndRetriesAfterFailureWindow()
testFallbackStartUsesZeroCoordinateAndAcceptsLateServerId()
testPingTrackAndRecordGatingMatchLiveSessionContract()
testJumpRecordsQueueAndFlushOnlySessionBests()
testGPSStationaryGateOnlyAppliesWhenReliableGPSExists()
testBackgroundNoiseGateRequiresAllNoiseSignals()
print("WatchLiveSessionCoreChecks passed")
