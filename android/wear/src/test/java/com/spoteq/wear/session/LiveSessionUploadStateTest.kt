package com.spoteq.wear.session

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class LiveSessionUploadStateTest {
    @Test
    fun startIsDedupedAndRetriesAfterFailureWindow() {
        val state = LiveSessionUploadState()
        state.reset("local-1")
        val start = 1_000_000L

        assertTrue(state.beginStartAttempt("local-1", start, 32.1, 34.8))
        assertTrue(state.isStartUploadInFlight)
        assertEquals(listOf(listOf(321000, 348000)), state.trackPoints)

        assertFalse(state.beginStartAttempt("local-1", start + 1_000L, 32.2, 34.9))
        assertFalse(state.acceptStart("old-session", 99))

        state.failStart("local-1")
        assertFalse(state.beginStartAttempt("local-1", start + 4_900L, 32.2, 34.9))
        assertTrue(state.beginStartAttempt("local-1", start + 5_000L, 32.2, 34.9))

        assertTrue(state.acceptStart("local-1", 123))
        assertEquals(123, state.serverSessId)
        assertFalse(state.isStartUploadInFlight)
    }

    @Test
    fun pingTrackAndRecordGatingMatchLiveSessionContract() {
        val state = LiveSessionUploadState()
        state.reset("local-1")
        val start = 2_000_000L
        assertTrue(state.beginStartAttempt("local-1", start, 36.0128, -5.6012))
        assertTrue(state.acceptStart("local-1", 321))

        assertFalse(state.appendTrackIfDue(start + 4_900L, 36.0130, -5.6014))
        assertTrue(state.appendTrackIfDue(start + 5_000L, 36.0130, -5.6014))
        assertEquals(listOf(listOf(360128, -56012), listOf(360130, -56014)), state.trackPoints)

        assertFalse(state.shouldPing(start + 9_900L))
        assertTrue(state.shouldPing(start + 10_000L))
        assertFalse(state.shouldPing(start + 19_900L))

        assertEquals(20.0, state.speedRecordIfImproved(20.0)!!, 0.0)
        assertNull(state.speedRecordIfImproved(20.9))
        assertEquals(21.1, state.speedRecordIfImproved(21.1)!!, 0.0)

        assertEquals(0.11, state.distanceRecordIfImproved(0.11)!!, 0.0)
        assertNull(state.distanceRecordIfImproved(0.20))
        assertEquals(0.211, state.distanceRecordIfImproved(0.211)!!, 0.0)
    }

    @Test
    fun jumpRecordsQueueAndFlushOnlySessionBests() {
        val state = LiveSessionUploadState()
        state.reset("local-1")

        val first = state.jumpRecordIfImproved(heightM = 2.0, airS = 1.5)
        assertEquals(PendingLiveRecord(jumpM = 2.0, airS = 1.5), first)
        state.enqueue(first!!)

        assertNull(state.jumpRecordIfImproved(heightM = 1.9, airS = 1.4))
        val airOnly = state.jumpRecordIfImproved(heightM = 1.95, airS = 1.8)
        assertEquals(PendingLiveRecord(airS = 1.8), airOnly)
        state.enqueue(airOnly!!)

        val jumpOnly = state.jumpRecordIfImproved(heightM = 2.4, airS = 1.7)
        assertEquals(PendingLiveRecord(jumpM = 2.4), jumpOnly)
        state.enqueue(jumpOnly!!)

        assertEquals(PendingLiveRecord(jumpM = 2.4, airS = 1.8), state.claimPendingRecord("local-1"))
        assertNull(state.claimPendingRecord("local-1"))
        assertNull(state.claimPendingRecord("other"))
    }
}
