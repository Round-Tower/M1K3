package app.m1k3.ai.assistant.avatar

import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.graphicsLayer
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.domain.avatar.PixelFace

/**
 * M1K3's face — a Compose Canvas render of [PixelFace]'s 13×11 grid: orange
 * dots on charcoal, blinking and glancing idly, a settled ⌣ smile. Replaces
 * the 64×64 DotMatrixAvatar hero (deleted alongside this file); see
 * [PixelFace]'s header for why this is a reduction, not a like-for-like port.
 *
 * The face's SHAPE never changes with [AvatarState] — that was the old
 * system's 8-emotion authoring surface, cut. What state DOES carry is a
 * soft activity tint (listening/thinking/generating/speaking), the same
 * signal the old chase-ring gave, expressed here as a colour on the dots
 * themselves plus a faint glow rather than a separate perimeter animation.
 *
 * Time-driven cells are read inside the [Canvas] draw lambda (deferred to
 * the draw phase, same pattern as `breathe` below) so the 60fps clock never
 * forces a recomposition of this composable — only a redraw.
 *
 * Signed: kev + claude-fable-5, 2026-08-22, confidence 0.85, context: finding
 * 7 of the Android UX pass. Prior: DotMatrixAvatar (this file's predecessor,
 * kev + claude, 2026-04-19); PixelFace.swift (M1K3ScreensaverCore).
 */
@Composable
fun PixelFaceAvatar(
    state: AvatarState,
    modifier: Modifier = Modifier,
) {
    val elapsedSeconds = remember { mutableStateOf(0.0) }
    LaunchedEffect(Unit) {
        var startNanos = -1L
        while (true) {
            withFrameNanos { frameNanos ->
                if (startNanos < 0) startNanos = frameNanos
                elapsedSeconds.value = (frameNanos - startNanos) / 1_000_000_000.0
            }
        }
    }

    val infinite = rememberInfiniteTransition(label = "pixelface")
    val breathe by infinite.animateFloat(
        initialValue = 1.00f,
        targetValue = 1.02f,
        animationSpec =
            infiniteRepeatable(
                animation = tween(4000, easing = FastOutSlowInEasing),
                repeatMode = RepeatMode.Reverse,
            ),
        label = "breathe",
    )

    val isActive = state.activity.isActive
    val activityTint =
        when (state.activity) {
            AvatarActivity.LISTENING -> MaColors.Info
            AvatarActivity.THINKING -> MaColors.Warning
            AvatarActivity.GENERATING -> MaColors.Orange
            AvatarActivity.SPEAKING -> MaColors.Success
            AvatarActivity.ERROR -> MaColors.Error
            AvatarActivity.IDLE -> MaColors.Orange
        }

    Canvas(
        modifier =
            modifier.graphicsLayer {
                scaleX = breathe
                scaleY = breathe
            },
    ) {
        val litCells = PixelFace.litCells(elapsedSeconds.value)

        val cellSize = minOf(size.width / PixelFace.COLS, size.height / PixelFace.ROWS)
        val gridWidth = cellSize * PixelFace.COLS
        val gridHeight = cellSize * PixelFace.ROWS
        val originX = (size.width - gridWidth) / 2f
        val originY = (size.height - gridHeight) / 2f
        val dotRadius = cellSize * 0.42f
        val glowRadius = dotRadius * 2.2f

        for (cell in litCells) {
            val cx = originX + cell.col * cellSize + cellSize / 2f
            val cy = originY + cell.row * cellSize + cellSize / 2f
            if (isActive) {
                drawCircle(
                    color = activityTint.copy(alpha = 0.22f),
                    radius = glowRadius,
                    center = Offset(cx, cy),
                )
            }
            drawCircle(
                color = if (isActive) activityTint else MaColors.Orange,
                radius = dotRadius,
                center = Offset(cx, cy),
            )
        }
    }
}
