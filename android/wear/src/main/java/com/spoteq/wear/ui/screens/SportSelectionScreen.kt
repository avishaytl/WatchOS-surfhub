package com.spoteq.wear.ui.screens

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.navigation.NavController
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.material.Chip
import androidx.wear.compose.material.ChipDefaults
import androidx.wear.compose.material.Text
import com.spoteq.wear.R
import com.spoteq.wear.model.Sport
import com.spoteq.wear.session.SessionManager
import com.spoteq.wear.ui.components.ListScaffold

@Composable
fun SportSelectionScreen(vm: SessionManager, nav: NavController) {
    val context = LocalContext.current
    ListScaffold { listState ->
        ScalingLazyColumn(modifier = Modifier.fillMaxWidth(), state = listState) {
            item {
                Text(
                    context.getString(R.string.sport_select_sport),
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.padding(bottom = 4.dp),
                )
            }
            items(Sport.entries.size) { i ->
                val sport = Sport.entries[i]
                Chip(
                    onClick = { vm.startSession(sport) },
                    label = {
                        Text(
                            context.getString(R.string.sport_kitesurfing),
                            modifier = Modifier.fillMaxWidth(),
                            textAlign = TextAlign.Center,
                        )
                    },
                    colors = ChipDefaults.secondaryChipColors(),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
            item {
                Chip(
                    onClick = { nav.popBackStack() },
                    label = {
                        Text(
                            context.getString(R.string.session_cancel),
                            modifier = Modifier.fillMaxWidth(),
                            textAlign = TextAlign.Center,
                        )
                    },
                    colors = ChipDefaults.secondaryChipColors(),
                    modifier = Modifier.fillMaxWidth(),
                )
            }
        }
    }
}
