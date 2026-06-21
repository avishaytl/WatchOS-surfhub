package com.kiters.wear.engine

import com.kiters.wear.model.ImuSample
import com.kiters.wear.model.Vector3
import java.io.File
import java.time.LocalDateTime
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.math.PI
import kotlin.math.sqrt

/**
 * Minimal port of the Swift JumpReplay Loader/FormatDetector, used only for
 * the engine-parity unit test. Parses the same CSV fixtures the Swift harness
 * blesses, applying identical per-format unit conversions so the Kotlin engine
 * sees the exact same ImuSample values.
 */
object ReplayLoader {

    enum class Format { CORE_MOTION, ANDROID, ON_DEVICE }

    data class Loaded(val samples: List<ImuSample>, val speeds: List<Double?>, val format: Format)

    fun loadResource(name: String): Loaded {
        val text = ReplayLoader::class.java.classLoader!!
            .getResourceAsStream(name)!!.bufferedReader().readText()
        return parseCsv(text)
    }

    fun loadFile(path: String): Loaded {
        val file = resolveFixtureFile(path)
        val text = file.readText()
        return if (file.name.endsWith(".json")) parseJsonEnvelope(text) else parseCsv(text)
    }

    private fun resolveFixtureFile(path: String): File {
        val requested = File(path)
        if (requested.exists()) return requested

        val fixtureName = requested.name
        return listOf(
            File("docs", fixtureName),
            File("../docs", fixtureName),
            File("../../docs", fixtureName),
        ).firstOrNull { it.exists() } ?: requested
    }

    private fun parseJsonEnvelope(text: String): Loaded {
        val obj = Json.parseToJsonElement(text).jsonObject
        val contentType = obj["contentType"]?.jsonPrimitive?.content?.lowercase().orEmpty()
        val content = obj["content"]?.jsonPrimitive?.content
        if (contentType.contains("csv") && content != null) return parseCsv(content)
        error("unsupported replay JSON envelope")
    }

    private fun parseCsv(text: String): Loaded {
        val lines = text.split("\n", "\r\n", "\r").filter { it.isNotBlank() }
        val nonComment = lines.filter { !it.startsWith("#") }
        val rawHeader = nonComment.first().split(",").map { it.trim() }

        val isOnDevice = rawHeader.contains("ax") && !rawHeader.contains("accX")
        val aliases = mapOf(
            "t" to "timestamp",
            "ax" to "accX", "ay" to "accY", "az" to "accZ",
            "gvX" to "gravX", "gvY" to "gravY", "gvZ" to "gravZ",
            "gx" to "gyrX", "gy" to "gyrY", "gz" to "gyrZ",
        )
        val cols = if (isOnDevice) rawHeader.map { aliases[it] ?: it } else rawHeader
        fun idx(n: String) = cols.indexOf(n).takeIf { it >= 0 }

        val ti = idx("timestamp")!!
        val axi = idx("accX")!!
        val ayi = idx("accY"); val azi = idx("accZ")
        val gxi = idx("gravX"); val gyi = idx("gravY"); val gzi = idx("gravZ")
        val baroi = idx("baro")
        val spdi = idx("spd")
        val wxi = idx("gyrX"); val wyi = idx("gyrY"); val wzi = idx("gyrZ")

        data class Row(
            val t: Double, val ax: Double, val ay: Double, val az: Double,
            val gravX: Double, val gravY: Double, val gravZ: Double,
            val baro: Double, val gx: Double, val gy: Double, val gz: Double,
            val speed: Double?,
        )

        val rows = ArrayList<Row>()
        for (line in nonComment.drop(1)) {
            val f = line.split(",")
            if (f.size < cols.size) continue
            fun d(i: Int?) = i?.let { f.getOrNull(it)?.trim()?.toDoubleOrNull() } ?: 0.0
            rows.add(
                Row(
                    t = parseTimestamp(f[ti].trim()),
                    ax = d(axi), ay = d(ayi), az = d(azi),
                    gravX = d(gxi), gravY = d(gyi), gravZ = d(gzi),
                    baro = d(baroi),
                    gx = d(wxi), gy = d(wyi), gz = d(wzi),
                    speed = spdi?.let { f.getOrNull(it)?.trim()?.toDoubleOrNull() },
                )
            )
        }

        val format = if (isOnDevice) Format.ON_DEVICE else detectFormat(rows.take(200).map {
            sqrt(it.gravX * it.gravX + it.gravY * it.gravY + it.gravZ * it.gravZ)
        })

        val deg2rad = PI / 180.0
        val inv = 1.0 / 9.81
        val samples = rows.map { r ->
            val userAx: Double; val userAy: Double; val userAz: Double
            val gx: Double; val gy: Double; val gz: Double
            val wx: Double; val wy: Double; val wz: Double
            when (format) {
                Format.CORE_MOTION -> {
                    userAx = r.ax; userAy = r.ay; userAz = r.az
                    gx = r.gravX; gy = r.gravY; gz = r.gravZ
                    wx = r.gx; wy = r.gy; wz = r.gz
                }
                Format.ANDROID -> {
                    userAx = r.ax; userAy = r.ay; userAz = r.az
                    gx = r.gravX * 9.81; gy = r.gravY * 9.81; gz = r.gravZ * 9.81
                    wx = r.gx * deg2rad; wy = r.gy * deg2rad; wz = r.gz * deg2rad
                }
                Format.ON_DEVICE -> {
                    userAx = r.ax * 9.81; userAy = r.ay * 9.81; userAz = r.az * 9.81
                    gx = r.gravX * 9.81; gy = r.gravY * 9.81; gz = r.gravZ * 9.81
                    wx = r.gx; wy = r.gy; wz = r.gz
                }
            }
            ImuSample(
                timestamp = r.t,
                accelerationX = userAx * inv,
                accelerationY = userAy * inv,
                accelerationZ = userAz * inv,
                rotationX = wx, rotationY = wy, rotationZ = wz,
                gravity = Vector3(gx * inv, gy * inv, gz * inv),
                pressure = if (r.baro > 0) r.baro else null,
            )
        }
        return Loaded(samples, rows.map { it.speed }, format)
    }

    private fun detectFormat(gravMags: List<Double>): Format {
        if (gravMags.isEmpty()) return Format.CORE_MOTION
        val mean = gravMags.sum() / gravMags.size
        return if (mean < 3.0) Format.ANDROID else Format.CORE_MOTION
    }

    private val isoMicros: DateTimeFormatter =
        DateTimeFormatter.ofPattern("yyyy-MM-dd'T'HH:mm:ss[.SSSSSS][.SSS]")

    private fun parseTimestamp(s: String): Double {
        s.toDoubleOrNull()?.let { return it }
        return try {
            LocalDateTime.parse(s, isoMicros).toEpochSecond(ZoneOffset.UTC) +
                LocalDateTime.parse(s, isoMicros).nano / 1_000_000_000.0
        } catch (e: Exception) {
            0.0
        }
    }
}
