package com.kiters.wear.ui.screens

import android.app.Activity
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.navigation.NavController
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.Text
import com.kiters.wear.R
import com.kiters.wear.session.SessionManager
import com.kiters.wear.ui.components.ListScaffold
import com.kiters.wear.ui.theme.themeColor

@Composable
fun SettingsScreen(vm: SessionManager, nav: NavController) {
    val context = LocalContext.current
    val activity = context as? Activity
    val settings = vm.settingsStore
    @Suppress("UNUSED_VARIABLE")
    val rev by settings.revision.collectAsStateWithLifecycle()   // forces recompose on change
    val accent = themeColor(settings.appTheme)

    // ChipDefaults.*ChipColors() are @Composable, so resolve them once here.
    val primarySel = ChipDefaults.primaryChipColors(backgroundColor = accent)
    val secondary = ChipDefaults.secondaryChipColors()
    fun selColors(selected: Boolean) = if (selected) primarySel else secondary

    ListScaffold { listState ->
    ScalingLazyColumn(
        modifier = Modifier.fillMaxWidth(),
        state = listState,
    ) {
        item { SectionTitle(context.getString(R.string.settings_title), big = true) }

        // Account
        item { SectionTitle(context.getString(R.string.account_section_title)) }
        item {
            val accountLabel = settings.authEmail.ifBlank {
                if (settings.authAccessToken.isNotBlank()) context.getString(R.string.account_connected_title) else ""
            }
            ChipRow(
                if (accountLabel.isNotBlank()) accountLabel else context.getString(R.string.account_sign_in),
                ChipDefaults.secondaryChipColors(),
            ) { nav.navigate("account") }
        }

        // Theme
        item { SectionTitle(context.getString(R.string.settings_app_theme)) }
        val themes = listOf(
            "blue" to R.string.settings_theme_blue,
            "cyan" to R.string.settings_theme_cyan,
            "green" to R.string.settings_theme_green,
            "yellow" to R.string.settings_theme_yellow,
            "orange" to R.string.settings_theme_orange,
            "red" to R.string.settings_theme_red,
            "pink" to R.string.settings_theme_pink,
        )
        items(themes.size) { i ->
            val (key, label) = themes[i]
            ChipRow(context.getString(label), selColors(settings.appTheme == key)) { settings.appTheme = key }
        }

        // Language
        item { SectionTitle(context.getString(R.string.settings_language)) }
        item {
            ChipRow(context.getString(R.string.settings_language_english), selColors(settings.appLanguage == "en")) {
                settings.appLanguage = "en"; activity?.recreate()
            }
        }
        item {
            ChipRow(context.getString(R.string.settings_language_hebrew), selColors(settings.appLanguage == "he")) {
                settings.appLanguage = "he"; activity?.recreate()
            }
        }

        // Units
        item { SectionTitle(context.getString(R.string.settings_units)) }
        item { ChipRow(context.getString(R.string.settings_units_metric), selColors(settings.units == "metric")) { settings.units = "metric" } }
        item { ChipRow(context.getString(R.string.settings_units_imperial), selColors(settings.units == "imperial")) { settings.units = "imperial" } }

        // Display & feedback
        item { SectionTitle(context.getString(R.string.settings_display_feedback)) }
        item {
            val tp = settings.metricsTopPadding
            Row(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                ChipRow(context.getString(R.string.settings_top_padding_auto), selColors(tp < 0), Modifier.weight(1f)) {
                    settings.metricsTopPadding = -1.0
                }
                ChipRow("-", ChipDefaults.secondaryChipColors(), Modifier.weight(1f)) {
                    settings.metricsTopPadding = maxOf(0.0, (if (tp < 0) 0.0 else tp) - 1)
                }
                ChipRow("+", ChipDefaults.secondaryChipColors(), Modifier.weight(1f)) {
                    settings.metricsTopPadding = minOf(40.0, (if (tp < 0) 0.0 else tp) + 1)
                }
            }
        }
        item {
            val v = settings.autoLock
            ChipRow("${context.getString(R.string.settings_screen_lock)}: ${onOff(v, context)}", selColors(v)) {
                settings.autoLock = !v
            }
        }
        item {
            val v = settings.hapticFeedback
            ChipRow("${context.getString(R.string.settings_haptic_feedback)}: ${onOff(v, context)}", selColors(v)) {
                settings.hapticFeedback = !v
            }
        }
        // Data
        item { SectionTitle(context.getString(R.string.settings_data)) }
        item { ChipRow(context.getString(R.string.settings_manage_sessions), ChipDefaults.secondaryChipColors()) { nav.navigate("data") } }
        item { ChipRow(context.getString(R.string.settings_session_logs), ChipDefaults.secondaryChipColors()) { nav.navigate("logs") } }

        // About
        item { SectionTitle(context.getString(R.string.settings_about)) }
        item {
            Text(
                "${context.getString(R.string.settings_version)} 1.0.0",
                color = Color.Gray, fontSize = 11.sp,
                modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center,
            )
        }
    }
    }
}

private fun onOff(v: Boolean, context: android.content.Context): String =
    if (v) "ON" else "OFF"

@Composable
private fun SectionTitle(text: String, big: Boolean = false) {
    Text(
        text,
        color = if (big) Color.White else Color.Gray,
        fontSize = if (big) 18.sp else 11.sp,
        fontWeight = if (big) FontWeight.Bold else FontWeight.Normal,
        modifier = Modifier.fillMaxWidth().padding(top = 6.dp),
        textAlign = TextAlign.Center,
    )
}

@Composable
private fun ChipRow(
    label: String,
    colors: androidx.wear.compose.material.ChipColors,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Chip(
        onClick = onClick,
        colors = colors,
        modifier = modifier.fillMaxWidth(),
        label = { Text(label, modifier = Modifier.fillMaxWidth(), textAlign = TextAlign.Center, fontSize = 13.sp) },
    )
}
