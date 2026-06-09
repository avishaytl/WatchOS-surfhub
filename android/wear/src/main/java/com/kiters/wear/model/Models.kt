package com.kiters.wear.model

import com.kiters.wear.engine.GpsUtil
import kotlinx.serialization.Serializable
import java.util.UUID
import kotlin.math.sqrt

// MARK: - Supporting Types

@Serializable
data class Vector3(val x: Double, val y: Double, val z: Double)

@Serializable
enum class Sport {
    KITEBOARDING;
    // windsurfing / wingfoiling / surfing — disabled, matching the watchOS app

    val displayName: String
        get() = when (this) {
            KITEBOARDING -> "Kiteboarding"
        }
}

@Serializable
enum class SessionStatus { ACTIVE, PAUSED, COMPLETED }

// MARK: - GPS Point

@Serializable
data class GpsPoint(
    val timestampMs: Long,
    val latitude: Double,
    val longitude: Double,
    val altitude: Double,
    val speed: Double,          // m/s, clamped to >= 0
    val course: Double,
    val horizontalAccuracy: Double,
    val verticalAccuracy: Double,
)

// MARK: - IMU Sample
//   accel: g (gravity removed, like CMDeviceMotion.userAcceleration)
//   rotation: rad/s
//   gravity: g (unit-ish vector)
//   pressure: hPa (nil when unavailable)
//   timestamp: monotonic seconds (sensor clock)

data class ImuSample(
    val timestamp: Double,
    val accelerationX: Double,
    val accelerationY: Double,
    val accelerationZ: Double,
    val rotationX: Double,
    val rotationY: Double,
    val rotationZ: Double,
    val gravity: Vector3?,
    val pressure: Double?,
) {
    val accelerationMagnitude: Double
        get() = sqrt(
            accelerationX * accelerationX +
                accelerationY * accelerationY +
                accelerationZ * accelerationZ
        )

    val rotationMagnitude: Double
        get() = sqrt(
            rotationX * rotationX +
                rotationY * rotationY +
                rotationZ * rotationZ
        )
}

// MARK: - Jump Model

@Serializable
data class Jump(
    val id: String = UUID.randomUUID().toString(),
    var sessionId: String,
    var startTimeMs: Long,
    var endTimeMs: Long,
    var height: Double = 0.0,          // metres
    var airtime: Double = 0.0,         // seconds
    var jumpDistance: Double = 0.0,    // metres
    var rotations: Int = 0,
    var confidence: Double = 0.0,      // 0..100
    var apexTime: Double? = null,      // seconds, takeoff -> apex
)

// MARK: - Session Model

@Serializable
data class Session(
    val id: String = UUID.randomUUID().toString(),
    var startTimeMs: Long,
    var endTimeMs: Long? = null,
    var sport: Sport = Sport.KITEBOARDING,
    var status: SessionStatus = SessionStatus.ACTIVE,
    var gpsPoints: MutableList<GpsPoint> = mutableListOf(),
    var jumps: MutableList<Jump> = mutableListOf(),
    /** Cached cumulative GPS distance (metres), updated incrementally. */
    var cachedDistance: Double = 0.0,
) {
    /** Duration in seconds. */
    val duration: Double
        get() {
            val end = endTimeMs ?: System.currentTimeMillis()
            return (end - startTimeMs) / 1000.0
        }

    val distance: Double
        get() = if (cachedDistance > 0) cachedDistance else calculateTotalDistance()

    val maxSpeed: Double
        get() = gpsPoints.maxOfOrNull { it.speed } ?: 0.0

    val avgSpeed: Double
        get() = if (gpsPoints.isEmpty()) 0.0
        else gpsPoints.sumOf { it.speed } / gpsPoints.size

    private fun calculateTotalDistance(): Double {
        if (gpsPoints.size < 2) return 0.0
        var total = 0.0
        for (i in 1 until gpsPoints.size) {
            val a = gpsPoints[i - 1]
            val b = gpsPoints[i]
            total += GpsUtil.haversine(a.latitude, a.longitude, b.latitude, b.longitude)
        }
        return total
    }

    companion object {
        fun create(sport: Sport): Session = Session(
            startTimeMs = System.currentTimeMillis(),
            sport = sport,
        )
    }
}
