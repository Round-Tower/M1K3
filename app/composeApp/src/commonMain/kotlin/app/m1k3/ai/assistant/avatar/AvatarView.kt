package app.m1k3.ai.assistant.avatar

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.m1k3.ai.assistant.avatar.AvatarEngine.drawRobotAvatar
import app.m1k3.ai.assistant.design.components.MaCard
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaSpacing
import app.m1k3.ai.assistant.design.tokens.MaTypography

/**
 * 間 AI Avatar View
 *
 * Main avatar display component (280dp).
 * Integrates all avatar systems:
 * - Canvas rendering (AvatarEngine)
 * - Emotion detection
 * - Activity animations
 * - State management (AvatarViewModel)
 */

/**
 * Full-size avatar display with emotion and activity indicators
 *
 * Supports both 2D Canvas and 3D model rendering:
 * - Android: 3D Colobus monkey by default (with 2D fallback)
 * - Other platforms: 2D Canvas robot (3D not yet supported)
 *
 * @param state Current avatar state (emotion, activity, intensity)
 * @param modifier Optional modifier
 * @param showInfo Whether to show emotion/activity labels
 * @param onClick Optional click handler for interactive demos
 * @param use3D Whether to use 3D model (Android only, defaults to 2D for compatibility)
 */
@Composable
fun AvatarView(
    state: AvatarState,
    modifier: Modifier = Modifier,
    showInfo: Boolean = true,
    onClick: (() -> Unit)? = null,
    use3D: Boolean = false  // Default to 2D for stability
) {
    // Animate state transitions
    val animatedState = rememberAnimatedAvatarState(
        targetState = state,
        transitionDuration = 300
    )

    // Activity-based animations
    val activityAnim = rememberActivityAnimation(state.activity)

    // Entrance animation (plays once on mount)
    val entranceProgress = rememberEntranceAnimation()

    // Bounce animation for active states
    val bounceOffset = rememberBounceAnimation(state.isAnimating)

    // No card/box — 3D avatar floats freely, parent controls sizing.
    // clipToBounds=false lets the 3D scene render beyond the container
    // (prevents model heads from being cut off with overhead camera angles).
    Box(
        modifier = modifier
            .then(if (onClick != null) Modifier.clickable(onClick = onClick) else Modifier)
            .graphicsLayer {
                clip = false
                scaleX = activityAnim.scale * entranceProgress
                scaleY = activityAnim.scale * entranceProgress
                rotationZ = activityAnim.rotation
                translationX = activityAnim.offsetX
                translationY = activityAnim.offsetY + bounceOffset
            },
        contentAlignment = Alignment.Center
    ) {
        if (use3D) {
            AvatarViewContent3D(state = animatedState)
        } else {
            // 2D Canvas rendering (all platforms)
            Canvas(modifier = Modifier.fillMaxSize()) {
                drawRobotAvatar(
                    state = animatedState,
                    geometry = RobotGeometry(),
                    animation = AvatarAnimation()
                )
            }
        }
    }
}

/**
 * Compact avatar display (200dp)
 *
 * Smaller version without labels, for headers/toolbars.
 *
 * @param state Current avatar state
 * @param modifier Optional modifier
 */
@Composable
fun AvatarViewCompact(
    state: AvatarState,
    modifier: Modifier = Modifier
) {
    val animatedState = rememberAnimatedAvatarState(state)
    val activityAnim = rememberActivityAnimation(state.activity)

    Box(
        modifier = modifier
            .size(200.dp)
            .scale(activityAnim.scale)
            .graphicsLayer {
                rotationZ = activityAnim.rotation
                translationX = activityAnim.offsetX
                translationY = activityAnim.offsetY
            },
        contentAlignment = Alignment.Center
    ) {
        Canvas(modifier = Modifier.fillMaxSize()) {
            drawRobotAvatar(
                state = animatedState,
                geometry = RobotGeometry(),
                animation = AvatarAnimation()
            )
        }
    }
}

/**
 * Avatar emotion selector
 *
 * Interactive grid for testing/selecting emotions.
 *
 * @param onEmotionSelected Callback when emotion is selected
 * @param modifier Optional modifier
 */
