package com.spoteq.wear.ui

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.wear.compose.material.Button
import androidx.wear.compose.material.ButtonDefaults
import androidx.wear.compose.material.MaterialTheme
import androidx.wear.compose.material.Text
import androidx.wear.compose.navigation.SwipeDismissableNavHost
import androidx.wear.compose.navigation.composable
import androidx.wear.compose.navigation.rememberSwipeDismissableNavController
import com.spoteq.wear.R
import com.spoteq.wear.session.SessionManager
import com.spoteq.wear.ui.screens.AccountScreen
import com.spoteq.wear.ui.screens.ActiveSessionScreen
import com.spoteq.wear.ui.screens.DataManagementScreen
import com.spoteq.wear.ui.screens.HomeScreen
import com.spoteq.wear.ui.screens.SessionDetailScreen
import com.spoteq.wear.ui.screens.SessionLogsScreen
import com.spoteq.wear.ui.screens.SettingsScreen
import com.spoteq.wear.ui.screens.SportSelectionScreen

@Composable
fun SPOTEQApp(vm: SessionManager) {
    MaterialTheme {
        val isRecording by vm.isRecording.collectAsStateWithLifecycle()
        val pendingCloudUpload by vm.pendingCloudUpload.collectAsStateWithLifecycle()
        val sessionNotice by vm.sessionNotice.collectAsStateWithLifecycle()
        val revision by vm.settingsStore.revision.collectAsStateWithLifecycle()
        // Re-evaluate on every settings change so sign-in/out instantly updates routing.
        val isSignedIn = revision.let {
            vm.settingsStore.authAccessToken.isNotBlank() && vm.settingsStore.authUserId.isNotBlank()
        }

        when {
            isRecording -> ActiveSessionScreen(vm)
            pendingCloudUpload != null -> CloudUploadPrompt(vm)
            sessionNotice != null -> SessionNoticePrompt(vm, sessionNotice!!)
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

@Composable
private fun SessionNoticePrompt(vm: SessionManager, notice: com.spoteq.wear.session.SessionUserNotice) {
    val context = LocalContext.current
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = context.getString(notice.titleRes),
            color = Color.White,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center,
        )
        Text(
            text = if (notice.messageArg != null) {
                context.getString(notice.messageRes, notice.messageArg)
            } else {
                context.getString(notice.messageRes)
            },
            color = Color.Gray,
            fontSize = 11.sp,
            textAlign = TextAlign.Center,
        )
        Button(
            onClick = { vm.dismissSessionNotice() },
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(context.getString(R.string.common_ok), color = Color.White)
        }
    }
}

@Composable
private fun CloudUploadPrompt(vm: SessionManager) {
    val context = LocalContext.current
    val canUpload by vm.canUploadPendingSession.collectAsStateWithLifecycle()
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            text = context.getString(R.string.session_upload_prompt_title),
            color = Color.White,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center,
        )
        Text(
            text = context.getString(
                if (canUpload) R.string.session_upload_prompt_message
                else R.string.session_upload_offline_message,
            ),
            color = Color.Gray,
            fontSize = 11.sp,
            textAlign = TextAlign.Center,
        )
        if (canUpload) {
            Button(
                onClick = { vm.uploadPendingSessionToCloud() },
                modifier = Modifier.fillMaxWidth(),
            ) {
                Text(context.getString(R.string.session_upload_now), color = Color.White)
            }
        }
        Button(
            onClick = { vm.keepPendingSessionLocal() },
            colors = ButtonDefaults.secondaryButtonColors(),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(context.getString(R.string.session_keep_local))
        }
        Button(
            onClick = { vm.discardPendingSession() },
            colors = ButtonDefaults.buttonColors(backgroundColor = Color.Red),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(context.getString(R.string.session_discard), color = Color.White)
        }
    }
}
