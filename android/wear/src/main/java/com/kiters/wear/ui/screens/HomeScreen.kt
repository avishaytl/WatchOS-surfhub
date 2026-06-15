package com.kiters.wear.ui.screens

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.LifecycleResumeEffect
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavController
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.Text
import com.kiters.wear.R
import com.kiters.wear.model.GpsSignalQuality
import com.kiters.wear.model.Session
import com.kiters.wear.session.SessionManager
import com.kiters.wear.ui.components.ListScaffold
import com.kiters.wear.ui.components.formatDurationShort
import com.kiters.wear.ui.components.gpsSignalColor
import com.kiters.wear.ui.theme.themeColor

@Composable
fun HomeScreen(vm: SessionManager, nav: NavController) {
    val context = LocalContext.current
    val settings = vm.settingsStore
    val accent = themeColor(settings.appTheme)
    var sessions by remember { mutableStateOf(emptyList<Session>()) }
    var showDeniedHint by remember { mutableStateOf(false) }
    val signal by vm.gpsSignalQuality.collectAsStateWithLifecycle()
    val accuracy by vm.lastGpsAccuracy.collectAsStateWithLifecycle()

    androidx.compose.runtime.LaunchedEffect(Unit) {
        sessions = vm.loadAllSessions()
    }

    // Warm up GPS while Home is in the foreground; stop when it leaves so we
    // don't drain the battery in the background. Never affects an active session.
    LifecycleResumeEffect(Unit) {
        vm.prewarmGps()
        onPauseOrDispose { vm.stopGpsPrewarm() }
    }

    ListScaffold { listState ->
        ScalingLazyColumn(modifier = Modifier.fillMaxWidth(), state = listState) {
            // GPS status — live while Home is foregrounded, mirrors the active
            // session indicator so the user can confirm a fix before starting.
            item {
                Row(
                    modifier = Modifier.fillMaxWidth().padding(bottom = 2.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Box(Modifier.size(8.dp).clip(CircleShape).background(gpsSignalColor(signal.rawValue)))
                    Spacer(Modifier.size(6.dp))
                    Text(gpsStatusLabel(context, signal), color = Color.Gray, fontSize = 12.sp)
                    if (accuracy > 0) {
                        Spacer(Modifier.size(6.dp))
                        Text("±${accuracy.toInt()}m", color = Color.Gray, fontSize = 11.sp)
                    }
                }
            }
            item {
                Chip(
                    onClick = {
                        if (vm.isLocationAuthorized) nav.navigate("sport") else showDeniedHint = true
                    },
                    label = {
                        Text(
                            context.getString(R.string.home_start_session),
                            modifier = Modifier.fillMaxWidth(),
                            textAlign = TextAlign.Center,
                            fontWeight = FontWeight.Bold,
                        )
                    },
                    colors = ChipDefaults.primaryChipColors(backgroundColor = accent),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            item {
                Chip(
                    onClick = { nav.navigate("settings") },
                    label = {
                        Text(
                            context.getString(R.string.home_settings),
                            modifier = Modifier.fillMaxWidth(),
                            textAlign = TextAlign.Center,
                        )
                    },
                    colors = ChipDefaults.secondaryChipColors(),
                    modifier = Modifier.fillMaxWidth(),
                )
            }

            if (showDeniedHint) {
                item {
                    Text(
                        context.getString(R.string.permissions_denied_message),
                        color = Color(0xFFFF9800),
                        fontSize = 11.sp,
                        textAlign = TextAlign.Center,
                        modifier = Modifier.padding(horizontal = 8.dp),
                    )
                }
            }

            if (sessions.isNotEmpty()) {
                item {
                    Text(
                        context.getString(R.string.home_recent_sessions),
                        color = Color.Gray,
                        fontSize = 11.sp,
                        modifier = Modifier.padding(top = 6.dp),
                    )
                }
                items(sessions.take(3).size) { i ->
                    val session = sessions[i]
                    SessionRow(session, accent) { nav.navigate("detail/${session.id}") }
                }
            }
        }
    }
}

private fun gpsStatusLabel(context: Context, q: GpsSignalQuality): String = context.getString(
    when (q) {
        GpsSignalQuality.NONE -> R.string.gps_signal_none
        GpsSignalQuality.WEAK -> R.string.gps_signal_weak
        GpsSignalQuality.FAIR -> R.string.gps_signal_fair
        GpsSignalQuality.GOOD -> R.string.gps_signal_good
        GpsSignalQuality.STRONG -> R.string.gps_signal_strong
    },
)

@Composable
private fun SessionRow(session: Session, accent: Color, onClick: () -> Unit) {
    val context = LocalContext.current
    Chip(
        onClick = onClick,
        colors = ChipDefaults.secondaryChipColors(),
        modifier = Modifier.fillMaxWidth(),
        label = {
            Column(modifier = Modifier.fillMaxWidth()) {
                Text(
                    "${session.jumps.size} ${context.getString(R.string.session_jumps).lowercase()}",
                    color = accent,
                    fontWeight = FontWeight.Bold,
                    fontSize = 13.sp,
                )
                Text(
                    formatDurationShort(session.duration),
                    color = Color.Gray,
                    fontSize = 11.sp,
                )
            }
        },
    )
}
