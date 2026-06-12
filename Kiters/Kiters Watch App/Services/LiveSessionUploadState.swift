import Foundation

public struct PendingLiveRecord: Equatable {
    public var jumpM: Double?
    public var airS: Double?
    public var speedKmh: Double?
    public var distKm: Double?

    public init(jumpM: Double? = nil, airS: Double? = nil, speedKmh: Double? = nil, distKm: Double? = nil) {
        self.jumpM = jumpM
        self.airS = airS
        self.speedKmh = speedKmh
        self.distKm = distKm
    }

    public var isEmpty: Bool {
        jumpM == nil && airS == nil && speedKmh == nil && distKm == nil
    }
}

public struct StartUploadSnapshot: Equatable {
    public let isCurrent: Bool
    public let sessId: Int?
    public let startInFlight: Bool
}

public final class LiveSessionUploadState {
    public private(set) var activeSessionId: String?
    public private(set) var serverSessId: Int?
    public private(set) var isStartUploadInFlight = false
    public private(set) var trackPoints: [[Int]] = []

    private var lastPingTime: Date?
    private var lastTrackTime: Date?
    private var lastStartAttempt: Date?
    private var sessionBestJumpM: Double = 0
    private var sessionBestAirS: Double = 0
    private var sessionBestSpeedKmh: Double = 0
    private var sessionBestDistKm: Double = 0
    private var pendingRecord = PendingLiveRecord()

    public init() {}

    public func reset(sessionId: String?) {
        activeSessionId = sessionId
        serverSessId = nil
        isStartUploadInFlight = false
        lastPingTime = nil
        lastTrackTime = nil
        lastStartAttempt = nil
        trackPoints = []
        sessionBestJumpM = 0
        sessionBestAirS = 0
        sessionBestSpeedKmh = 0
        sessionBestDistKm = 0
        pendingRecord = PendingLiveRecord()
    }

    public func beginStartAttempt(sessionId: String, now: Date, lat: Double, lng: Double) -> Bool {
        guard activeSessionId == sessionId, serverSessId == nil, !isStartUploadInFlight else { return false }
        if let lastStartAttempt, now.timeIntervalSince(lastStartAttempt) < 5 { return false }

        lastStartAttempt = now
        isStartUploadInFlight = true
        lastPingTime = now
        lastTrackTime = now
        appendTrackPoint(lat: lat, lng: lng)
        return true
    }

    public func acceptStart(sessionId: String, sessId: Int) -> Bool {
        guard activeSessionId == sessionId else { return false }
        serverSessId = sessId
        isStartUploadInFlight = false
        return true
    }

    public func failStart(sessionId: String) {
        guard activeSessionId == sessionId else { return }
        isStartUploadInFlight = false
    }

    public func appendTrackIfDue(now: Date, lat: Double, lng: Double) -> Bool {
        guard let lastTrackTime, now.timeIntervalSince(lastTrackTime) >= 5 else { return false }
        appendTrackPoint(lat: lat, lng: lng)
        self.lastTrackTime = now
        return true
    }

    public func shouldPing(now: Date) -> Bool {
        guard let lastPingTime, now.timeIntervalSince(lastPingTime) >= 10 else { return false }
        self.lastPingTime = now
        return true
    }

    public var pingBestJumpM: Double? { sessionBestJumpM > 0 ? sessionBestJumpM : nil }
    public var currentServerSessId: Int? { serverSessId }

    public func speedRecordIfImproved(kmh: Double) -> Double? {
        guard kmh > sessionBestSpeedKmh + 1 else { return nil }
        sessionBestSpeedKmh = kmh
        return kmh
    }

    public func distanceRecordIfImproved(distKm: Double) -> Double? {
        guard distKm > sessionBestDistKm + 0.1 else { return nil }
        sessionBestDistKm = distKm
        return distKm
    }

    public func jumpRecordIfImproved(heightM: Double, airS: Double) -> PendingLiveRecord? {
        let jumpBetter = heightM > sessionBestJumpM
        let airBetter = airS > sessionBestAirS
        guard jumpBetter || airBetter else { return nil }

        if jumpBetter { sessionBestJumpM = heightM }
        if airBetter { sessionBestAirS = airS }
        return PendingLiveRecord(
            jumpM: jumpBetter ? heightM : nil,
            airS: airBetter ? airS : nil
        )
    }

    public func enqueue(_ record: PendingLiveRecord) {
        if let jumpM = record.jumpM {
            pendingRecord.jumpM = max(pendingRecord.jumpM ?? 0, jumpM)
        }
        if let airS = record.airS {
            pendingRecord.airS = max(pendingRecord.airS ?? 0, airS)
        }
        if let speedKmh = record.speedKmh {
            pendingRecord.speedKmh = max(pendingRecord.speedKmh ?? 0, speedKmh)
        }
        if let distKm = record.distKm {
            pendingRecord.distKm = max(pendingRecord.distKm ?? 0, distKm)
        }
    }

    public func claimPendingRecord(sessionId: String) -> PendingLiveRecord? {
        guard activeSessionId == sessionId, !pendingRecord.isEmpty else { return nil }
        let record = pendingRecord
        pendingRecord = PendingLiveRecord()
        return record
    }

    public func startSnapshot(sessionId: String) -> StartUploadSnapshot {
        StartUploadSnapshot(
            isCurrent: activeSessionId == sessionId,
            sessId: serverSessId,
            startInFlight: isStartUploadInFlight
        )
    }

    private func appendTrackPoint(lat: Double, lng: Double) {
        let compact = [Int(lat * 1e4), Int(lng * 1e4)]
        if trackPoints.last != compact {
            trackPoints.append(compact)
        }
    }
}
