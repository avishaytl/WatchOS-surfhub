package com.spoteq.wear.model

// MARK: - Key/Value backing store
// Mirrors the role of UserDefaults in the watchOS app. The engine and
// JumpDetectionConfig read synchronously, so this stays synchronous.
// The Android app installs a SharedPreferences-backed implementation;
// unit tests use the default in-memory one.

interface KeyValueStore {
    fun getDouble(key: String, default: Double): Double
    fun setDouble(key: String, value: Double)
    fun getBool(key: String, default: Boolean): Boolean
    fun setBool(key: String, value: Boolean)
    fun getString(key: String): String?
    fun setString(key: String, value: String?)
    fun contains(key: String): Boolean
}

class InMemoryKeyValueStore : KeyValueStore {
    private val map = HashMap<String, Any?>()
    override fun getDouble(key: String, default: Double) = (map[key] as? Double) ?: default
    override fun setDouble(key: String, value: Double) { map[key] = value }
    override fun getBool(key: String, default: Boolean) = (map[key] as? Boolean) ?: default
    override fun setBool(key: String, value: Boolean) { map[key] = value }
    override fun getString(key: String) = map[key] as? String
    override fun setString(key: String, value: String?) { map[key] = value }
    override fun contains(key: String) = map.containsKey(key)
}

// MARK: - Jump Detection Mode
// User-selectable algorithm preset, stored under "detectionMode".

enum class DetectionMode {
    STANDARD,
    CUSTOM;

    val rawValue: String get() = name.lowercase()

    val displayName: String
        get() = when (this) {
            STANDARD -> "Standard"
            CUSTOM -> "Custom"
        }

    val description: String
        get() = when (this) {
            STANDARD -> "Optimised for real-world kiteboarding."
            CUSTOM -> "Fine-tune parameters yourself."
        }

    // 6 core parameters + kinematic calibration
    val minSpeed: Double
        get() = when (this) {
            STANDARD -> JumpDetectionConfig.shared.standardMinSpeed
            CUSTOM -> JumpDetectionConfig.shared.minSpeed
        }
    val takeoffG: Double
        get() = when (this) {
            STANDARD -> JumpDetectionConfig.shared.standardTakeoffG
            CUSTOM -> JumpDetectionConfig.shared.takeoffG
        }
    val landingG: Double
        get() = when (this) {
            STANDARD -> JumpDetectionConfig.shared.standardLandingG
            CUSTOM -> JumpDetectionConfig.shared.landingG
        }
    val minAirtime: Double
        get() = when (this) {
            STANDARD -> JumpDetectionConfig.shared.standardMinAirtime
            CUSTOM -> JumpDetectionConfig.shared.minAirtime
        }
    val maxAirtime: Double
        get() = when (this) {
            STANDARD -> JumpDetectionConfig.shared.standardMaxAirtime
            CUSTOM -> JumpDetectionConfig.shared.maxAirtime
        }
    val cooldown: Double
        get() = when (this) {
            STANDARD -> JumpDetectionConfig.shared.standardCooldown
            CUSTOM -> JumpDetectionConfig.shared.cooldown
        }
    val kinematicCalibration: Double
        get() = when (this) {
            STANDARD -> JumpDetectionConfig.shared.standardKinematicCalibration
            CUSTOM -> JumpDetectionConfig.shared.kinematicCalibration
        }

    companion object {
        fun fromRaw(raw: String?): DetectionMode =
            entries.firstOrNull { it.rawValue == raw } ?: STANDARD
    }
}

// MARK: - Jump Detection Configuration (6 parameters)
// Faithful port of the Swift JumpDetectionConfig (UserDefaults-backed).

class JumpDetectionConfig(private var store: KeyValueStore) {
    private val currentStandardCalibrationVersion = "surfr-v7-20260619-strict-gpsfree"

    init {
        installStandardCalibrationIfNeeded()
    }

    private object Key {
        const val minSpeed = "jd_minSpeed"
        const val takeoffG = "jd_takeoffG"
        const val landingG = "jd_landingG"
        const val minAirtime = "jd_minAirtime"
        const val maxAirtime = "jd_maxAirtime"
        const val cooldown = "jd_cooldown"
        const val devMode = "jd_devMode"
        const val kinematicCalibration = "jd_kinematicCalibration"
        const val standardMinSpeed = "jd_standard_minSpeed"
        const val standardTakeoffG = "jd_standard_takeoffG"
        const val standardLandingG = "jd_standard_landingG"
        const val standardMinAirtime = "jd_standard_minAirtime"
        const val standardMaxAirtime = "jd_standard_maxAirtime"
        const val standardCooldown = "jd_standard_cooldown"
        const val standardKinematicCalibration = "jd_standard_kinematicCalibration"
        const val standardCalibrationVersion = "jd_standard_calibrationVersion"
    }

