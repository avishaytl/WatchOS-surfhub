package com.kiters.wear.engine

import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

// ================================================================
// Kitesurf Jump Engine — v7 (sensor-grounded), ported from
// KitesurfJumpEngine.swift. Pure math, no Android dependencies.
//
// UNITS (watch-native):
//   accel   : g, gravity REMOVED (userAcceleration)
//   gyro    : rad/s
//   gravity : g (unit-ish vector)
//   baro    : hPa
// ================================================================

internal object K {
    const val g: Double = 9.81
    const val p2m: Double = 8.43       // hPa -> metres (sea level)
    const val sampleRate: Double = 50.0
    const val dt: Double = 1.0 / 50.0
    const val ms2kn: Double = 1.94384
    const val ms2kmh: Double = 3.6
    const val deg2rad: Double = PI / 180.0
    const val twoPi: Double = 2.0 * PI
}

// MARK: - Sensor Sample (watch-native units)
data class SensorSample(
    /** Monotonic seconds since session start. */
    val t: Double,
    val ax: Double, val ay: Double, val az: Double,
    val aM: Double?,
    val gx: Double, val gy: Double, val gz: Double,
    val gM: Double?,
    val gravX: Double, val gravY: Double, val gravZ: Double,
    val baro: Double?,
    val gpsSpeedMS: Double?,
    val gpsLat: Double?,
    val gpsLon: Double?,
    val gpsAccuracyM: Double?,
) {
    val accelMagG: Double get() = aM ?: sqrt(ax * ax + ay * ay + az * az)
    val gyroMag: Double get() = gM ?: sqrt(gx * gx + gy * gy + gz * gz)
}

// MARK: - Jump Result
data class JumpResult(
    val jumpHeightMeters: Double,
    val baroHeightMeters: Double,
    val kinematicHeightMeters: Double,
    val airTimeSeconds: Double,
    val apexTimeSeconds: Double?,
    val rotations: Int,
    val jumpDistanceMeters: Double?,
    val jumpDistanceGPSMeters: Double?,
    val maxSessionSpeedKnots: Double,
    val maxSessionSpeedKmh: Double,
    val confidence: Double,                 // 0..1
    val landingKind: LandingKind,
    val heightSource: HeightSource,
    val deltaPressureHPa: Double,
    val peakTakeoffG: Double,
    val peakGyro: Double,
    val avgGyroQuality: Double,
    val takeoffIndex: Int,
    val landingIndex: Int,
) {
    enum class LandingKind(val rawValue: String) {
        HARD_IMPACT("hardImpact"),
        BARO_RECOVERY("baroRecovery"),
        SETTLE("settle"),
        TIMEOUT("timeout"),
    }

    enum class HeightSource(val rawValue: String) {
        KINEMATIC("kinematic"),
        BAROMETRIC("barometric"),
        BLENDED("blended"),
    }
}

// MARK: - DSP Primitives
object DSP {

    /** Sliding-median spike removal. */
    fun medianFilter(data: List<Double>, halfWindow: Int, causal: Boolean = false): List<Double> {
        if (data.isEmpty()) return emptyList()
        val w = maxOf(1, halfWindow)
        return data.indices.map { i ->
            val lo: Int
            val hi: Int
            if (causal) { lo = maxOf(0, i - 2 * w); hi = i }
            else { lo = maxOf(0, i - w); hi = minOf(data.size - 1, i + w) }
            val slice = data.subList(lo, hi + 1).sorted()
            val m = slice.size / 2
            if (slice.size % 2 == 0) (slice[m - 1] + slice[m]) / 2 else slice[m]
        }
    }

    /** First-order IIR low-pass. */
    fun lowPass(data: List<Double>, alpha: Double): List<Double> {
        if (data.isEmpty()) return emptyList()
        val a = maxOf(0.001, minOf(1.0, alpha))
        val out = ArrayList<Double>(data.size)
        out.add(data[0])
        for (i in 1 until data.size) out.add(a * data[i] + (1 - a) * out[i - 1])
        return out
    }

    fun median(a: List<Double>): Double {
        if (a.isEmpty()) return 0.0
        val s = a.sorted()
        val m = s.size / 2
        return if (s.size % 2 == 0) (s[m - 1] + s[m]) / 2 else s[m]
    }

    fun mean(a: List<Double>): Double = if (a.isEmpty()) 0.0 else a.sum() / a.size

    /** Sample standard deviation (population). */
    fun std(a: List<Double>): Double {
        if (a.size <= 1) return 0.0
        val m = mean(a)
        return sqrt(a.sumOf { (it - m) * (it - m) } / a.size)
    }

    fun dot3(ax: Double, ay: Double, az: Double, bx: Double, by: Double, bz: Double): Double =
        ax * bx + ay * by + az * bz

    fun normalize3(x: Double, y: Double, z: Double): Triple<Double, Double, Double> {
        val m = sqrt(x * x + y * y + z * z)
        return if (m > 0.001) Triple(x / m, y / m, z / m) else Triple(0.0, 0.0, -1.0)
    }

    fun clamp(v: Double, lo: Double, hi: Double): Double = maxOf(lo, minOf(hi, v))
}

// MARK: - GPS Utilities
object GpsUtil {
    fun haversine(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val r = 6_371_000.0
        val p1 = lat1 * PI / 180
        val p2 = lat2 * PI / 180
        val dp = (lat2 - lat1) * PI / 180
        val dl = (lon2 - lon1) * PI / 180
        val a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return r * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

// MARK: - Circular Buffer
class CircularBuffer<T>(val capacity: Int) {
    private val storage = arrayOfNulls<Any?>(capacity)
    private var head = 0
    private var filled = 0

    fun push(e: T) {
        storage[head] = e
        head = (head + 1) % capacity
        filled = minOf(filled + 1, capacity)
    }

    /** Last `count` elements in chronological order. */
    @Suppress("UNCHECKED_CAST")
    fun last(count: Int): List<T> {
        val take = minOf(count, filled)
        if (take <= 0) return emptyList()
        val result = ArrayList<T>(take)
        var idx = ((head - take) % capacity + capacity) % capacity
        repeat(take) {
            val e = storage[idx]
            if (e != null) result.add(e as T)
            idx = (idx + 1) % capacity
        }
        return result
    }

    fun clear() {
        for (i in storage.indices) storage[i] = null
        head = 0
        filled = 0
    }
}
