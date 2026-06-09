package com.kiters.wear.ui.screens

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.navigation.NavController
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.Text
import com.kiters.wear.R
import com.kiters.wear.model.Session
import com.kiters.wear.session.SessionManager
import com.kiters.wear.ui.components.ListScaffold
import com.kiters.wear.ui.components.formatDurationShort
import com.kiters.wear.ui.theme.themeColor

@Composable
fun HomeScreen(vm: SessionManager, nav: NavController) {
    val context = LocalContext.current
    val settings = vm.settingsStore
    val accent = themeColor(settings.appTheme)
    var sessions by remember { mutableStateOf(emptyList<Session>()) }
    var showDeniedHint by remember { mutableStateOf(false) }

    androidx.compose.runtime.LaunchedEffect(Unit) {
        sessions = vm.loadAllSessions()
    }

    ListScaffold { listState ->
        ScalingLazyColumn(modifier = Modifier.fillMaxWidth(), state = listState) {
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
