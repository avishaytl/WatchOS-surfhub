package com.kiters.wear.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.material.Text
import com.kiters.wear.R
import com.kiters.wear.model.Jump
import com.kiters.wear.model.Session
import com.kiters.wear.session.SessionManager
import com.kiters.wear.ui.components.ListScaffold
import com.kiters.wear.ui.components.StatRow
import com.kiters.wear.ui.components.formatDistanceKm
import com.kiters.wear.ui.components.formatDurationShort
import com.kiters.wear.ui.components.formatSpeed

@Composable
fun SessionDetailScreen(id: String, vm: SessionManager) {
    val context = LocalContext.current
    var session by remember { mutableStateOf<Session?>(null) }
    androidx.compose.runtime.LaunchedEffect(id) { session = vm.loadSession(id) }

    val s = session ?: return
    ListScaffold { listState ->
    ScalingLazyColumn(modifier = Modifier.fillMaxWidth(), state = listState) {
        item {
            Text(context.getString(R.string.detail_session_complete),
                fontWeight = FontWeight.Bold, fontSize = 15.sp)
        }
        item { StatRow(context.getString(R.string.detail_duration), formatDurationShort(s.duration)) }
        item { StatRow(context.getString(R.string.detail_total_distance), "${formatDistanceKm(s.distance)} km") }
        item { StatRow(context.getString(R.string.detail_max_speed), "${formatSpeed(s.maxSpeed)} km/h") }
        item { StatRow(context.getString(R.string.detail_avg_speed), "${formatSpeed(s.avgSpeed)} km/h") }
        item { StatRow(context.getString(R.string.detail_total_jumps), "${s.jumps.size}") }

        if (s.gpsPoints.isNotEmpty()) {
            item { StatRow(context.getString(R.string.detail_gps_points), "${s.gpsPoints.size}") }
        }

        if (s.jumps.isNotEmpty()) {
            item {
                Text(context.getString(R.string.session_jumps), fontWeight = FontWeight.Bold,
                    fontSize = 14.sp, modifier = Modifier.padding(top = 6.dp))
            }
            items(s.jumps.size) { i -> JumpCard(s.jumps[i]) }
        }
    }
    }
}

@Composable
private fun JumpCard(jump: Jump) {
    Column(
        modifier = Modifier.fillMaxWidth().padding(vertical = 3.dp)
            .clip(RoundedCornerShape(8.dp)).background(Color(0xFF2A2A2A)).padding(8.dp),
    ) {
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("%.2f m".format(jump.height), color = Color.White, fontWeight = FontWeight.Bold, fontSize = 14.sp)
            if (jump.rotations > 0) Text("🔄 ${jump.rotations}", color = Color(0xFF2196F3), fontSize = 11.sp)
        }
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            Text("%.2f sec".format(jump.airtime), color = Color.Gray, fontSize = 11.sp)
            Row {
                repeat(5) { i ->
                    val filled = i < (jump.confidence / 20).toInt()
                    Text("●", color = if (filled) Color(0xFF4CAF50) else Color.Gray.copy(alpha = 0.3f), fontSize = 8.sp)
                }
            }
        }
    }
}
