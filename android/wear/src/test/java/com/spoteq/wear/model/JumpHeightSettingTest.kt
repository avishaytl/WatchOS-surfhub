package com.spoteq.wear.model

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class JumpHeightSettingTest {

    @Test
    fun exposesExactlyTheSupportedOptionsAndDefault() {
        assertEquals(listOf(1.5, 2.0, 3.0, 4.0), JumpHeightSetting.OPTIONS_METERS)
        assertEquals(1.5, JumpHeightSetting.DEFAULT_METERS, 0.0)
    }

    @Test
    fun persistsAndReadsEverySupportedOption() {
        val store = InMemoryKeyValueStore()
        assertEquals(1.5, JumpHeightSetting.read(store), 0.0)

        JumpHeightSetting.OPTIONS_METERS.forEach { option ->
            JumpHeightSetting.write(store, option)
            assertEquals(option, JumpHeightSetting.read(store), 0.0)
        }
    }

    @Test
    fun rejectsUnsupportedWritesAndRepairsCorruptReads() {
        val store = InMemoryKeyValueStore()
        assertThrows(IllegalArgumentException::class.java) {
            JumpHeightSetting.write(store, 2.5)
        }

        store.setDouble(JumpHeightSetting.PREFERENCE_KEY, Double.NaN)
        assertEquals(1.5, JumpHeightSetting.read(store), 0.0)
    }

    @Test
    fun decodesCanonicalBitsAndLegacyNumericValues() {
        JumpHeightSetting.OPTIONS_METERS.forEach { option ->
            assertEquals(
                option,
                JumpHeightSetting.decodePersisted(JumpHeightSetting.encodePersisted(option)),
                0.0,
            )
            assertEquals(option, JumpHeightSetting.decodePersisted(option.toFloat()), 0.0)
        }
        assertEquals(2.0, JumpHeightSetting.decodePersisted(2L), 0.0)
        assertEquals(1.5, JumpHeightSetting.decodePersisted("invalid"), 0.0)
    }
}
