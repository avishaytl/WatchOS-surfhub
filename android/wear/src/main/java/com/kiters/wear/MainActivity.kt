package com.kiters.wear

import android.Manifest
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.lifecycle.viewmodel.compose.viewModel
import com.kiters.wear.session.SessionManager
import com.kiters.wear.storage.SettingsStore
import com.kiters.wear.ui.KitersApp
import java.util.Locale

class MainActivity : ComponentActivity() {

    private var sessionManager: SessionManager? = null

    private val permissionLauncher =
        registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { result ->
            val granted = result[Manifest.permission.ACCESS_FINE_LOCATION] == true
            sessionManager?.onPermissionResult(granted)
        }

    override fun attachBaseContext(newBase: Context) {
        // Apply the user-selected language (en / he), mirroring the watchOS
        // per-app localization. RTL follows automatically for Hebrew.
        val lang = SettingsStore(newBase).appLanguage
        val locale = Locale(lang)
        Locale.setDefault(locale)
        val config = Configuration(newBase.resources.configuration)
        config.setLocale(locale)
        config.setLayoutDirection(locale)
        super.attachBaseContext(newBase.createConfigurationContext(config))
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestPermissionsIfNeeded()
        setContent {
            val vm: SessionManager = viewModel()
            sessionManager = vm
            KitersApp(vm)
        }
    }

    override fun onResume() {
        super.onResume()
        sessionManager?.refreshLocationAuth()
    }

    private fun requestPermissionsIfNeeded() {
        val perms = mutableListOf(
            Manifest.permission.ACCESS_FINE_LOCATION,
            Manifest.permission.BODY_SENSORS,
        )
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            perms.add(Manifest.permission.POST_NOTIFICATIONS)
        }
        permissionLauncher.launch(perms.toTypedArray())
    }
}
