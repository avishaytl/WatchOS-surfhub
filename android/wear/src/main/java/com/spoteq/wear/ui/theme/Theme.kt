package com.spoteq.wear.ui.theme

import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import com.spoteq.wear.storage.SettingsStore

/** Maps the stored appTheme key to an accent Color (same palette as watchOS). */
fun themeColor(name: String): Color = when (name) {
    "yellow" -> Color(0xFFFFEB3B)
    "green" -> Color(0xFF4CAF50)
    "red" -> Color(0xFFF44336)
    "orange" -> Color(0xFFFF9800)
    "cyan" -> Color(0xFF00BCD4)
    "pink" -> Color(0xFFE91E63)
    else -> Color(0xFFFF9800) // orange
}

@Composable
fun rememberSettings(): SettingsStore {
    val context = LocalContext.current
    return remember { SettingsStore(context.applicationContext) }
}
