package com.spoteq.wear.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.wear.compose.foundation.lazy.ScalingLazyColumn
import androidx.wear.compose.foundation.lazy.ScalingLazyListState
import androidx.wear.compose.foundation.lazy.rememberScalingLazyListState
import androidx.wear.compose.material.PositionIndicator
import androidx.wear.compose.material.Scaffold
import androidx.wear.compose.material.TimeText
import androidx.wear.compose.material.Vignette
import androidx.wear.compose.material.VignettePosition

/**
 * Circular Wear scaffold for scrolling screens: a curved [TimeText] clock at the
 * top, an edge [Vignette], and a curved [PositionIndicator] scrollbar that hugs
 * the bezel. The [content] receives the list state so it can be shared with the
 * scrollbar. [ScalingLazyColumn] gives the round-screen scaling/curving effect.
 */
@Composable
fun ListScaffold(
    content: @Composable (ScalingLazyListState) -> Unit,
) {
    val listState = rememberScalingLazyListState()
    Scaffold(
        timeText = { TimeText() },
        vignette = { Vignette(vignettePosition = VignettePosition.TopAndBottom) },
        positionIndicator = { PositionIndicator(scalingLazyListState = listState) },
    ) {
        content(listState)
    }
}

/**
 * Horizontal page dots for the active-session pager — the classic round-watch
 * page indicator anchored to the bottom of the circle.
 */
@Composable
fun PageDots(
    count: Int,
    selected: Int,
    accent: Color,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier = modifier,
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        repeat(count) { i ->
            Box(
                Modifier
                    .size(if (i == selected) 7.dp else 5.dp)
                    .clip(CircleShape)
                    .background(if (i == selected) accent else Color.Gray.copy(alpha = 0.4f)),
            )
        }
    }
}