    var standardMinSpeed: Double
        get() = store.getDouble(Key.standardMinSpeed, 5.0 / 3.6)
        set(v) = store.setDouble(Key.standardMinSpeed, v)
    var standardTakeoffG: Double
        get() = store.getDouble(Key.standardTakeoffG, 1.7)
        set(v) = store.setDouble(Key.standardTakeoffG, v)
    var standardLandingG: Double
        get() = store.getDouble(Key.standardLandingG, 1.4)
        set(v) = store.setDouble(Key.standardLandingG, v)
    var standardMinAirtime: Double
        get() = store.getDouble(Key.standardMinAirtime, 2.0)
        set(v) = store.setDouble(Key.standardMinAirtime, v)
    var standardMaxAirtime: Double
        get() = store.getDouble(Key.standardMaxAirtime, 6.5)
        set(v) = store.setDouble(Key.standardMaxAirtime, v)
    var standardCooldown: Double
        get() = store.getDouble(Key.standardCooldown, 1.0)
        set(v) = store.setDouble(Key.standardCooldown, v)
    var standardKinematicCalibration: Double
        get() = store.getDouble(Key.standardKinematicCalibration, 1.0)
        set(v) = store.setDouble(Key.standardKinematicCalibration, v)
    var standardCalibrationVersion: String?
        get() = store.getString(Key.standardCalibrationVersion)
        set(v) = store.setString(Key.standardCalibrationVersion, v)

    var minSpeed: Double
        get() = store.getDouble(Key.minSpeed, 15.0 / 3.6)
        set(v) = store.setDouble(Key.minSpeed, v)
    var takeoffG: Double
        get() = store.getDouble(Key.takeoffG, 1.5)
        set(v) = store.setDouble(Key.takeoffG, v)
    var landingG: Double
        get() = store.getDouble(Key.landingG, 2.0)
        set(v) = store.setDouble(Key.landingG, v)
    var minAirtime: Double
        get() = store.getDouble(Key.minAirtime, 0.5)
        set(v) = store.setDouble(Key.minAirtime, v)
    var maxAirtime: Double
        get() = store.getDouble(Key.maxAirtime, 8.0)
        set(v) = store.setDouble(Key.maxAirtime, v)
    var cooldown: Double
        get() = store.getDouble(Key.cooldown, 1.5)
        set(v) = store.setDouble(Key.cooldown, v)
    var kinematicCalibration: Double
        get() = store.getDouble(Key.kinematicCalibration, 1.12)
        set(v) = store.setDouble(Key.kinematicCalibration, v)

    /**
     * Deprecated compatibility flag. The V7 detector now has one production
     * flow: IMU-first and GPS-independent, without a relaxed toss-test branch.
     */
    var devMode: Boolean
        get() = if (store.contains(Key.devMode)) store.getBool(Key.devMode, false) else false
        set(v) = store.setBool(Key.devMode, v)

    fun resetToDefaults() {
        minSpeed = 15.0 / 3.6
        takeoffG = 1.5
        landingG = 2.0
        minAirtime = 0.5
        maxAirtime = 8.0
        cooldown = 1.5
        kinematicCalibration = 1.12
        devMode = false
    }

    private fun installStandardCalibrationIfNeeded() {
        if (standardCalibrationVersion == currentStandardCalibrationVersion) return
        standardMinSpeed = 5.0 / 3.6
        standardTakeoffG = 1.7
        standardLandingG = 1.4
        standardMinAirtime = 2.0
        standardMaxAirtime = 6.5
        standardCooldown = 1.0
        standardKinematicCalibration = 1.0
        devMode = false
        standardCalibrationVersion = currentStandardCalibrationVersion
    }

    companion object {
        @Volatile
        var shared: JumpDetectionConfig = JumpDetectionConfig(InMemoryKeyValueStore())
            private set

        /** Called once from the Android Application with a persistent store. */
        fun install(store: KeyValueStore) {
            shared = JumpDetectionConfig(store)
        }
    }
}
