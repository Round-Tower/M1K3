package app.m1k3.ai.assistant.ui.components

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.SizeTransform
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaRadius
import app.m1k3.ai.assistant.design.tokens.MaSpacing
import app.m1k3.ai.assistant.design.tokens.MaTypography
import app.m1k3.ai.domain.ai.LlmModel
import kotlin.math.abs
import kotlin.math.sin

/**
 * Footer strip rendered immediately below the ChatInputBar, as a single
 * visual unit with the input. Reads like metadata — small, muted, with
 * a hairline divider above.
 *
 * Morphs into a full-width listening pill (with animated waveform + live
 * transcript) whenever voice input is active, using [AnimatedContent] +
 * [SizeTransform] so the bar *becomes* the pill rather than fades across.
 *
 * Pure renderer over [ChatContextBarState] — mapping logic stays testable.
 */
@Composable
fun ChatContextBar(
    state: ChatContextBarState,
    availableModels: List<LlmModel>,
    onModelSwitch: (LlmModel) -> Unit,
    onContextTap: () -> Unit = {},
    enabled: Boolean = true,
    modifier: Modifier = Modifier,
) {
    val isListening = state.status is ChatContextBarStatus.Listening

    Box(
        modifier =
            modifier
                .fillMaxWidth()
                .heightIn(min = 28.dp)
                .padding(
                    start = MaSpacing.md,
                    end = MaSpacing.md,
                    top = 4.dp,
                    bottom = MaSpacing.xs,
                ),
    ) {
        AnimatedContent(
            targetState = isListening,
            transitionSpec = {
                (fadeIn(tween(180)) togetherWith fadeOut(tween(140)))
                    .using(SizeTransform(clip = false) { _, _ -> tween(260, easing = FastOutSlowInEasing) })
            },
            label = "contextBarMorph",
        ) { listening ->
            if (listening) {
                val partial = (state.status as? ChatContextBarStatus.Listening)?.partial.orEmpty()
                ListeningPill(partial = partial)
            } else {
                FooterRow(
                    state = state,
                    availableModels = availableModels,
                    onModelSwitch = onModelSwitch,
                    onContextTap = onContextTap,
                    enabled = enabled,
                )
            }
        }
    }
}

// `state.currentModel` / `availableModels` / `onModelSwitch` stay on the
// footer's data contract (Settings' Brain section is the one place a brain
// is chosen — doctrine principle 6, "show a state once") but the row itself
// no longer renders the brain name or a tokens/sec figure: those are
// engineering nouns (doctrine principle 7) that don't belong on the chat
// face. What's left is context-window headroom (a real, non-noisy signal)
// and — while a tool call is in flight — that it's happening.
@Composable
private fun FooterRow(
    state: ChatContextBarState,
    availableModels: List<LlmModel>,
    onModelSwitch: (LlmModel) -> Unit,
    onContextTap: () -> Unit,
    enabled: Boolean,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(MaSpacing.sm),
    ) {
        ContextTag(
            percent = state.contextPercent,
            onTap = onContextTap,
        )

        Spacer(modifier = Modifier.weight(1f))

        val toolRunning = state.status as? ChatContextBarStatus.ToolRunning
        if (toolRunning != null) {
            ToolRunningChip(toolId = toolRunning.toolId)
        }
    }
}

@Composable
private fun Dot() {
    Box(
        modifier =
            Modifier
                .size(2.dp)
                .clip(CircleShape)
                .background(MaColors.textMuted().copy(alpha = 0.5f)),
    )
}

@Composable
private fun ContextTag(
    percent: Int,
    onTap: () -> Unit,
) {
    val color =
        when {
            percent >= 80 -> MaColors.Error
            percent >= 50 -> MaColors.Warning
            else -> MaColors.Success
        }
    Row(
        modifier =
            Modifier
                .clip(RoundedCornerShape(MaRadius.xs))
                .clickable(onClick = onTap)
                .padding(horizontal = 4.dp, vertical = 2.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Box(
            modifier =
                Modifier
                    .size(5.dp)
                    .clip(CircleShape)
                    .background(color),
        )
        Text(
            text = "$percent%",
            style = MaTypography.labelSmall,
            color = MaColors.textMuted(),
        )
    }
}

@Composable
private fun ToolRunningChip(toolId: String) {
    val transition = rememberInfiniteTransition(label = "toolPulse")
    val alpha by transition.animateFloat(
        initialValue = 0.45f,
        targetValue = 1f,
        animationSpec =
            infiniteRepeatable(
                animation = tween(700, easing = FastOutSlowInEasing),
                repeatMode = RepeatMode.Reverse,
            ),
        label = "toolPulseAlpha",
    )
    // Spring slide-in so tool use feels purposeful
    val entered = remember { mutableStateOf(false) }
    LaunchedEffect(toolId) { entered.value = true }
    val slide by animateFloatAsState(
        targetValue = if (entered.value) 0f else 16f,
        animationSpec = spring(dampingRatio = Spring.DampingRatioMediumBouncy, stiffness = Spring.StiffnessMedium),
        label = "toolChipSlide",
    )
    Row(
        modifier =
            Modifier
                .clip(RoundedCornerShape(MaRadius.xs))
                .background(MaColors.Orange.copy(alpha = 0.14f))
                .padding(horizontal = 8.dp, vertical = 3.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Box(
            modifier =
                Modifier
                    .size(6.dp)
                    .clip(CircleShape)
                    .background(MaColors.Orange.copy(alpha = alpha)),
        )
        Text(
            text = toolId.replace('_', ' '),
            style = MaTypography.labelSmall,
            color = MaColors.Orange,
            fontWeight = FontWeight.Medium,
            modifier = Modifier.padding(start = slide.dp),
        )
    }
}

@Composable
private fun ListeningPill(partial: String) {
    Row(
        modifier =
            Modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(MaRadius.lg))
                .background(MaColors.Orange.copy(alpha = 0.14f))
                .padding(horizontal = MaSpacing.md, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(MaSpacing.sm),
    ) {
        Waveform(barCount = 5, modifier = Modifier.size(width = 36.dp, height = 18.dp))
        Text(
            text = "Listening",
            style = MaTypography.labelSmall,
            color = MaColors.Orange,
            fontWeight = FontWeight.Medium,
        )
        if (partial.isNotBlank()) {
            Text(
                text = "· $partial",
                style = MaTypography.labelSmall,
                color = MaColors.textSecondary(),
                maxLines = 1,
            )
        }
    }
}

@Composable
private fun Waveform(
    barCount: Int,
    modifier: Modifier = Modifier,
) {
    val transition = rememberInfiniteTransition(label = "waveform")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = (2 * kotlin.math.PI).toFloat(),
        animationSpec =
            infiniteRepeatable(
                animation = tween(durationMillis = 900, easing = FastOutSlowInEasing),
                repeatMode = RepeatMode.Restart,
            ),
        label = "waveformPhase",
    )
    Canvas(modifier = modifier) {
        val barWidth = size.width / (barCount * 2f - 1f)
        val centerY = size.height / 2f
        val maxHalfHeight = size.height * 0.45f
        for (i in 0 until barCount) {
            val offset = i / barCount.toFloat()
            val amp = abs(sin(phase + offset * 3f)) * 0.9f + 0.1f
            val half = maxHalfHeight * amp
            val x = i * (barWidth * 2f)
            drawLine(
                color = MaColors.Orange,
                start = Offset(x + barWidth / 2f, centerY - half),
                end = Offset(x + barWidth / 2f, centerY + half),
                strokeWidth = barWidth,
            )
        }
    }
}
