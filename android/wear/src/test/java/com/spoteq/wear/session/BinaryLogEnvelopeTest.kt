package com.spoteq.wear.session

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class BinaryLogEnvelopeTest {
    @Test
    fun encodesKlogContainerForLifecyclePayloads() {
        val bytes = BinaryLogEnvelope.encode(
            mapOf(
                "type" to "start",
                "lat" to 32.835421,
                "lng" to 34.967118,
            ),
        )

        assertArrayEquals(byteArrayOf('K'.code.toByte(), 'L'.code.toByte(), 'O'.code.toByte(), 'G'.code.toByte()), bytes.copyOfRange(0, 4))
        assertEquals(1, bytes[4].toInt())
        assertEquals(0, bytes[5].toInt())
        assertEquals(7, bytes[6].toInt())
        assertTrue(bytes.size > 20)
    }
}
