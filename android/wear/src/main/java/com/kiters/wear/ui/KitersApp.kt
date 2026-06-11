package com.kiters.wear.ui

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.navigation.SwipeDismissableNavHost
import androidx.wear.compose.navigation.composable
import androidx.wear.compose.navigation.rememberSwipeDismissableNavController
import com.kiters.wear.session.SessionManager
import com.kiters.wear.ui.screens.AccountScreen
import com.kiters.wear.ui.screens.ActiveSessionScreen
import com.kiters.wear.ui.screens.DataManagementScreen
import com.kiters.wear.ui.screens.HomeScreen
import com.kiters.wear.ui.screens.SessionDetailScreen
import com.kiters.wear.ui.screens.SessionLogsScreen
import com.kiters.wear.ui.screens.SettingsScreen
import com.kiters.wear.ui.screens.SportSelectionScreen

@Composable
fun KitersApp(vm: SessionManager) {
    MaterialTheme {
        val isRecording by vm.isRecording.collectAsStateWithLifecycle()
        val revision by vm.settingsStore.revision.collectAsStateWithLifecycle()
        // Re-evaluate on every settings change so sign-in/out instantly updates routing.
        val isSignedIn = revision.let { vm.settingsStore.authEmail.isNotBlank() }

        when {
            isRecording -> ActiveSessionScreen(vm)
            !isSignedIn -> {
                val nav = rememberSwipeDismissableNavController()
                AccountScreen(vm, nav)
            }
            else -> {
                val nav = rememberSwipeDismissableNavController()
                SwipeDismissableNavHost(navController = nav, startDestination = "home") {
                    composable("home") { HomeScreen(vm, nav) }
                    composable("sport") { SportSelectionScreen(vm, nav) }
                    composable("settings") { SettingsScreen(vm, nav) }
                    composable("account") { AccountScreen(vm, nav) }
                    composable("data") { DataManagementScreen(vm) }
                    composable("logs") { SessionLogsScreen() }
                    composable("detail/{id}") { entry ->
                        val id = entry.arguments?.getString("id").orEmpty()
                        SessionDetailScreen(id, vm)
                    }
                }
            }
        }
    }
}
