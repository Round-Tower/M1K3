package app.m1k3.ai.assistant.ui.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.m1k3.ai.assistant.avatar.AvatarState
import app.m1k3.ai.assistant.avatar.AvatarViewModel
import app.m1k3.ai.assistant.avatar.DotMatrixAvatar
import app.m1k3.ai.assistant.avatar.LocalSharedAvatarState
import app.m1k3.ai.assistant.avatar.LocalSharedAvatarVM
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaSpacing
import app.m1k3.ai.assistant.design.tokens.MaTypography

/**
 * The first thing you see when you open an empty chat — a hero splash.
 *
 *   * The pixel face as the visual anchor
 *   * A simple greeting (name, if we have one)
 *   * A muted "what are we working on?" nudge
 *
 * Replaces the small status card that used to sit above the first message.
 * When the user starts chatting this disappears — ChatMessageList only
 * renders it when `messages.size == 1 && messages.first().isStatusMessage`.
 *
 * MurphySig: kev+claude / confidence 0.72 / 2026-04-19
 * Rationale: a product's home screen sets the tone. M1K3's avatar is the
 * identity — give it the real estate.
 */
@Composable
fun ChatHeroSplash(
    userName: String?,
    modifier: Modifier = Modifier,
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
        verticalArrangement = Arrangement.spacedBy(MaSpacing.md),
    ) {
        Box(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .height(220.dp),
            contentAlignment = Alignment.Center,
        ) {
            DotMatrixAvatar(
                state = avatarState ?: AvatarState(),
                modifier = Modifier.fillMaxWidth().height(220.dp),
            )
        }

        Text(
            text = userName?.let { "Hello, $it." } ?: "Hello, friend.",
            style = MaTypography.headlineMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaColors.textPrimary(),
        )

        Text(
            text = "What are we working on?",
            style = MaTypography.bodyMedium,
            color = MaColors.textMuted(),
        )
    }
}
