package com.kiters.wear.ui.screens

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.wear.compose.material.Button
import androidx.wear.compose.material.ButtonDefaults
import androidx.wear.compose.material.Scaffold
import androidx.wear.compose.material.Text
import androidx.wear.compose.material.Vignette
import androidx.wear.compose.material.VignettePosition
import com.kiters.wear.R
import com.kiters.wear.engine.JumpDetector
import com.kiters.wear.session.SessionManager
import com.kiters.wear.ui.components.CompactMetric
import com.kiters.wear.ui.components.GpsStatCard
import com.kiters.wear.ui.components.PageDots
import com.kiters.wear.ui.components.formatAirtime
import com.kiters.wear.ui.components.formatDistanceKm
import com.kiters.wear.ui.components.formatDuration
import com.kiters.wear.ui.components.formatHeight
import com.kiters.wear.ui.components.formatSpeed
import com.kiters.wear.ui.components.gpsSignalColor
import com.kiters.wear.ui.theme.themeColor

@Composable
fun ActiveSessionScreen(vm: SessionManager) {
    var showEndConfirm by remember { mutableStateOf(false) }
    val accent = themeColor(vm.settingsStore.appTheme)

    if (showEndConfirm) {
        EndConfirm(
            onCancel = { showEndConfirm = false },
            onEnd = { showEndConfirm = false; vm.endSession() },
        )
        return
    }

    val pagerState = rememberPagerState(initialPage = 1, pageCount = { 4 })
    Scaffold(vignette = { Vignette(vignettePosition = VignettePosition.TopAndBottom) }) {
        Box(Modifier.fillMaxSize()) {
            HorizontalPager(state = pagerState, modifier = Modifier.fillMaxSize()) { page ->
                when (page) {
                    0 -> ControlsPage(vm) { showEndConfirm = true }
                    1 -> MetricsPage(vm)
                    2 -> JumpStatsPage(vm)
                    else -> GpsRoutePage(vm)
                }
            }
            PageDots(
                count = 4,
                selected = pagerState.currentPage,
                accent = accent,
                modifier = Modifier.align(Alignment.BottomCenter).padding(bottom = 3.dp),
            )
        }
    }
}

@Composable
private fun MetricsPage(vm: SessionManager) {
    val context = LocalContext.current
    val accent = themeColor(vm.settingsStore.appTheme)
    val duration by vm.duration.collectAsStateWithLifecycle()
    val signal by vm.gpsSignalQuality.collectAsStateWithLifecycle()
    val pointCount by vm.gpsPointCount.collectAsStateWithLifecycle()
    val jumpState by vm.jumpState.collectAsStateWithLifecycle()
    val session by vm.currentSession.collectAsStateWithLifecycle()
    val hr by vm.heartRate.collectAsStateWithLifecycle()
    val distance by vm.distance.collectAsStateWithLifecycle()
    val maxSpeed by vm.maxSpeed.collectAsStateWithLifecycle()
    val jumpCount by vm.jumpCount.collectAsStateWithLifecycle()

    val jumps = session?.jumps ?: emptyList()
    val lastHeight = jumps.lastOrNull()?.height ?: 0.0
    val maxHeight = jumps.maxByOrNull { it.height }?.height ?: 0.0
    val maxAir = jumps.maxByOrNull { it.airtime }?.airtime ?: 0.0

    Column(modifier = Modifier.fillMaxSize()) {
        // Top status row — centered to clear the round bezel.
        Row(
            modifier = Modifier.fillMaxWidth().padding(top = 22.dp),
            horizontalArrangement = Arrangement.Center,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                formatDuration(duration),
                color = Color.White,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                fontFamily = FontFamily.Monospace,
            )
            Spacer(Modifier.size(6.dp))
            Box(Modifier.size(8.dp).clip(CircleShape).background(gpsSignalColor(signal.rawValue)))
            if (pointCount > 0) {
                Text(" $pointCount", color = gpsSignalColor(signal.rawValue), fontSize = 10.sp)
            }
            Spacer(Modifier.size(6.dp))
            Box(Modifier.size(6.dp).clip(CircleShape).background(jumpStateColor(jumpState)))
        }

        Row(
            modifier = Modifier.fillMaxWidth().padding(horizontal = 14.dp, vertical = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            CompactMetric(formatHeight(lastHeight), context.getString(R.string.session_last),
                if (jumpCount > 0) accent else Color.White, Modifier.weight(1f))
            CompactMetric(if (hr > 0) "${hr.toInt()}" else "--", context.getString(R.string.session_bpm),
                if (hr > 0) Color.Red else Color.White, Modifier.weight(1f))
            CompactMetric(formatHeight(maxHeight), context.getString(R.string.session_max),
                Color.White, Modifier.weight(1f))
        }

        // Big last-jump height
        Box(
            modifier = Modifier.fillMaxWidth().weight(1f).padding(horizontal = 8.dp, vertical = 4.dp)
                .clip(RoundedCornerShape(12.dp)).background(Color.Black),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                formatHeight(lastHeight),
                color = accent,
                fontSize = 46.sp,
                fontWeight = FontWeight.Bold,
                fontFamily = FontFamily.SansSerif,
            )
        }

        Row(
            modifier = Modifier.fillMaxWidth().padding(start = 20.dp, end = 20.dp, bottom = 24.dp),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            CompactMetric(formatDistanceKm(distance), context.getString(R.string.session_distance),
                Color.White, Modifier.weight(1f))
            CompactMetric(formatAirtime(maxAir), context.getString(R.string.session_airtime),
                Color.White, Modifier.weight(1f))
            CompactMetric(formatSpeed(maxSpeed), context.getString(R.string.session_speed),
                Color.White, Modifier.weight(1f))
        }
    }
}

