package app.m1k3.ai.assistant.avatar

import android.app.ActivityManager
import android.content.Context
import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import app.m1k3.ai.domain.avatar.Companion3DDecision
import app.m1k3.ai.domain.avatar.Companion3DInputs
import app.m1k3.ai.domain.avatar.Companion3DPolicy
import app.m1k3.ai.domain.avatar.CrtTreatment

/**
 * The empty-chat hero's face. Shows the 3D **Phosphor Fox** under a CRT skin
 * when [Companion3DPolicy] clears it (brain resident + memory headroom + GL 3
 * + not opted out); otherwise the always-safe 2D [PixelFaceAvatar].
 *
 * The gate is read once per (brainReady, userEnabled) change — deliberately
 * not on every frame — so a transient memory dip can't tear the surface down
 * mid-render. The fox only ever mounts *after* the brain is resident, which is
 * the whole point of the OOM guard.
 *
 * MurphySig: kev+claude-opus-4-8 / confidence 0.75 / 2026-08-23
 * Prior: ChatHeroSplash (pixel-face hero); companion-fox-3d-plan.md.
 */
@Composable
fun PhosphorFoxHero(
    state: AvatarState,
    brainReady: Boolean,
    modifier: Modifier = Modifier,
    userEnabled: Boolean = true,
) {
    val context = LocalContext.current
    val decision =
        remember(brainReady, userEnabled) {
            Companion3DPolicy.decide(readCompanion3DInputs(context, brainReady, userEnabled))
        }

    when (decision) {
        Companion3DDecision.SHOW_3D -> {
            val treatment = CrtTreatment.forActivity(state.activity.isActive, state.intensity)
            Box(modifier) {
                Companion3DView(modifier = Modifier.matchParentSize())
                CrtOverlay(
                    treatment = treatment,
                    modifier = Modifier.matchParentSize(),
                )
            }
        }

        Companion3DDecision.FALLBACK_2D ->
            PixelFaceAvatar(state = state, modifier = modifier)
    }
}

private fun readCompanion3DInputs(
    context: Context,
    brainReady: Boolean,
    userEnabled: Boolean,
): Companion3DInputs {
    val am = context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
    val mem = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
    val availMb = mem.availMem / (1024L * 1024L)
    // High 16 bits of reqGlEsVersion carry the device's supported GL ES major.
    val glesMajor = am.deviceConfigurationInfo.reqGlEsVersion ushr 16
    return Companion3DInputs(
        availableMemMb = availMb,
        isLowRamDevice = am.isLowRamDevice,
        glesMajorVersion = glesMajor,
        brainResident = brainReady,
        userEnabled = userEnabled,
    )
}
