package com.kiters.wear.storage

import android.content.Context
import android.util.Log
import com.kiters.wear.model.DetectionMode
import com.kiters.wear.model.ImuSample
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executors
import kotlin.math.roundToInt

/**
 * Per-session binary logger for debugging jump detection.
 *
 * New logs use .kslog: a small JSON metadata header followed by compact binary
 * sensor/event records. Older .csv logs are still listed, shared, and deleted.
 */
class SessionLogger private constructor() {

    private val ioExecutor = Executors.newSingleThreadExecutor()
    private var output: BufferedOutputStream? = null
    private var file: File? = null
    @Volatile private var active = false
    private var sampleIndex = 0
    private val buffer = ByteArrayOutputStream()
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
            val name = "log_${dateStr}_${sessionId.take(8)}.$BINARY_EXTENSION"
            val f = File(logsDir, name)
            file = null
            try {
                val out = BufferedOutputStream(FileOutputStream(f))
                output = out
                file = f
                sampleIndex = 0
                buffer.reset()
                active = true
                out.write(makeHeaderData(sessionId, dateStr, mode, devMode))
                Log.d(TAG, "SessionLogger started -> $name")
            } catch (e: Exception) {
                active = false
                Log.e(TAG, "cannot open log file", e)
            }
        }
    }

    /** Log one IMU sample. `t` is seconds since session start. */
    fun logSample(sample: ImuSample, t: Double, speed: Double, state: String, event: String = "") {
        if (!active) return
        val ax = sample.accelerationX
        val ay = sample.accelerationY
        val az = sample.accelerationZ
        val aM = sample.accelerationMagnitude
        val gx = sample.rotationX
        val gy = sample.rotationY
        val gz = sample.rotationZ
        val gM = sample.rotationMagnitude
        val gv = sample.gravity
        val baro = sample.pressure

        ioExecutor.execute {
            if (!active) return@execute
            sampleIndex += 1
            buffer.write(
                makeSampleRecord(
                    index = sampleIndex,
                    t = t,
                    ax = ax,
                    ay = ay,
                    az = az,
                    aM = aM,
                    gx = gx,
                    gy = gy,
                    gz = gz,
                    gM = gM,
                    gvX = gv?.x,
                    gvY = gv?.y,
                    gvZ = gv?.z,
                    baro = baro,
                    baseBaro = null,
                    speed = speed,
                    lowGCount = 0,
                    state = state,
                    event = event,
                )
            )
            if (sampleIndex % flushInterval == 0) flush()
        }
    }

    fun logEvent(event: String, state: String = "", speed: Double = 0.0, t: Double = 0.0) {
        if (!active) return
        ioExecutor.execute {
            if (!active) return@execute
            sampleIndex += 1
            buffer.write(makeEventRecord(sampleIndex, t, speed, state, event))
            flush()
        }
    }

    fun stop() {
        active = false
        ioExecutor.execute {
            closeOutput()
        }
    }

    fun mostRecentLogFile(): File? = file

    fun allLogFiles(): List<File> {
        if (!::logsDir.isInitialized) return emptyList()
        return (logsDir.listFiles { f -> f.extension.lowercase(Locale.US) in SUPPORTED_EXTENSIONS } ?: emptyArray())
            .sortedByDescending { it.name }
    }

    fun clearAllLogs() {
        allLogFiles().forEach { it.delete() }
    }

    fun deleteLogFile(file: File?) {
        ioExecutor.execute {
            val target = file ?: this.file ?: return@execute
            if (target.delete()) {
                Log.d(TAG, "Deleted log -> ${target.name}")
            }
            if (this.file?.absolutePath == target.absolutePath) {
                this.file = null
            }
        }
    }

    fun isBinaryLog(file: File): Boolean = file.extension.lowercase(Locale.US) == BINARY_EXTENSION

    fun buildShareText(file: File, maxChars: Int = 12_000): String =
        if (isBinaryLog(file)) buildBinaryShareText(file, maxChars) else buildCsvShareText(file, maxChars)

    fun estimatedRowCount(file: File): Int {
        val bytes = file.length().coerceAtLeast(0)
        if (!isBinaryLog(file)) return (bytes / 120L).toInt().coerceAtLeast(0)
        val headerLen = binaryHeaderLength(file) ?: return (bytes / SAMPLE_RECORD_MIN_SIZE).toInt().coerceAtLeast(0)
        val payloadBytes = (bytes - FILE_HEADER_SIZE - headerLen).coerceAtLeast(0)
        return (payloadBytes / SAMPLE_RECORD_MIN_SIZE).toInt().coerceAtLeast(0)
    }

    private fun flush() {
        if (buffer.size() == 0) return
        try {
            output?.write(buffer.toByteArray())
            buffer.reset()
        } catch (_: Exception) {
        }
    }

    private fun closeOutput() {
        val out = output
        output = null
        active = false
        try {
            if (buffer.size() > 0) {
                out?.write(buffer.toByteArray())
                buffer.reset()
            }
            out?.flush()
            out?.close()
        } catch (e: Exception) {
            Log.e(TAG, "error closing log", e)
        }
    }

    companion object {
        private const val TAG = "SessionLogger"
        private const val BINARY_EXTENSION = "kslog"
        private const val CSV_EXTENSION = "csv"
        private val SUPPORTED_EXTENSIONS = setOf(BINARY_EXTENSION, CSV_EXTENSION)
        private val MAGIC = byteArrayOf('K'.code.toByte(), 'S'.code.toByte(), 'L'.code.toByte(), 'G'.code.toByte())
        private const val VERSION = 1
        private const val FILE_HEADER_SIZE = 8
        private const val SAMPLE_RECORD_BODY_SIZE = 45
        private const val EVENT_RECORD_BODY_SIZE = 13
        private const val SAMPLE_RECORD_MIN_SIZE = 1 + SAMPLE_RECORD_BODY_SIZE
        private const val UINT16_MAX = 65_535
        private const val UINT32_MAX = 4_294_967_295L
        private const val TYPE_SAMPLE = 1
        private const val TYPE_EVENT = 2
        private const val CSV_COLUMNS = "idx,t,ax,ay,az,aM,gx,gy,gz,gM,gvX,gvY,gvZ,baro,baseBaro,spd,lowG,state,evt"

        val shared = SessionLogger()
        private val fileDateFormatter = SimpleDateFormat("yyyyMMdd_HHmmss", Locale.US)

        private fun makeHeaderData(sessionId: String, dateStr: String, mode: DetectionMode, devMode: Boolean): ByteArray {
            val json = buildString {
                append('{')
                appendJson("app", "SPOTEQ"); append(',')
                appendJson("format", "kslog"); append(',')
                append("\"version\":$VERSION,")
                appendJson("session", sessionId); append(',')
                appendJson("date", dateStr); append(',')
                appendJson("mode", mode.displayName); append(',')
                append("\"devMode\":$devMode,")
                append("\"sampleRateHz\":50,")
                append("\"parameters\":{")
                append("\"minSpeed\":${mode.minSpeed},")
                append("\"takeoffG\":${mode.takeoffG},")
                append("\"landingG\":${mode.landingG},")
                append("\"minAirtime\":${mode.minAirtime},")
                append("\"maxAirtime\":${mode.maxAirtime},")
                append("\"cooldown\":${mode.cooldown}")
                append("},")
                append("\"columns\":[")
                CSV_COLUMNS.split(',').forEachIndexed { i, col ->
                    if (i > 0) append(',')
                    appendJsonValue(col)
                }
                append("]}")
            }.toByteArray(Charsets.UTF_8)

            val clipped = if (json.size > UINT16_MAX) json.copyOf(UINT16_MAX) else json
            return ByteArrayOutputStream(FILE_HEADER_SIZE + clipped.size).apply {
                write(MAGIC)
                write(VERSION)
                write(0)
                writeUInt16(clipped.size)
                write(clipped)
            }.toByteArray()
        }

        private fun makeSampleRecord(
            index: Int,
            t: Double,
            ax: Double,
            ay: Double,
            az: Double,
            aM: Double,
            gx: Double,
            gy: Double,
            gz: Double,
            gM: Double,
            gvX: Double?,
            gvY: Double?,
            gvZ: Double?,
            baro: Double?,
            baseBaro: Double?,
            speed: Double,
            lowGCount: Int,
            state: String,
            event: String,
        ): ByteArray {
            val eventBytes = event.toByteArray(Charsets.UTF_8).let {
                if (it.size > UINT16_MAX) it.copyOf(UINT16_MAX) else it
            }
            return ByteArrayOutputStream(SAMPLE_RECORD_MIN_SIZE + eventBytes.size).apply {
                write(TYPE_SAMPLE)
                writeUInt32(index.coerceAtLeast(0).toLong())
                writeUInt32(milliseconds(t))
                writeInt16(scaledInt16(ax, 1000.0))
                writeInt16(scaledInt16(ay, 1000.0))
                writeInt16(scaledInt16(az, 1000.0))
                writeInt16(scaledInt16(aM, 1000.0))
                writeInt16(scaledInt16(gx, 1000.0))
                writeInt16(scaledInt16(gy, 1000.0))
                writeInt16(scaledInt16(gz, 1000.0))
                writeInt16(scaledInt16(gM, 1000.0))
                writeInt16(scaledInt16(gvX, 1000.0))
                writeInt16(scaledInt16(gvY, 1000.0))
                writeInt16(scaledInt16(gvZ, 1000.0))
                writeInt32(scaledInt32(baro, 100.0))
                writeInt32(scaledInt32(baseBaro, 100.0))
                writeUInt16(scaledUInt16(speed, 100.0))
                writeUInt16(lowGCount.coerceIn(0, UINT16_MAX))
                write(stateCode(state))
                writeUInt16(eventBytes.size)
                write(eventBytes)
            }.toByteArray()
        }

        private fun makeEventRecord(index: Int, t: Double, speed: Double, state: String, event: String): ByteArray {
            val eventBytes = event.toByteArray(Charsets.UTF_8).let {
                if (it.size > UINT16_MAX) it.copyOf(UINT16_MAX) else it
            }
            return ByteArrayOutputStream(1 + EVENT_RECORD_BODY_SIZE + eventBytes.size).apply {
                write(TYPE_EVENT)
                writeUInt32(index.coerceAtLeast(0).toLong())
                writeUInt32(milliseconds(t))
                writeUInt16(scaledUInt16(speed, 100.0))
                write(stateCode(state))
                writeUInt16(eventBytes.size)
                write(eventBytes)
            }.toByteArray()
        }

        private fun buildBinaryShareText(file: File, maxChars: Int): String {
            BufferedInputStream(FileInputStream(file)).use { input ->
                val header = readHeader(input) ?: return "SPOTEQ Session Log\nFile: ${file.name}\nSize: ${file.length()} bytes\nFormat: binary kslog\n"
                val text = StringBuilder()
                text.append("SPOTEQ Session Log\n")
                text.append("File: ${file.name}\n")
                text.append("Size: ${file.length()} bytes\n")
                text.append("Format: binary kslog\n")
                text.append(header).append("\n\n")
                text.append("CSV preview decoded from binary:\n")
                text.append(CSV_COLUMNS).append('\n')

                while (text.length < maxChars) {
                    val type = input.read()
                    if (type < 0) break
                    val line = when (type) {
                        TYPE_SAMPLE -> readSamplePreviewLine(input)
                        TYPE_EVENT -> readEventPreviewLine(input)
                        else -> null
                    } ?: break
                    if (text.length + line.length + 1 > maxChars) {
                        text.append("\n... (truncated - send to phone for full file)\n")
                        break
                    }
                    text.append(line).append('\n')
                }
                return text.toString()
            }
        }

        private fun buildCsvShareText(file: File, maxChars: Int): String =
            try {
                val prefix = "SPOTEQ Session Log\nFile: ${file.name}\nSize: ${file.length()} bytes\n\n"
                prefix + file.readText().take(maxChars - prefix.length)
            } catch (_: Exception) {
                ""
            }

        private fun readHeader(input: BufferedInputStream): String? {
            val fileHeader = input.readNBytesCompat(FILE_HEADER_SIZE)
            if (fileHeader.size != FILE_HEADER_SIZE || !fileHeader.copyOfRange(0, 4).contentEquals(MAGIC)) return null
            val headerLen = readUInt16(fileHeader, 6)
            val headerBytes = input.readNBytesCompat(headerLen)
            if (headerBytes.size != headerLen) return null
            return String(headerBytes, Charsets.UTF_8)
        }

        private fun binaryHeaderLength(file: File): Int? =
            try {
                BufferedInputStream(FileInputStream(file)).use { input ->
                    val header = input.readNBytesCompat(FILE_HEADER_SIZE)
                    if (header.size != FILE_HEADER_SIZE || !header.copyOfRange(0, 4).contentEquals(MAGIC)) null
                    else readUInt16(header, 6)
                }
            } catch (_: Exception) {
                null
            }

        private fun readSamplePreviewLine(input: BufferedInputStream): String? {
            val body = input.readNBytesCompat(SAMPLE_RECORD_BODY_SIZE)
            if (body.size != SAMPLE_RECORD_BODY_SIZE) return null
            var offset = 0
            val idx = readUInt32(body, offset); offset += 4
            val tMs = readUInt32(body, offset); offset += 4
            val ax = readInt16(body, offset); offset += 2
            val ay = readInt16(body, offset); offset += 2
            val az = readInt16(body, offset); offset += 2
            val aM = readInt16(body, offset); offset += 2
            val gx = readInt16(body, offset); offset += 2
            val gy = readInt16(body, offset); offset += 2
            val gz = readInt16(body, offset); offset += 2
            val gM = readInt16(body, offset); offset += 2
            val gvX = readInt16(body, offset); offset += 2
            val gvY = readInt16(body, offset); offset += 2
            val gvZ = readInt16(body, offset); offset += 2
            val baro = readInt32(body, offset); offset += 4
            val baseBaro = readInt32(body, offset); offset += 4
            val speed = readUInt16(body, offset); offset += 2
            val lowG = readUInt16(body, offset); offset += 2
            val state = body[offset].toInt() and 0xff; offset += 1
            val eventLength = readUInt16(body, offset)
            val event = String(input.readNBytesCompat(eventLength), Charsets.UTF_8)

            return listOf(
                idx.toString(),
                "%.3f".format(Locale.US, tMs / 1000.0),
                formatScaled(ax, Short.MIN_VALUE.toInt(), 1000.0, 3),
                formatScaled(ay, Short.MIN_VALUE.toInt(), 1000.0, 3),
                formatScaled(az, Short.MIN_VALUE.toInt(), 1000.0, 3),
                formatScaled(aM, Short.MIN_VALUE.toInt(), 1000.0, 3),
                formatScaled(gx, Short.MIN_VALUE.toInt(), 1000.0, 3),
                formatScaled(gy, Short.MIN_VALUE.toInt(), 1000.0, 3),
                formatScaled(gz, Short.MIN_VALUE.toInt(), 1000.0, 3),
                formatScaled(gM, Short.MIN_VALUE.toInt(), 1000.0, 3),
                formatScaled(gvX, Short.MIN_VALUE.toInt(), 1000.0, 3),
                formatScaled(gvY, Short.MIN_VALUE.toInt(), 1000.0, 3),
                formatScaled(gvZ, Short.MIN_VALUE.toInt(), 1000.0, 3),
                formatScaled(baro, Int.MIN_VALUE, 100.0, 2),
                formatScaled(baseBaro, Int.MIN_VALUE, 100.0, 2),
                "%.2f".format(Locale.US, speed / 100.0),
                lowG.toString(),
                stateName(state),
                sanitizeCsv(event),
            ).joinToString(",")
        }

        private fun readEventPreviewLine(input: BufferedInputStream): String? {
            val body = input.readNBytesCompat(EVENT_RECORD_BODY_SIZE)
            if (body.size != EVENT_RECORD_BODY_SIZE) return null
            var offset = 0
            val idx = readUInt32(body, offset); offset += 4
            val tMs = readUInt32(body, offset); offset += 4
            val speed = readUInt16(body, offset); offset += 2
            val state = body[offset].toInt() and 0xff; offset += 1
            val eventLength = readUInt16(body, offset)
            val event = String(input.readNBytesCompat(eventLength), Charsets.UTF_8)
            return "$idx,${"%.3f".format(Locale.US, tMs / 1000.0)},,,,,,,,,,,,,,${"%.2f".format(Locale.US, speed / 100.0)},,${stateName(state)},${sanitizeCsv(event)}"
        }

        private fun StringBuilder.appendJson(name: String, value: String) {
            appendJsonValue(name)
            append(':')
            appendJsonValue(value)
        }

        private fun StringBuilder.appendJsonValue(value: String) {
            append('"')
            value.forEach { ch ->
                when (ch) {
                    '\\' -> append("\\\\")
                    '"' -> append("\\\"")
                    '\n' -> append("\\n")
                    '\r' -> append("\\r")
                    '\t' -> append("\\t")
                    else -> append(ch)
                }
            }
            append('"')
        }

        private fun ByteArrayOutputStream.writeUInt16(value: Int) {
            val v = value.coerceIn(0, UINT16_MAX)
            write(v and 0xff)
            write((v ushr 8) and 0xff)
        }

        private fun ByteArrayOutputStream.writeUInt32(value: Long) {
            val v = value.coerceIn(0L, UINT32_MAX)
            write((v and 0xff).toInt())
            write(((v ushr 8) and 0xff).toInt())
            write(((v ushr 16) and 0xff).toInt())
            write(((v ushr 24) and 0xff).toInt())
        }

        private fun ByteArrayOutputStream.writeInt16(value: Int) = writeUInt16(value and 0xffff)

        private fun ByteArrayOutputStream.writeInt32(value: Int) {
            write(value and 0xff)
            write((value ushr 8) and 0xff)
            write((value ushr 16) and 0xff)
            write((value ushr 24) and 0xff)
        }

        private fun milliseconds(t: Double): Long = ((t.coerceAtLeast(0.0)) * 1000.0).roundToInt().toLong()

        private fun scaledInt16(value: Double?, scale: Double): Int {
            if (value == null || !value.isFinite()) return Short.MIN_VALUE.toInt()
            return (value * scale).roundToInt().coerceIn(Short.MIN_VALUE.toInt(), Short.MAX_VALUE.toInt())
        }

        private fun scaledInt32(value: Double?, scale: Double): Int {
            if (value == null || !value.isFinite()) return Int.MIN_VALUE
            val scaled = value * scale
            return when {
                scaled > Int.MAX_VALUE -> Int.MAX_VALUE
                scaled < Int.MIN_VALUE -> Int.MIN_VALUE
                else -> scaled.roundToInt()
            }
        }

        private fun scaledUInt16(value: Double, scale: Double): Int {
            if (!value.isFinite()) return 0
            return (value * scale).roundToInt().coerceIn(0, UINT16_MAX)
        }

        private fun stateCode(state: String): Int {
            val normalized = state.lowercase(Locale.US)
            return when {
                normalized.contains("idle") -> 0
                normalized.contains("riding") -> 1
                normalized.contains("airborne") -> 2
                normalized.contains("cooldown") -> 3
                else -> 255
            }
        }

        private fun stateName(code: Int): String = when (code) {
            0 -> "idle"
            1 -> "riding"
            2 -> "airborne"
            3 -> "cooldown"
            else -> ""
        }

        private fun readUInt16(bytes: ByteArray, offset: Int): Int =
            (bytes[offset].toInt() and 0xff) or ((bytes[offset + 1].toInt() and 0xff) shl 8)

        private fun readInt16(bytes: ByteArray, offset: Int): Int {
            val value = readUInt16(bytes, offset)
            return if (value and 0x8000 != 0) value - 0x10000 else value
        }

        private fun readUInt32(bytes: ByteArray, offset: Int): Long =
            (bytes[offset].toLong() and 0xffL) or
                ((bytes[offset + 1].toLong() and 0xffL) shl 8) or
                ((bytes[offset + 2].toLong() and 0xffL) shl 16) or
                ((bytes[offset + 3].toLong() and 0xffL) shl 24)

        private fun readInt32(bytes: ByteArray, offset: Int): Int =
            (bytes[offset].toInt() and 0xff) or
                ((bytes[offset + 1].toInt() and 0xff) shl 8) or
                ((bytes[offset + 2].toInt() and 0xff) shl 16) or
                (bytes[offset + 3].toInt() shl 24)

        private fun formatScaled(value: Int, sentinel: Int, scale: Double, decimals: Int): String =
            if (value == sentinel) "" else "%.${decimals}f".format(Locale.US, value / scale)

        private fun sanitizeCsv(value: String): String =
            value.replace('\n', ' ').replace('\r', ' ').replace(',', ';')

        private fun BufferedInputStream.readNBytesCompat(count: Int): ByteArray {
            val result = ByteArray(count)
            var offset = 0
            while (offset < count) {
                val read = read(result, offset, count - offset)
                if (read < 0) break
                offset += read
            }
            return if (offset == count) result else result.copyOf(offset)
        }
    }
}
