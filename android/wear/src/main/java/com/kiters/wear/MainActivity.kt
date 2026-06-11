package com.kiters.wear

import android.Manifest
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
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

            // Keep the screen on while a session is active.
            // FLAG_KEEP_SCREEN_ON is the correct Wear OS mechanism: it prevents the
            // display from turning off so the rider can glance at metrics without
            // touching the watch. The flag is cleared the moment the session ends.
            val isRecording by vm.isRecording.collectAsStateWithLifecycle()
            LaunchedEffect(isRecording) {
                if (isRecording) {
                    window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                } else {
                    window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                }
            }

            KitersApp(vm)
        }
    }

    override fun onResume() {
        super.onResume()
        sessionManager?.refreshLocationAuth()
        // Re-apply the flag in case the activity was recreated mid-session.
        sessionManager?.let { vm ->
            if (vm.isRecording.value) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
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
