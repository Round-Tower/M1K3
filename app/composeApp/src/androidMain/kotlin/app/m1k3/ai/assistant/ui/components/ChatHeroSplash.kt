package app.m1k3.ai.assistant.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AutoAwesome
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.m1k3.ai.assistant.avatar.AvatarState
import app.m1k3.ai.assistant.avatar.AvatarViewModel
import app.m1k3.ai.assistant.avatar.LocalSharedAvatarState
import app.m1k3.ai.assistant.avatar.LocalSharedAvatarVM
import app.m1k3.ai.assistant.avatar.PhosphorFoxHero
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaSpacing
import app.m1k3.ai.assistant.design.tokens.MaTypography

/**
 * The first thing you see when you open an empty chat — matches the shape of
 * the iOS/visionOS shell's `ChatScreen.hero` + `.emptyState`: the pixel face,
 * the M1K3 wordmark, a caption naming the current brain, a one-line nudge, and
 * three tap-to-send starter chips.
 *
 * Replaces the small status card that used to sit above the first message.
 * When the user starts chatting this disappears — ChatMessageList only
 * renders it when there's no user message yet.
 *
 * MurphySig: kev+claude-fable-5 / confidence 0.8 / 2026-08-20
 * Rationale: chat is the app (macos/docs/DESIGN_DOCTRINE.md) — the empty state
 * IS the home screen, so it carries the identity and the on-ramp together.
 */
@Composable
fun ChatHeroSplash(
    brainCaption: String,
    brainReady: Boolean,
    onStarterTap: (String) -> Unit,
    modifier: Modifier = Modifier,
    heavyBrain: Boolean = false,
) {
    val sharedVM: AvatarViewModel? = LocalSharedAvatarVM.current
    val collectedState by (sharedVM?.avatarState ?: kotlinx.coroutines.flow.MutableStateFlow(null))
        .collectAsState()
    val avatarState = LocalSharedAvatarState.current ?: collectedState

    Column(
        modifier =
            modifier
                .fillMaxWidth()
                .padding(horizontal = MaSpacing.md, vertical = MaSpacing.md),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(MaSpacing.sm),
    ) {
        Box(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .height(180.dp),
            contentAlignment = Alignment.Center,
        ) {
            PhosphorFoxHero(
                state = avatarState ?: AvatarState(),
                brainReady = brainReady,
                heavyBrain = heavyBrain,
                modifier = Modifier.fillMaxWidth().height(180.dp),
            )
        }

        Text(
            text = "M1K3",
            style = MaTypography.displayMedium,
            fontWeight = FontWeight.Bold,
            color = MaColors.textPrimary(),
        )
        Text(
            text = brainCaption,
            style = MaTypography.labelSmall,
            color = MaColors.textMuted(),
        )

        Column(
            modifier = Modifier.padding(top = MaSpacing.sm),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text(
                text = "Ask me anything.",
                style = MaTypography.bodyMedium,
                color = MaColors.textSecondary(),
            )
            Text(
                text = "Grounded in your documents and memories — on device.",
                style = MaTypography.bodySmall,
                color = MaColors.textMuted(),
            )
        }

        Column(
            modifier =
                Modifier
                    .padding(top = MaSpacing.md)
                    .widthIn(max = 340.dp)
                    .alpha(if (brainReady) 1f else 0.5f),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            starters.forEach { prompt ->
                StarterChip(
                    prompt = prompt,
                    enabled = brainReady,
                    onTap = { onStarterTap(prompt) },
                )
            }
        }
    }
}

private val starters =
    listOf(
        "What can you help me with?",
        "Explain something simply",
        "What do you remember about me?",
    )

@Composable
private fun StarterChip(
    prompt: String,
    enabled: Boolean,
    onTap: () -> Unit,
) {
    val shape = RoundedCornerShape(14.dp)
    Row(
        modifier =
            Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(MaColors.bgElevated(), shape)
                .clickable(
                    enabled = enabled,
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = onTap,
                ).padding(horizontal = 14.dp, vertical = 11.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            imageVector = Icons.Default.AutoAwesome,
            contentDescription = null,
            tint = MaColors.Orange,
            modifier = Modifier.size(16.dp),
        )
        Text(
            text = prompt,
            style = MaTypography.bodyMedium,
            color = MaColors.textPrimary(),
        )
    }
}
