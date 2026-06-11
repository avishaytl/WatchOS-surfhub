package com.kiters.wear.storage

import android.content.Context
import android.content.SharedPreferences
import com.kiters.wear.model.DetectionMode
import com.kiters.wear.model.KeyValueStore
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow

/**
 * SharedPreferences-backed settings, mirroring the watchOS @AppStorage /
 * UserDefaults model (synchronous reads, exactly like the Swift app). Also
 * implements [KeyValueStore] so JumpDetectionConfig persists to the same store.
 *
 * For reactive Compose reads, observe [revision] and re-read the getters.
 */
class SettingsStore(context: Context) : KeyValueStore {

    private val prefs: SharedPreferences =
        context.applicationContext.getSharedPreferences("kiters_settings", Context.MODE_PRIVATE)

    /** Bumped on every change so Compose can recompose off a single signal. */
    val revision: StateFlow<Int> get() = _revision
    private val _revision = MutableStateFlow(0)

    private val listener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ ->
        _revision.value = _revision.value + 1
    }

    init {
        prefs.registerOnSharedPreferenceChangeListener(listener)
    }

    // MARK: - @AppStorage-equivalent keys

    var units: String
        get() = prefs.getString("units", "metric") ?: "metric"
        set(v) { prefs.edit().putString("units", v).apply() }

    var appTheme: String
        get() = prefs.getString("appTheme", "blue") ?: "blue"
        set(v) { prefs.edit().putString("appTheme", v).apply() }

    var appLanguage: String
        get() = prefs.getString("appLanguage", "en") ?: "en"
        set(v) { prefs.edit().putString("appLanguage", v).apply() }

    var detectionModeRaw: String
        get() = prefs.getString("detectionMode", DetectionMode.STANDARD.rawValue)
            ?: DetectionMode.STANDARD.rawValue
        set(v) { prefs.edit().putString("detectionMode", v).apply() }

    val detectionMode: DetectionMode get() = DetectionMode.fromRaw(detectionModeRaw)

    var autoLock: Boolean
        get() = if (prefs.contains("autoLock")) prefs.getBoolean("autoLock", true) else true
        set(v) { prefs.edit().putBoolean("autoLock", v).apply() }

    var hapticFeedback: Boolean
        get() = if (prefs.contains("hapticFeedback")) prefs.getBoolean("hapticFeedback", true) else true
        set(v) { prefs.edit().putBoolean("hapticFeedback", v).apply() }

    var voiceAnnouncements: Boolean
        get() = prefs.getBoolean("voiceAnnouncements", false)
        set(v) { prefs.edit().putBoolean("voiceAnnouncements", v).apply() }

    // MARK: - Auth

    var authAccessToken: String
        get() = prefs.getString("authAccessToken", "") ?: ""
        set(v) { prefs.edit().putString("authAccessToken", v).apply() }

    var authRefreshToken: String
        get() = prefs.getString("authRefreshToken", "") ?: ""
        set(v) { prefs.edit().putString("authRefreshToken", v).apply() }

    var authEmail: String
        get() = prefs.getString("authEmail", "") ?: ""
        set(v) { prefs.edit().putString("authEmail", v).apply() }

    var authUserId: String
        get() = prefs.getString("authUserId", "") ?: ""
        set(v) { prefs.edit().putString("authUserId", v).apply() }

    var authExpiresAt: Long
        get() = prefs.getLong("authExpiresAt", 0L)
        set(v) { prefs.edit().putLong("authExpiresAt", v).apply() }

    /** -1 = auto. Stored as Double to match the watchOS metricsTopPadding. */
    var metricsTopPadding: Double
        get() = if (prefs.contains("metricsTopPadding"))
            Double.fromBits(prefs.getLong("metricsTopPadding", (-1.0).toRawBits())) else -1.0
        set(v) { prefs.edit().putLong("metricsTopPadding", v.toRawBits()).apply() }

    // MARK: - KeyValueStore (for JumpDetectionConfig)

    override fun getDouble(key: String, default: Double): Double =
        if (prefs.contains(key)) Double.fromBits(prefs.getLong(key, default.toRawBits())) else default

    override fun setDouble(key: String, value: Double) {
        prefs.edit().putLong(key, value.toRawBits()).apply()
    }

    override fun getBool(key: String, default: Boolean): Boolean = prefs.getBoolean(key, default)
    override fun setBool(key: String, value: Boolean) { prefs.edit().putBoolean(key, value).apply() }
    override fun getString(key: String): String? = prefs.getString(key, null)
    override fun setString(key: String, value: String?) { prefs.edit().putString(key, value).apply() }
    override fun contains(key: String): Boolean = prefs.contains(key)
}
