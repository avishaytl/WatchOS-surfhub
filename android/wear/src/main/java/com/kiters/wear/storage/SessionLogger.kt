package com.kiters.wear.storage

import android.content.Context
import android.util.Log
import com.kiters.wear.model.DetectionMode
import com.kiters.wear.model.ImuSample
import java.io.File
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Per-session CSV logger for debugging jump detection. Writes the SAME
 * 19-column schema + self-documenting header as the watchOS SessionLogger,
 * to filesDir/session_logs/log_yyyyMMdd_HHmmss_<id8>.csv.
 *
 * All file IO runs on a single-thread executor (mirrors the iOS serial ioQueue)
 * so it never blocks the 50 Hz sensor thread.
 */
class SessionLogger private constructor() {

    private val ioExecutor = Executors.newSingleThreadExecutor()
    private var writer: java.io.BufferedWriter? = null
    private var file: File? = null
    private var active = false
    private var sampleIndex = 0
    private val buffer = StringBuilder()
    private val flushInterval = 250

    private lateinit var logsDir: File

    fun init(context: Context) {
        logsDir = File(context.applicationContext.filesDir, "session_logs")
    }

    fun start(sessionId: String, mode: DetectionMode, devMode: Boolean) {
        stop()
        ioExecutor.execute {
            if (!logsDir.exists()) logsDir.mkdirs()
            val dateStr = fileDateFormatter.format(Date())
            val name = "log_${dateStr}_${sessionId.take(8)}.csv"
            val f = File(logsDir, name)
            try {
                val w = f.bufferedWriter()
                writer = w
                file = f
                sampleIndex = 0
                buffer.setLength(0)
                active = true

                val h = StringBuilder()
                h.append("# Kiters Session Log\n")
                h.append("# session: $sessionId\n")
                h.append("# date: $dateStr\n")
                h.append("# mode: ${mode.displayName}\n")
                h.append("# devMode: $devMode\n")
                h.append("# sampleRate: 50 Hz\n")
                h.append("# --- 6 Parameters ---\n")
                h.append("# minSpeed(m/s): ${"%.2f".format(mode.minSpeed)}\n")
                h.append("# takeoffG(g): ${"%.2f".format(mode.takeoffG)}\n")
                h.append("# landingG(g): ${"%.2f".format(mode.landingG)}\n")
                h.append("# minAirtime(s): ${"%.2f".format(mode.minAirtime)}\n")
                h.append("# maxAirtime(s): ${"%.2f".format(mode.maxAirtime)}\n")
                h.append("# cooldown(s): ${"%.2f".format(mode.cooldown)}\n")
                h.append("# --- Columns ---\n")
                h.append("# ax/ay/az = userAcceleration (g, gravity removed)\n")
                h.append("# gx/gy/gz = gyroscope (rad/s)\n")
                h.append("# gvX/gvY/gvZ = gravity vector (g)\n")
                h.append("# baro = barometric pressure (hPa)\n")
                h.append("# baseBaro = rolling baseline pressure (hPa)\n")
                h.append("# spd = GPS speed (m/s)\n")
                h.append("# lowG = consecutive low-g sample count\n")
                h.append("# -----------------------\n")
                h.append("idx,t,ax,ay,az,aM,gx,gy,gz,gM,gvX,gvY,gvZ,baro,baseBaro,spd,lowG,state,evt\n")
                w.write(h.toString())
                Log.d(TAG, "SessionLogger started -> $name")
            } catch (e: Exception) {
                Log.e(TAG, "cannot open log file", e)
            }
        }
    }

    /** Log one IMU sample. `t` is seconds since session start. */
    fun logSample(sample: ImuSample, t: Double, speed: Double, state: String, event: String = "") {
        if (!active) return
        val ax = sample.accelerationX; val ay = sample.accelerationY; val az = sample.accelerationZ
        val aM = sample.accelerationMagnitude
        val gx = sample.rotationX; val gy = sample.rotationY; val gz = sample.rotationZ
        val gM = sample.rotationMagnitude
        val gv = sample.gravity
        val baro = sample.pressure
        ioExecutor.execute {
            if (!active) return@execute
            sampleIndex += 1
            val gvX = gv?.let { "%.3f".format(it.x) } ?: ""
            val gvY = gv?.let { "%.3f".format(it.y) } ?: ""
            val gvZ = gv?.let { "%.3f".format(it.z) } ?: ""
            val baroStr = baro?.let { "%.2f".format(it) } ?: ""
            buffer.append(sampleIndex).append(',')
                .append("%.3f".format(t)).append(',')
                .append(f(ax)).append(',').append(f(ay)).append(',').append(f(az)).append(',').append(f(aM)).append(',')
                .append(f(gx)).append(',').append(f(gy)).append(',').append(f(gz)).append(',').append(f(gM)).append(',')
                .append(gvX).append(',').append(gvY).append(',').append(gvZ).append(',')
                .append(baroStr).append(',').append("").append(',')
                .append("%.2f".format(speed)).append(',').append(0).append(',')
                .append(state).append(',').append(event).append('\n')
            if (sampleIndex % flushInterval == 0) flush()
        }
    }

    fun logEvent(event: String, state: String = "", speed: Double = 0.0, t: Double = 0.0) {
        if (!active) return
        ioExecutor.execute {
            if (!active) return@execute
            sampleIndex += 1
            buffer.append(sampleIndex).append(',').append("%.3f".format(t))
                .append(",,,,,,,,,,,,,,").append("%.2f".format(speed)).append(",,")
                .append(state).append(',').append(event).append('\n')
            flush()
        }
    }

    fun stop() {
        if (!active) return
        active = false
        val w = writer
        writer = null
        ioExecutor.execute {
            try {
                if (buffer.isNotEmpty()) { w?.write(buffer.toString()); buffer.setLength(0) }
                w?.flush(); w?.close()
            } catch (e: Exception) {
                Log.e(TAG, "error closing log", e)
            }
        }
    }

    fun mostRecentLogFile(): File? = file

    fun allLogFiles(): List<File> {
        if (!::logsDir.isInitialized) return emptyList()
        return (logsDir.listFiles { f -> f.extension == "csv" } ?: emptyArray())
            .sortedByDescending { it.name }
    }

    fun clearAllLogs() {
        allLogFiles().forEach { it.delete() }
    }

    private fun flush() {
        if (buffer.isEmpty()) return
        try { writer?.write(buffer.toString()); buffer.setLength(0) } catch (_: Exception) {}
    }

    private fun f(v: Double): String = "%.3f".format(v)

    companion object {
        private const val TAG = "SessionLogger"
        val shared = SessionLogger()
        private val fileDateFormatter = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US)
    }
}
