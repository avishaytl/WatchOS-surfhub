package com.kiters.wear.session

import org.json.JSONArray
import org.json.JSONObject
import java.io.ByteArrayOutputStream
import java.nio.charset.StandardCharsets

/**
 * Binary KLOG envelope shared with the watchOS uploader.
 *
 * The payload schema is still JSON-shaped, but it is serialized as:
 * "KLOG" + version + flags + a tagged value tree.
 */
object BinaryLogEnvelope {
    private val magic = byteArrayOf('K'.code.toByte(), 'L'.code.toByte(), 'O'.code.toByte(), 'G'.code.toByte())
    private const val version = 1

    fun encode(value: Any?): ByteArray =
        ByteArrayOutputStream().apply {
            write(magic)
            write(version)
            write(0)
            writeValue(value)
        }.toByteArray()

    private fun ByteArrayOutputStream.writeValue(value: Any?) {
        when (value) {
            null, JSONObject.NULL -> write(0)
            is Boolean -> {
                write(1)
                write(if (value) 1 else 0)
            }
            is Byte, is Short, is Int, is Long -> {
                write(2)
                writeInt64((value as Number).toLong())
            }
            is Float, is Double -> {
                write(3)
                writeUInt64(java.lang.Double.doubleToRawLongBits((value as Number).toDouble()))
            }
            is Number -> {
                write(3)
                writeUInt64(java.lang.Double.doubleToRawLongBits(value.toDouble()))
            }
            is String -> writeStringValue(value)
            is ByteArray -> writeBlobValue(value)
            is JSONArray -> writeArrayValue((0 until value.length()).map { value.opt(it) })
            is JSONObject -> {
                val keys = value.keys().asSequence().toList().sorted()
                writeObjectValue(keys.map { it to value.opt(it) })
            }
            is Map<*, *> -> {
                val pairs = value.entries
                    .mapNotNull { (key, item) -> (key as? String)?.let { it to item } }
                    .sortedBy { it.first }
                writeObjectValue(pairs)
            }
            is Iterable<*> -> writeArrayValue(value.toList())
            is Array<*> -> writeArrayValue(value.toList())
            else -> write(0)
        }
    }

    private fun ByteArrayOutputStream.writeStringValue(value: String) {
        val bytes = value.toByteArray(StandardCharsets.UTF_8)
        write(4)
        writeUInt32(bytes.size)
        write(bytes)
    }

    private fun ByteArrayOutputStream.writeBlobValue(value: ByteArray) {
        write(5)
        writeUInt32(value.size)
        write(value)
    }

    private fun ByteArrayOutputStream.writeArrayValue(items: List<Any?>) {
        write(6)
        writeUInt32(items.size)
        items.forEach { writeValue(it) }
    }

    private fun ByteArrayOutputStream.writeObjectValue(pairs: List<Pair<String, Any?>>) {
        write(7)
        writeUInt32(pairs.size)
        pairs.forEach { (key, value) ->
            val keyBytes = key.toByteArray(StandardCharsets.UTF_8)
            writeUInt16(keyBytes.size)
            write(keyBytes)
            writeValue(value)
        }
    }

    private fun ByteArrayOutputStream.writeUInt16(value: Int) {
        val v = value.coerceIn(0, 0xffff)
        write(v and 0xff)
        write((v ushr 8) and 0xff)
    }

    private fun ByteArrayOutputStream.writeUInt32(value: Int) {
        val v = value.coerceAtLeast(0).toLong()
        write((v and 0xff).toInt())
        write(((v ushr 8) and 0xff).toInt())
        write(((v ushr 16) and 0xff).toInt())
        write(((v ushr 24) and 0xff).toInt())
    }

    private fun ByteArrayOutputStream.writeInt64(value: Long) = writeUInt64(value)

    private fun ByteArrayOutputStream.writeUInt64(value: Long) {
        for (shift in 0..56 step 8) {
            write(((value ushr shift) and 0xff).toInt())
        }
    }
}
