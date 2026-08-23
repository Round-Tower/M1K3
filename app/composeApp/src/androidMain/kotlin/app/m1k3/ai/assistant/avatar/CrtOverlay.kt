package app.m1k3.ai.assistant.avatar

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.BlendMode
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TileMode
import app.m1k3.ai.domain.avatar.CrtTreatment
import kotlin.math.PI
import kotlin.math.sin

private val Phosphor = Color(0xFFFFB347) // hot amber — the tube colour
private val PhosphorDeep = Color(0xFFD97706) // M1K3 orange, the glow floor

/**
 * The amber-monochrome CRT skin, drawn *over* the [Companion3DView]
 * TextureView: repeating scanlines (semi-transparent black darkens the fox
 * beneath), an edge vignette, an additive amber phosphor bloom at centre, a
 * slow drifting hum-bar, and a mains flicker — all breathing with the
 * [CrtTreatment] the avatar's activity dials.
 *
 * On first mount it plays a CRT **power-on**: a fade-up from black plus a
 * bright band that sweeps down the tube. Pure texture — it never samples the
 * fox (a separate render surface), so there is no chromatic-aberration pass;
 * the aberration lives in the additive amber offset instead.
 *
 * The 60 fps clock is read inside the [Canvas] draw lambda, so it forces a
 * redraw but never a recomposition.
 *
 * MurphySig: kev+claude-opus-4-8 / confidence 0.78 / 2026-08-23
 * Rationale: overlay texture is the only CRT pass a separate SurfaceView/
 * TextureView permits without rendering the fox to an offscreen target;
 * bloom for the tube glow lives in Filament, the tube *feel* lives here.
 */
@Composable
fun CrtOverlay(
    treatment: CrtTreatment,
    modifier: Modifier = Modifier,
) {
    var elapsed by remember { mutableStateOf(0.0) }
    LaunchedEffect(Unit) {
        var start = -1L
        while (true) {
            withFrameNanos { now ->
                if (start < 0) start = now
                elapsed = (now - start) / 1_000_000_000.0
            }
        }
    }

    val powerOn = remember { Animatable(0f) }
    LaunchedEffect(Unit) {
        powerOn.animateTo(1f, tween(durationMillis = 750, easing = FastOutSlowInEasing))
    }

    Canvas(modifier = modifier) {
        val t = elapsed
        val on = powerOn.value
        val w = size.width
        val h = size.height
        if (w <= 0f || h <= 0f) return@Canvas

        // Mains flicker — a small brightness dip oscillating at the tube's hum.
        val flickerPhase = sin(2.0 * PI * treatment.flickerHz * t).toFloat()
        val flickerDip = 0.04f * (0.5f + 0.5f * flickerPhase)

        // --- additive amber phosphor bloom (centre), lifted by activity ---
        val glow = treatment.phosphorGlow * on
        drawRect(
            brush =
                Brush.radialGradient(
                    colors =
                        listOf(
                            Phosphor.copy(alpha = 0.22f * glow),
                            PhosphorDeep.copy(alpha = 0.10f * glow),
                            Color.Transparent,
                        ),
                    center = Offset(w / 2f, h * 0.46f),
                    radius = maxOf(w, h) * 0.62f,
                ),
            blendMode = BlendMode.Plus,
        )

        // --- scanlines: a repeating soft dark line every ~3px ---
        val lineHeight = 3f * density
        drawRect(
            brush =
                Brush.verticalGradient(
                    0.0f to Color.Transparent,
                    0.5f to Color.Black.copy(alpha = treatment.scanlineStrength),
                    1.0f to Color.Transparent,
                    startY = 0f,
                    endY = lineHeight,
                    tileMode = TileMode.Repeated,
                ),
        )

        // --- hum-bar: a faint bright band drifting slowly down the tube ---
        val barY = ((t * 0.08) % 1.0).toFloat() * h
        val barH = h * 0.14f
        drawRect(
            brush =
                Brush.verticalGradient(
                    colors =
                        listOf(
                            Color.Transparent,
                            Phosphor.copy(alpha = 0.05f * on),
                            Color.Transparent,
                        ),
                    startY = barY,
                    endY = barY + barH,
                ),
            topLeft = Offset(0f, barY),
            size = Size(w, barH),
            blendMode = BlendMode.Plus,
        )

        // --- vignette: darken the edges into the bezel ---
        drawRect(
            brush =
                Brush.radialGradient(
                    0.55f to Color.Transparent,
                    1.0f to Color.Black.copy(alpha = 0.55f),
                    center = Offset(w / 2f, h / 2f),
                    radius = maxOf(w, h) * 0.72f,
                ),
        )

        // --- flicker dip over the whole tube ---
        if (flickerDip > 0f) {
            drawRect(color = Color.Black.copy(alpha = flickerDip))
        }

        // --- power-on: fade up from black + a bright sweep band ---
        if (on < 1f) {
            drawRect(color = Color.Black.copy(alpha = 1f - on))
            val sweepY = on * h
            val sweepH = h * 0.06f
            drawRect(
                brush =
                    Brush.verticalGradient(
                        colors = listOf(Color.Transparent, Phosphor.copy(alpha = 0.6f), Color.Transparent),
                        startY = sweepY - sweepH,
                        endY = sweepY + sweepH,
                    ),
                topLeft = Offset(0f, sweepY - sweepH),
                size = Size(w, sweepH * 2f),
                blendMode = BlendMode.Plus,
            )
        }
    }
}