@Composable
fun AvatarEmotionSelector(
    onEmotionSelected: (AvatarEmotion) -> Unit,
    modifier: Modifier = Modifier
) {
    val emotions = remember {
        listOf(
            AvatarEmotion.HAPPY,
            AvatarEmotion.SAD,
            AvatarEmotion.ANGRY,
            AvatarEmotion.SURPRISED,
            AvatarEmotion.LOVE,
            AvatarEmotion.THINKING,
            AvatarEmotion.SLEEPY,
            AvatarEmotion.EXCITED,
            AvatarEmotion.NEUTRAL
        )
    }

    Column(
        modifier = modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(MaSpacing.sm)
    ) {
        Text(
            text = "Avatar Emotions",
            style = MaTypography.titleMedium,
            fontWeight = FontWeight.Bold,
            color = MaColors.textPrimary()
        )

        // Grid of emotion buttons
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(MaSpacing.sm)
        ) {
            emotions.chunked(3).forEach { row ->
                Column(
                    modifier = Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(MaSpacing.sm)
                ) {
                    row.forEach { emotion ->
                        MaCard(
                            onClick = { onEmotionSelected(emotion) },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Column(
                                modifier = Modifier
                                    .fillMaxWidth()
                                    .padding(MaSpacing.sm),
                                horizontalAlignment = Alignment.CenterHorizontally
                            ) {
                                Text(
                                    text = emotion.emoji,
                                    style = MaTypography.headlineSmall
                                )
                                Text(
                                    text = emotion.displayName,
                                    style = MaTypography.labelSmall,
                                    color = emotion.primaryColor,
                                    fontWeight = FontWeight.Medium
                                )
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * Avatar activity indicator
 *
 * Shows current AI activity with animation.
 *
 * @param activity Current activity
 * @param modifier Optional modifier
 */
@Composable
fun AvatarActivityIndicator(
    activity: AvatarActivity,
    modifier: Modifier = Modifier
) {
    val activityAnim = rememberActivityAnimation(activity)
    val idleColor = MaColors.textDisabled()

    Row(
        modifier = modifier
            .scale(activityAnim.scale)
            .padding(horizontal = MaSpacing.base, vertical = MaSpacing.sm),
        horizontalArrangement = Arrangement.spacedBy(MaSpacing.sm),
        verticalAlignment = Alignment.CenterVertically
    ) {
        // Activity indicator dot
        Box(
            modifier = Modifier
                .size(12.dp)
                .graphicsLayer {
                    alpha = if (activity.isActive) 1f else 0.3f
                }
        ) {
            Canvas(modifier = Modifier.fillMaxSize()) {
                drawCircle(
                    color = when (activity) {
                        AvatarActivity.LISTENING -> MaColors.Info
                        AvatarActivity.THINKING -> MaColors.Warning
                        AvatarActivity.GENERATING -> MaColors.Orange
                        AvatarActivity.SPEAKING -> MaColors.Success
                        AvatarActivity.ERROR -> MaColors.Error
                        AvatarActivity.IDLE -> idleColor
                    }
                )
            }
        }

        Text(
            text = activity.displayName,
            style = MaTypography.bodySmall,
            color = if (activity.isActive) MaColors.textPrimary() else MaColors.textDisabled(),
            fontWeight = if (activity.isActive) FontWeight.Medium else FontWeight.Normal
        )
    }
}

/**
 * Platform-specific 3D avatar content
 *
 * On Android: Renders Colobus 3D model with SceneView
 * On other platforms: Falls back to 2D Canvas (3D not yet supported)
 *
 * @param state Avatar state to render
 */
@Composable
expect fun AvatarViewContent3D(
    state: AvatarState
)

/**
 * Usage Examples:
 * ```kotlin
 * // ========================================
 * // Classic Avatar Usage
 * // ========================================
 *
 * @Composable
 * fun AvatarDemo() {
 *     val viewModel = rememberAvatarViewModel()
 *     val state by viewModel.collectAsState()
 *
 *     Column {
 *         // Main avatar display
 *         AvatarView(
 *             state = state,
 *             showInfo = true,
 *             onClick = { viewModel.flashEmotion(AvatarEmotion.EXCITED) }
 *         )
 *
 *         // Emotion selector
 *         AvatarEmotionSelector(
 *             onEmotionSelected = { viewModel.setEmotion(it, 0.8f) }
 *         )
 *
 *         // Activity indicator
 *         AvatarActivityIndicator(activity = state.activity)
 *     }
 * }
 *
 * @Composable
 * fun ChatScreenWithAvatar() {
 *     val viewModel = rememberAvatarViewModel()
 *
 *     // Sync with AI
 *     LaunchedEffect(isGenerating) {
 *         viewModel.syncWithAI(isGenerating)
 *     }
 *
 *     // Compact avatar in header
 *     AvatarViewCompact(
 *         state = viewModel.avatarState.collectAsState().value,
 *         modifier = Modifier.size(80.dp)
 *     )
 * }
 *
 * ```
 */
