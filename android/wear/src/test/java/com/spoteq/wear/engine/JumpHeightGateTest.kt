package com.spoteq.wear.engine

import com.spoteq.wear.model.DetectionMode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

class JumpHeightGateTest {

    private fun fourSecondCandidate(): List<SensorSample> = List(230) { i ->
        SensorSample(
            t = i * 0.02,
            ax = 0.0,
            ay = 0.0,
            az = 9.80665,
            aM = null,
            gx = 0.0,
            gy = 0.0,
            gz = 0.0,
            gM = null,
            gravX = 0.0,
            gravY = 0.0,
            gravZ = -1.0,
            baro = null,
            gpsSpeedMS = null,
            gpsLat = null,
            gpsLon = null,
            gpsAccuracyM = null,
        )
    }

    private fun processAtThreshold(threshold: Double): JumpResult? =
        KitesurfJumpEngineV7(
            KitesurfJumpEngineV7.Config(minJumpHeightMeters = threshold),
        ).process(
            rawSamples = fourSecondCandidate(),
            takeoffHint = 10,
            landingHint = 210,
            landingKindHint = JumpResult.LandingKind.CONTACT,
            maxSessionSpeedMS = 0.0,
        )

    @Test
    fun engineActuallyFiltersUsingSelectedHeight() {
        val accepted = processAtThreshold(1.5)
        assertNotNull(accepted)
        assertEquals(1.6, accepted!!.jumpHeightMeters, 0.05)
        assertNull(processAtThreshold(2.0))
    }

    @Test
    fun detectorResetUsesTheSelectedHeight() {
        val detector = JumpDetector(synchronousAnalysis = true)
        detector.reset(DetectionMode.STANDARD, 3.0)
        assertEquals(3.0, detector.configuredMinJumpHeightMeters, 0.0)
    }
}
