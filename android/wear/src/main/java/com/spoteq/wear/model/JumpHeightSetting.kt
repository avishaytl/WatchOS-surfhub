package com.spoteq.wear.model

/**
 * User-facing minimum jump-height setting shared by persistence, UI and the
 * detector. Keeping the supported values here prevents the three layers from
 * drifting apart.
 */
object JumpHeightSetting {
    const val PREFERENCE_KEY = "minJumpHeightMeters"
    const val DEFAULT_METERS = 1.5

    val OPTIONS_METERS: List<Double> = listOf(1.5, 2.0, 3.0, 4.0)

    fun isSupported(value: Double): Boolean = OPTIONS_METERS.any { it == value }

    /** Invalid/corrupt persisted values safely migrate back to the default. */
    fun normalize(value: Double): Double =
        OPTIONS_METERS.firstOrNull { it == value } ?: DEFAULT_METERS

    /**
     * Decode both the canonical raw-Double-bits Long and values written by an
     * older Float/Number implementation of the sibling Wear target.
     */
    fun decodePersisted(raw: Any?): Double {
        val value = when (raw) {
            is Long -> Double.fromBits(raw).takeIf(::isSupported) ?: raw.toDouble()
            is Number -> raw.toDouble()
            else -> DEFAULT_METERS
        }
        return normalize(value)
    }

    fun encodePersisted(value: Double): Long {
        require(isSupported(value)) {
            "Minimum jump height must be one of $OPTIONS_METERS metres"
        }
        return value.toRawBits()
    }

    fun read(store: KeyValueStore): Double =
        normalize(store.getDouble(PREFERENCE_KEY, DEFAULT_METERS))

    fun write(store: KeyValueStore, value: Double) {
        require(isSupported(value)) {
            "Minimum jump height must be one of $OPTIONS_METERS metres"
        }
        store.setDouble(PREFERENCE_KEY, value)
    }
}
