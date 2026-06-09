package com.kiters.wear

import android.app.Application
import com.kiters.wear.model.JumpDetectionConfig
import com.kiters.wear.storage.SessionLogger
import com.kiters.wear.storage.SettingsStore

class KitersApp : Application() {
    override fun onCreate() {
        super.onCreate()
        // Persist jump-detection params + devMode to SharedPreferences, like
        // the watchOS app's UserDefaults-backed JumpDetectionConfig.
        JumpDetectionConfig.install(SettingsStore(this))
        SessionLogger.shared.init(this)
    }
}