@Composable
private fun ControlsPage(vm: SessionManager, onEndTap: () -> Unit) {
    val context = LocalContext.current
    val isPaused by vm.isPaused.collectAsStateWithLifecycle()
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Button(
            onClick = { if (isPaused) vm.resumeSession() else vm.pauseSession() },
            colors = ButtonDefaults.buttonColors(
                backgroundColor = if (isPaused) Color(0xFF4CAF50) else Color(0xFFFF9800),
            ),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(
                context.getString(if (isPaused) R.string.session_resume else R.string.session_pause),
                color = Color.White,
            )
        }
        Button(
            onClick = onEndTap,
            colors = ButtonDefaults.buttonColors(backgroundColor = Color.Red),
            modifier = Modifier.fillMaxWidth(),
        ) {
            Text(context.getString(R.string.session_end), color = Color.White)
        }
    }
}

@Composable
private fun JumpStatsPage(vm: SessionManager) {
    val context = LocalContext.current
    val session by vm.currentSession.collectAsStateWithLifecycle()
    val jumpCount by vm.jumpCount.collectAsStateWithLifecycle()
    val best = session?.jumps?.maxByOrNull { it.height }

    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        if (jumpCount > 0 && best != null) {
            Text(context.getString(R.string.session_best_jump), color = Color.Yellow, fontSize = 12.sp)
            Text("%.2f m".format(best.height), fontSize = 32.sp, fontWeight = FontWeight.Bold, color = Color.White)
            Text(context.getString(R.string.session_airtime_value).format(best.airtime),
                color = Color.Gray, fontSize = 12.sp)
            if (best.rotations > 0) {
                val key = if (best.rotations == 1) R.string.session_rotation_single else R.string.session_rotation_plural
                Text(context.getString(key).format(best.rotations), color = Color(0xFF2196F3), fontSize = 12.sp)
            }
            Spacer(Modifier.height(6.dp))
            Text(context.getString(R.string.session_total_jumps).format(jumpCount),
                color = Color.Gray, fontSize = 11.sp)
        } else {
            Text(context.getString(R.string.session_no_jumps), color = Color.Gray, fontSize = 13.sp,
                textAlign = TextAlign.Center)
            Text(context.getString(R.string.session_get_air), color = Color.Gray, fontSize = 11.sp,
                textAlign = TextAlign.Center)
        }
    }
}

@Composable
private fun GpsRoutePage(vm: SessionManager) {
    val context = LocalContext.current
    val signal by vm.gpsSignalQuality.collectAsStateWithLifecycle()
    val distance by vm.distance.collectAsStateWithLifecycle()
    val currentSpeed by vm.currentSpeed.collectAsStateWithLifecycle()
    val maxSpeed by vm.maxSpeed.collectAsStateWithLifecycle()
    val pointCount by vm.gpsPointCount.collectAsStateWithLifecycle()
    val accuracy by vm.lastGpsAccuracy.collectAsStateWithLifecycle()
    val session by vm.currentSession.collectAsStateWithLifecycle()

    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.Center,
    ) {
        Row(modifier = Modifier.fillMaxWidth().padding(vertical = 4.dp),
            horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.size(8.dp).clip(CircleShape).background(gpsSignalColor(signal.rawValue)))
            Spacer(Modifier.size(6.dp))
            Text(context.getString(R.string.gps_tracking), color = Color.White,
                fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
        }
        val km = context.getString(R.string.units_kilometers)
        val kmh = context.getString(R.string.units_kmh)
        Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            GpsStatCard(context.getString(R.string.gps_route_distance), formatDistanceKm(distance), km, Modifier.weight(1f))
            GpsStatCard(context.getString(R.string.gps_current_speed), formatSpeed(currentSpeed), kmh, Modifier.weight(1f))
        }
        Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            GpsStatCard(context.getString(R.string.gps_points), "$pointCount", context.getString(R.string.gps_pts), Modifier.weight(1f))
            GpsStatCard(context.getString(R.string.gps_accuracy), if (accuracy > 0) "%.0f".format(accuracy) else "--",
                context.getString(R.string.units_meters), Modifier.weight(1f))
        }
        Row(Modifier.fillMaxWidth().padding(vertical = 2.dp), horizontalArrangement = Arrangement.spacedBy(6.dp)) {
            GpsStatCard(context.getString(R.string.gps_max_speed), formatSpeed(maxSpeed), kmh, Modifier.weight(1f))
            GpsStatCard(context.getString(R.string.gps_avg_speed), formatSpeed(session?.avgSpeed ?: 0.0), kmh, Modifier.weight(1f))
        }
    }
}

@Composable
private fun EndConfirm(onCancel: () -> Unit, onEnd: () -> Unit) {
    val context = LocalContext.current
    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp, Alignment.CenterVertically),
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(context.getString(R.string.session_end_confirm), fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center, color = Color.White)
        Button(onClick = onEnd, colors = ButtonDefaults.buttonColors(backgroundColor = Color.Red),
            modifier = Modifier.fillMaxWidth()) {
            Text(context.getString(R.string.session_end), color = Color.White)
        }
        Button(onClick = onCancel, colors = ButtonDefaults.secondaryButtonColors(),
            modifier = Modifier.fillMaxWidth()) {
            Text(context.getString(R.string.session_cancel))
        }
    }
}

private fun jumpStateColor(state: JumpDetector.JumpState): Color = when (state) {
    JumpDetector.JumpState.IDLE -> Color.Gray
    JumpDetector.JumpState.RIDING -> Color(0xFF4CAF50)
    JumpDetector.JumpState.AIRBORNE -> Color(0xFF00BCD4)
    JumpDetector.JumpState.COOLDOWN -> Color.Gray
}
