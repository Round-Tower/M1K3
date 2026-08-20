package app.m1k3.ai.assistant.ui.components

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.m1k3.ai.assistant.avatar.AvatarState
import app.m1k3.ai.assistant.avatar.AvatarView
import app.m1k3.ai.assistant.avatar.AvatarViewModel
import app.m1k3.ai.assistant.avatar.DotMatrixAvatar
import app.m1k3.ai.assistant.avatar.LocalSharedAvatarState
import app.m1k3.ai.assistant.avatar.LocalSharedAvatarVM
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaRadius
import app.m1k3.ai.assistant.design.tokens.MaSpacing
import app.m1k3.ai.assistant.design.tokens.MaTypography
import app.m1k3.ai.assistant.platform.PreferenceKeys
import app.m1k3.ai.assistant.platform.PreferencesStoreInterface
import app.m1k3.ai.domain.context.ContextualGreetingBuilder
import app.m1k3.ai.domain.context.UserContext
import org.koin.compose.koinInject

/**
 * The first thing you see when you open an empty chat — a hero splash.
 *
 *   * A large 3D avatar (from the user's gallery pick) as the visual anchor
 *   * A contextual greeting (time of day + name, with any context lines)
 *   * Compact context pills
 *   * A muted "what are we working on?" nudge
 *
 * Replaces the small status card that used to sit above the first message.
 * When the user starts chatting this disappears — ChatMessageList only
 * renders it when `messages.size == 1 && messages.first().isStatusMessage`.
 *
 * MurphySig: kev+claude / confidence 0.72 / 2026-04-19
 * Rationale: a product's home screen sets the tone. M1K3's avatar is the
 * identity — give it the real estate and let eco stats ride along as a
 * visible reminder of the privacy/on-device promise.
 */
@Composable
fun ChatHeroSplash(
    userContext: UserContext?,
    onRequestLocation: (() -> Unit)? = null,
    onRequestHealth: (() -> Unit)? = null,
    onRequestScreenTime: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val greeting = userContext?.let { ContextualGreetingBuilder().build(it) }
    val sharedVM: AvatarViewModel? = LocalSharedAvatarVM.current
    val collectedState by (sharedVM?.avatarState ?: kotlinx.coroutines.flow.MutableStateFlow(null))
        .collectAsState()
    val avatarState = LocalSharedAvatarState.current ?: collectedState

    val prefs: PreferencesStoreInterface = koinInject()
    val heroStyle = prefs.getString(PreferenceKeys.HERO_STYLE, "DOT_MATRIX") ?: "DOT_MATRIX"

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
            if (heroStyle == "MODEL_3D" && avatarState != null) {
                AvatarView(
                    state = avatarState,
                    modifier = Modifier.fillMaxWidth().height(220.dp),
                    showInfo = false,
                    use3D = true,
                )
            } else {
                DotMatrixAvatar(
                    state = avatarState ?: AvatarState(),
                    modifier = Modifier.fillMaxWidth().height(220.dp),
                )
            }
        }

        Text(
            text = greeting?.greeting ?: "Hello, friend.",
            style = MaTypography.headlineMedium,
            fontWeight = FontWeight.SemiBold,
            color = MaColors.textPrimary(),
        )

        val pills =
            buildList {
                greeting?.locationLine?.let { add(it to MaColors.Orange) }
                greeting?.healthLine?.let { add(it to MaColors.textSecondary()) }
                greeting?.screenTimeLine?.let { add(it to MaColors.textSecondary()) }
                greeting?.notificationLine?.let { add(it to MaColors.textSecondary()) }
            }

        if (pills.isNotEmpty()) {
            Column(
                modifier = Modifier.fillMaxWidth(),
                verticalArrangement = Arrangement.spacedBy(MaSpacing.xs),
            ) {
                pills.forEach { (label, color) ->
                    HeroPill(label = label, accent = color)
                }
            }
        }

        Spacer(Modifier.height(MaSpacing.xs))

        Text(
            text = greeting?.closingLine ?: "What are we working on?",
            style = MaTypography.bodyMedium,
            color = MaColors.textMuted(),
        )

        if (userContext?.hasAnyContext == false) {
            Spacer(Modifier.height(MaSpacing.xs))
            PermissionNudges(
                onRequestLocation = onRequestLocation,
                onRequestHealth = onRequestHealth,
                onRequestScreenTime = onRequestScreenTime,
            )
        } else if (userContext != null) {
            Spacer(Modifier.height(MaSpacing.xs))
            PermissionNudges(
                onRequestLocation = if (userContext.location == null) onRequestLocation else null,
                onRequestHealth = if (userContext.health == null) onRequestHealth else null,
                onRequestScreenTime = if (userContext.screenTime == null) onRequestScreenTime else null,
            )
        }
    }
}

@Composable
private fun HeroPill(
    label: String,
    accent: androidx.compose.ui.graphics.Color,
) {
    val shape = RoundedCornerShape(MaRadius.full)
    Box(
        modifier =
            Modifier
                .clip(shape)
                .background(MaColors.bgElevated())
                .border(width = 1.dp, color = accent.copy(alpha = 0.35f), shape = shape)
                .padding(horizontal = MaSpacing.md, vertical = MaSpacing.xs),
    ) {
        Text(
            text = label,
            style = MaTypography.bodySmall,
            color = accent,
        )
    }
}

@Composable
private fun PermissionNudges(
    onRequestLocation: (() -> Unit)?,
    onRequestHealth: (() -> Unit)?,
    onRequestScreenTime: (() -> Unit)?,
) {
    Row(horizontalArrangement = Arrangement.spacedBy(MaSpacing.xs)) {
        onRequestLocation?.let { HeroNudge(text = "+ Location", onTap = it) }
        onRequestHealth?.let { HeroNudge(text = "+ Health", onTap = it) }
        onRequestScreenTime?.let { HeroNudge(text = "+ Screen time", onTap = it) }
    }
}

@Composable
private fun HeroNudge(
    text: String,
    onTap: () -> Unit,
) {
    val shape = RoundedCornerShape(MaRadius.full)
    Box(
        modifier =
            Modifier
                .clip(shape)
                .clickable(onClick = onTap)
                .background(MaColors.OrangeFaint)
                .border(width = 1.dp, color = MaColors.OrangeDim, shape = shape)
                .padding(horizontal = MaSpacing.sm, vertical = MaSpacing.xs),
    ) {
        Text(
            text = text,
            style = MaTypography.bodySmall,
            color = MaColors.Orange,
        )
    }
}
