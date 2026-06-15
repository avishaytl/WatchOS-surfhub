package com.kiters.wear.ui.screens

import android.content.Intent
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
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.Text
import com.kiters.wear.R
import com.kiters.wear.model.Session
import com.kiters.wear.session.SessionManager
import com.kiters.wear.ui.components.ListScaffold
import com.kiters.wear.storage.SessionLogger
import java.io.File

@Composable
fun DataManagementScreen(vm: SessionManager) {
    val context = LocalContext.current
    var sessions by remember { mutableStateOf(emptyList<Session>()) }
    var confirm by remember { mutableStateOf(false) }

    androidx.compose.runtime.LaunchedEffect(Unit) { sessions = vm.loadAllSessions() }

    ListScaffold { listState ->
    ScalingLazyColumn(modifier = Modifier.fillMaxWidth(), state = listState) {
        item { Text(context.getString(R.string.data_title), fontWeight = FontWeight.Bold) }
        item {
            Column(Modifier.fillMaxWidth().padding(8.dp)) {
                Text(context.getString(R.string.data_sessions_count).format(sessions.size),
                    color = Color.White, fontSize = 12.sp)
                Text(context.getString(R.string.data_total_jumps).format(sessions.sumOf { it.jumps.size }),
                    color = Color.White, fontSize = 12.sp)
            }
        }
        if (!confirm) {
            item {
                Chip(
                    onClick = { confirm = true },
                    colors = ChipDefaults.primaryChipColors(backgroundColor = Color.Red),
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(context.getString(R.string.data_delete_all), modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center) },
                )
            }
        } else {
            item {
                Text(context.getString(R.string.data_delete_message), color = Color.Gray, fontSize = 10.sp,
                    textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 8.dp))
            }
            item {
                Chip(onClick = { vm.clearAllSessionsPublic(); sessions = emptyList(); confirm = false },
                    colors = ChipDefaults.primaryChipColors(backgroundColor = Color.Red),
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(context.getString(R.string.data_delete), modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center) })
            }
            item {
                Chip(onClick = { confirm = false }, colors = ChipDefaults.secondaryChipColors(),
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(context.getString(R.string.common_cancel), modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center) })
            }
        }
    }
    }
}

@Composable
fun SessionLogsScreen() {
    val context = LocalContext.current
    var logs by remember { mutableStateOf(emptyList<File>()) }
    androidx.compose.runtime.LaunchedEffect(Unit) { logs = SessionLogger.shared.allLogFiles() }

    ListScaffold { listState ->
    ScalingLazyColumn(modifier = Modifier.fillMaxWidth(), state = listState) {
        item { Text(context.getString(R.string.logs_title), fontWeight = FontWeight.Bold) }
        if (logs.isEmpty()) {
            item {
                Text(context.getString(R.string.logs_empty), color = Color.Gray, fontSize = 12.sp,
                    modifier = Modifier.fillMaxWidth().padding(top = 12.dp), textAlign = TextAlign.Center)
            }
            item {
                Text(context.getString(R.string.logs_empty_hint), color = Color.Gray.copy(alpha = 0.7f),
                    fontSize = 10.sp, textAlign = TextAlign.Center, modifier = Modifier.padding(horizontal = 8.dp))
            }
        } else {
            items(logs.size) { i ->
                val file = logs[i]
                Chip(
                    onClick = { shareLog(context, file) },
                    colors = ChipDefaults.secondaryChipColors(),
                    modifier = Modifier.fillMaxWidth(),
                    label = {
                        Column(Modifier.fillMaxWidth()) {
                            Text(file.name.removePrefix("log_").substringBeforeLast('.'), fontSize = 12.sp, color = Color.White)
                            Text("${file.length() / 1024} KB · ${context.getString(R.string.logs_share)}",
                                fontSize = 9.sp, color = Color.Gray)
                        }
                    },
                )
            }
            item {
                Chip(
                    onClick = { SessionLogger.shared.clearAllLogs(); logs = emptyList() },
                    colors = ChipDefaults.primaryChipColors(backgroundColor = Color.Red.copy(alpha = 0.6f)),
                    modifier = Modifier.fillMaxWidth(),
                    label = { Text(context.getString(R.string.logs_delete_all), modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center) },
                )
            }
        }
    }
    }
}

/** Share a decoded log preview via the Android share sheet (text/plain, watch-sized). */
private fun shareLog(context: android.content.Context, file: File) {
    val content = try { SessionLogger.shared.buildShareText(file) } catch (e: Exception) { return }
    val intent = Intent(Intent.ACTION_SEND).apply {
        type = "text/plain"
        putExtra(Intent.EXTRA_SUBJECT, "Kiters Log — ${file.name}")
        putExtra(Intent.EXTRA_TEXT, content)
    }
    context.startActivity(Intent.createChooser(intent, null).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) })
}
