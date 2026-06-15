package com.kiters.wear.engine

import com.kiters.wear.model.DetectionMode
import com.kiters.wear.model.ImuSample
import com.kiters.wear.model.Jump
import com.kiters.wear.model.JumpDetectionConfig
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Engine-parity tests. These replay the same sensor-log fixtures the Swift
 * JumpReplay harness blesses, through the Kotlin v7 engine, and assert the
 * detected jumps match the Swift expected output (within rounding tolerance).
 *
 * Mirrors JumpReplay/main.swift: synchronousAnalysis=true, mode=standard,
 * a constant 8 m/s mock GPS emitted at most once per second.
 */
class EngineParityTest {

    private fun replay(resource: String, mockSpeed: Double = 8.0): List<Jump> {
        val loaded = ReplayLoader.loadResource(resource)
        val detector = JumpDetector(synchronousAnalysis = true)
        val jumps = ArrayList<Jump>()
        detector.onJumpDetected = { jumps.add(it) }
        JumpDetectionConfig.shared.devMode = false
        detector.reset(DetectionMode.STANDARD)

        var lastEmit: Double? = null
        for (sample in loaded.samples) {
            val le = lastEmit
            if (le == null || sample.timestamp - le >= 1.0) {
                lastEmit = sample.timestamp
                detector.updateGps(
                    speed = mockSpeed, altitude = 0.0,
                    latitude = 0.0, longitude = 0.0,
                    course = -1.0, timestamp = sample.timestamp,
                )
            }
            detector.processSample(sample)
        }
        return jumps
    }

    private fun replayResultsFromFile(path: String): List<JumpResult> {
        val loaded = ReplayLoader.loadFile(path)
        val session = KitesurfSession(
            detectorConfig = KitesurfJumpEngineV7.Config(),
            refractorySec = DetectionMode.STANDARD.cooldown,
            synchronousAnalysis = true,
        )
        val out = ArrayList<JumpResult>()
        session.onJumpDetected = { out.add(it) }
        session.start()
        for ((idx, sample) in loaded.samples.withIndex()) {
            val grav = sample.gravity
            session.onSample(
                SensorSample(
                    t = sample.timestamp,
                    ax = sample.accelerationX,
                    ay = sample.accelerationY,
                    az = sample.accelerationZ,
                    aM = sample.accelerationMagnitude,
                    gx = sample.rotationX,
                    gy = sample.rotationY,
                    gz = sample.rotationZ,
                    gM = sample.rotationMagnitude,
                    gravX = grav?.x ?: 0.0,
                    gravY = grav?.y ?: 0.0,
                    gravZ = grav?.z ?: -1.0,
                    baro = sample.pressure,
                    gpsSpeedMS = loaded.speeds.getOrNull(idx),
                    gpsLat = null,
                    gpsLon = null,
                    gpsAccuracyM = null,
                )
            )
        }
        return out
    }

    @Test
    fun realisticLog_detectsNoJumps() {
        // Swift expected: jumps = []
        val jumps = replay("kitesurf_realistic_log.csv")
        assertEquals("realistic log should detect no jumps", 0, jumps.size)
    }

    @Test
    fun ultraRealisticLog_detectsNoJumps() {
        // Swift expected: jumps = []
        val jumps = replay("kitesurf_ultra_realistic_log.csv")
        assertEquals("ultra-realistic log should detect no jumps", 0, jumps.size)
    }

    @Test
    fun syntheticLog_detectsOneJump_matchingSwift() {
        // Swift expected (kitesurf_jump_log_synthetic.expected.json):
        //   1 jump: height 3.09 m, airtime 1.5 s, rotations 8, confidence 42.9
        val jumps = replay("kitesurf_jump_log_synthetic.csv")
        assertEquals("synthetic log should emit exactly one jump", 1, jumps.size)
        val j = jumps.first()
        assertEquals("airtime", 1.5, j.airtime, 0.06)
        assertEquals("height", 3.09, j.height, 0.15)
        assertTrue("rotations near 8 (got ${j.rotations})", kotlin.math.abs(j.rotations - 8) <= 1)
        assertEquals("confidence (0..100)", 42.9, j.confidence, 1.5)
    }

    @Test
    fun engineHandlesEmptyAndTinyInputGracefully() {
        val engine = KitesurfJumpEngineV7()
        assertEquals(null, engine.process(emptyList(), maxSessionSpeedMS = 8.0))
        val tiny = List(5) {
            SensorSample(
                t = it * 0.02, ax = 0.0, ay = 0.0, az = 0.0, aM = null,
                gx = 0.0, gy = 0.0, gz = 0.0, gM = null,
                gravX = 0.0, gravY = 0.0, gravZ = -1.0, baro = null,
                gpsSpeedMS = null, gpsLat = null, gpsLon = null, gpsAccuracyM = null,
            )
        }
        assertEquals(null, engine.process(tiny, maxSessionSpeedMS = 8.0))
    }

    @Test
    fun surfrLog2_replayMatchesSwiftTimingShape() {
        val jumps = replayResultsFromFile("../log2.json")
        assertEquals("Swift replay currently emits 11 accepted candidates for log2", 11, jumps.size)
        val times = jumps.map { it.takeoffTimeSeconds }
        val expected = listOf(132.10, 148.55, 437.84, 484.50, 558.66, 646.24, 681.00, 743.76, 912.72, 981.74, 1624.04)
        expected.zip(times).forEachIndexed { idx, (e, actual) ->
            assertEquals("takeoff #$idx", e, actual, 0.15)
        }
        val firstSurfrWindow = jumps.minBy { kotlin.math.abs(it.takeoffTimeSeconds - 558.0) }
        assertEquals("first Surfr timing residual", 0.66, firstSurfrWindow.takeoffTimeSeconds - 558.0, 0.2)
    }
}
