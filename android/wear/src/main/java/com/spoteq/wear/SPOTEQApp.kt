package com.spoteq.wear

import android.app.Application
import com.spoteq.wear.model.JumpDetectionConfig
import com.spoteq.wear.storage.SessionLogger
import com.spoteq.wear.storage.SettingsStore

class SPOTEQApp : Application() {
    override fun onCreate() {
        super.onCreate()
        // Persist jump-detection params + devMode to SharedPreferences, like
        // the watchOS app's UserDefaults-backed JumpDetectionConfig.
        JumpDetectionConfig.install(SettingsStore(this))
        SessionLogger.shared.init(this)
    }
}
