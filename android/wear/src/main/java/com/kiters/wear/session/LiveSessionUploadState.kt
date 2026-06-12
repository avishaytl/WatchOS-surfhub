package com.kiters.wear.session

data class PendingLiveRecord(
    val jumpM: Double? = null,
    val airS: Double? = null,
    val speedKmh: Double? = null,
    val distKm: Double? = null,
) {
    val isEmpty: Boolean
        get() = jumpM == null && airS == null && speedKmh == null && distKm == null
}

data class StartUploadSnapshot(
    val isCurrent: Boolean,
    val sessId: Int?,
    val startInFlight: Boolean,
)

class LiveSessionUploadState {
    var activeSessionId: String? = null
        private set
    var serverSessId: Int? = null
        private set
    var isStartUploadInFlight: Boolean = false
        private set
    val trackPoints: MutableList<List<Int>> = mutableListOf()

    private var lastPingTimeMs: Long? = null
    private var lastTrackTimeMs: Long? = null
    private var lastStartAttemptMs: Long? = null
    private var sessionBestJumpM = 0.0
    private var sessionBestAirS = 0.0
    private var sessionBestSpeedKmh = 0.0
    private var sessionBestDistKm = 0.0
    private var pendingRecord = PendingLiveRecord()

    fun reset(sessionId: String?) {
        activeSessionId = sessionId
        serverSessId = null
        isStartUploadInFlight = false
        lastPingTimeMs = null
        lastTrackTimeMs = null
        lastStartAttemptMs = null
        trackPoints.clear()
        sessionBestJumpM = 0.0
        sessionBestAirS = 0.0
        sessionBestSpeedKmh = 0.0
        sessionBestDistKm = 0.0
        pendingRecord = PendingLiveRecord()
    }

    fun beginStartAttempt(sessionId: String, nowMs: Long, lat: Double, lng: Double): Boolean {
        if (activeSessionId != sessionId || serverSessId != null || isStartUploadInFlight) return false
        val lastStart = lastStartAttemptMs
        if (lastStart != null && nowMs - lastStart < 5_000L) return false

        lastStartAttemptMs = nowMs
        isStartUploadInFlight = true
        lastPingTimeMs = nowMs
        lastTrackTimeMs = nowMs
        appendTrackPoint(lat, lng)
        return true
    }

    fun acceptStart(sessionId: String, sessId: Int): Boolean {
        if (activeSessionId != sessionId) return false
        serverSessId = sessId
        isStartUploadInFlight = false
        return true
    }

    fun failStart(sessionId: String) {
        if (activeSessionId == sessionId) isStartUploadInFlight = false
    }

    fun appendTrackIfDue(nowMs: Long, lat: Double, lng: Double): Boolean {
        val lastTrack = lastTrackTimeMs ?: return false
        if (nowMs - lastTrack < 5_000L) return false
        appendTrackPoint(lat, lng)
        lastTrackTimeMs = nowMs
        return true
    }

    fun shouldPing(nowMs: Long): Boolean {
        val lastPing = lastPingTimeMs ?: return false
        if (nowMs - lastPing < 10_000L) return false
        lastPingTimeMs = nowMs
        return true
    }

    val pingBestJumpM: Double?
        get() = if (sessionBestJumpM > 0.0) sessionBestJumpM else null

    fun speedRecordIfImproved(kmh: Double): Double? {
        if (kmh <= sessionBestSpeedKmh + 1.0) return null
        sessionBestSpeedKmh = kmh
        return kmh
    }

    fun distanceRecordIfImproved(distKm: Double): Double? {
        if (distKm <= sessionBestDistKm + 0.1) return null
        sessionBestDistKm = distKm
        return distKm
    }

    fun jumpRecordIfImproved(heightM: Double, airS: Double): PendingLiveRecord? {
        val jumpBetter = heightM > sessionBestJumpM
        val airBetter = airS > sessionBestAirS
        if (!jumpBetter && !airBetter) return null

        if (jumpBetter) sessionBestJumpM = heightM
        if (airBetter) sessionBestAirS = airS
        return PendingLiveRecord(
            jumpM = if (jumpBetter) heightM else null,
            airS = if (airBetter) airS else null,
        )
    }

    fun enqueue(record: PendingLiveRecord) {
        pendingRecord = PendingLiveRecord(
            jumpM = maxOrCurrent(pendingRecord.jumpM, record.jumpM),
            airS = maxOrCurrent(pendingRecord.airS, record.airS),
            speedKmh = maxOrCurrent(pendingRecord.speedKmh, record.speedKmh),
            distKm = maxOrCurrent(pendingRecord.distKm, record.distKm),
        )
    }

    fun claimPendingRecord(sessionId: String): PendingLiveRecord? {
        if (activeSessionId != sessionId || pendingRecord.isEmpty) return null
        val record = pendingRecord
        pendingRecord = PendingLiveRecord()
        return record
    }

    fun startSnapshot(sessionId: String): StartUploadSnapshot =
        StartUploadSnapshot(
            isCurrent = activeSessionId == sessionId,
            sessId = serverSessId,
            startInFlight = isStartUploadInFlight,
        )

    private fun appendTrackPoint(lat: Double, lng: Double) {
        val compact = listOf((lat * 1e4).toInt(), (lng * 1e4).toInt())
        if (trackPoints.lastOrNull() != compact) trackPoints.add(compact)
    }

    private fun maxOrCurrent(current: Double?, next: Double?): Double? =
        when {
            next == null -> current
            current == null -> next
            else -> maxOf(current, next)
        }
}
