package com.spoteq.wear.model

/** GPS signal quality buckets, identical thresholds to the watchOS app. */
enum class GpsSignalQuality(val rawValue: String) {
    NONE("none"),
    WEAK("weak"),
    FAIR("fair"),
    GOOD("good"),
    STRONG("strong");

    companion object {
        fun from(accuracy: Double): GpsSignalQuality = when {
            accuracy <= 0 -> NONE
            accuracy < 5 -> STRONG
            accuracy < 15 -> GOOD
            accuracy < 30 -> FAIR
            else -> WEAK
        }
    }
}

/** Location permission state, mirroring CLAuthorizationStatus usage in the app. */
enum class LocationAuthStatus { NOT_DETERMINED, AUTHORIZED, DENIED }
