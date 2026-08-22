package app.m1k3.ai.assistant.ui

import androidx.compose.animation.AnimatedContent
import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseInOut
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
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.togetherWith
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaSpacing
import app.m1k3.ai.assistant.design.tokens.MaTypography
import app.m1k3.ai.assistant.onboarding.OnboardingDownloadState
import app.m1k3.ai.assistant.onboarding.OnboardingStep
import app.m1k3.ai.assistant.onboarding.OnboardingUiState
import app.m1k3.ai.assistant.onboarding.OnboardingViewModel
import app.m1k3.ai.domain.ai.M1K3Tier
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import org.koin.androidx.compose.koinViewModel

private val AwakeOrange = Color(0xFFD97706)
private val DimOrange = Color(0x40D97706)
private val GlassBg = Color(0x14FFFFFF)
private val Border = Color(0x28FFFFFF)

@Composable
fun OnboardingScreen(
    onComplete: () -> Unit,
    viewModel: OnboardingViewModel = koinViewModel(),
) {
    val state by viewModel.uiState.collectAsState()

    LaunchedEffect(state.isComplete) {
        if (state.isComplete) onComplete()
    }

    Box(
        modifier =
            Modifier
                .fillMaxSize()
                .background(Color.Black)
                .statusBarsPadding()
                .navigationBarsPadding(),
    ) {
        AnimatedContent(
            targetState = state.step,
            transitionSpec = {
                (fadeIn(tween(500)) + slideInVertically { it / 8 })
                    .togetherWith(fadeOut(tween(300)))
            },
            label = "onboarding-step",
        ) { step ->
            when (step) {
                OnboardingStep.Welcome -> {
                    WelcomeStep(onContinue = viewModel::onWelcomeContinue)
                }

                OnboardingStep.YourEngine -> {
                    YourEngineStep(
                        state = state,
                        onTierSelected = viewModel::onTierSelected,
                        onInstall = viewModel::onInstallConfirmed,
                    )
                }

                OnboardingStep.Awakening -> {
                    AwakeningStep(
                        state = state,
                        onRetry = viewModel::retryDownload,
                        onComplete = onComplete,
                    )
                }
            }
        }
    }
}

// =============================================================================
// Step 1 — Welcome
// =============================================================================

@Composable
private fun WelcomeStep(onContinue: () -> Unit) {
    val pulse = rememberInfiniteTransition(label = "pulse")
    val pulseAlpha by pulse.animateFloat(
        initialValue = 0.4f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(2000, easing = EaseInOut), RepeatMode.Reverse),
        label = "pulse-alpha",
    )

    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 32.dp),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        // Glyph
        Box(
            modifier =
                Modifier
                    .size(72.dp)
                    .clip(CircleShape)
                    .background(DimOrange)
                    .border(1.dp, AwakeOrange.copy(alpha = pulseAlpha), CircleShape),
            contentAlignment = Alignment.Center,
        ) {
            Text("M", color = AwakeOrange, fontSize = 32.sp, fontWeight = FontWeight.Black)
        }

        Spacer(Modifier.height(40.dp))

        Text(
            "M1K3",
            style =
                MaTypography.displayLarge.copy(
                    fontSize = 52.sp,
                    fontWeight = FontWeight.Black,
                    letterSpacing = (-1).sp,
                ),
            color = Color.White,
        )

        Spacer(Modifier.height(12.dp))

        Text(
            "A local, private AI companion.",
            style = MaTypography.headlineSmall,
            color = Color.White.copy(alpha = 0.7f),
            textAlign = TextAlign.Center,
        )

        Spacer(Modifier.height(24.dp))

        Text(
            "Pick a brain to get started.",
            style = MaTypography.bodyMedium,
            color = Color.White.copy(alpha = 0.45f),
            textAlign = TextAlign.Center,
            lineHeight = 22.sp,
        )

        Spacer(Modifier.height(72.dp))

        PrimaryButton("Meet my M1K3 →", onClick = onContinue)
    }
}

// =============================================================================
// Step 2 — Your Engine
// =============================================================================

@Composable
private fun YourEngineStep(
    state: OnboardingUiState,
    onTierSelected: (M1K3Tier) -> Unit,
    onInstall: () -> Unit,
) {
    val selected = state.selectedTier ?: state.recommendedTier

    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 24.dp),
        verticalArrangement = Arrangement.SpaceBetween,
    ) {
        Spacer(Modifier.height(16.dp))

        Column {
            Text(
                "Your brain",
                style = MaTypography.labelSmall,
                color = AwakeOrange,
                letterSpacing = 2.sp,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                selected?.displayName ?: "Detecting…",
                style =
                    MaTypography.displayMedium.copy(
                        fontWeight = FontWeight.Black,
                        fontSize = 42.sp,
                    ),
                color = Color.White,
            )
            Spacer(Modifier.height(8.dp))
            Text(
                selected?.tagline ?: "",
                style = MaTypography.bodyLarge,
                color = Color.White.copy(alpha = 0.6f),
            )
            Spacer(Modifier.height(20.dp))
            Text(
                selected?.description ?: "",
                style = MaTypography.bodyMedium,
                color = Color.White.copy(alpha = 0.55f),
                lineHeight = 22.sp,
            )

            selected?.let {
                Spacer(Modifier.height(12.dp))
                Text(
                    "~${it.downloadSizeMb}MB · one-time download",
                    style = MaTypography.labelSmall,
                    color = DimOrange.copy(alpha = 0.9f),
                )
            }
        }

        Column {
            // Brain picker — subtle, available if user wants to change
            Text(
                "Or pick a different brain",
                style = MaTypography.labelSmall,
                color = Color.White.copy(alpha = 0.35f),
                letterSpacing = 1.sp,
            )
            Spacer(Modifier.height(12.dp))
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                M1K3Tier.all().forEach { tier ->
                    TierChip(
                        tier = tier,
                        isSelected = selected == tier,
                        isRecommended = tier == state.recommendedTier,
                        onClick = { onTierSelected(tier) },
                        modifier = Modifier.weight(1f),
                    )
                }
            }

            Spacer(Modifier.height(20.dp))
            Text(
                "Everything runs on your device.",
                style = MaTypography.labelSmall,
                color = Color.White.copy(alpha = 0.4f),
                textAlign = TextAlign.Center,
                modifier = Modifier.fillMaxWidth(),
            )
            Spacer(Modifier.height(12.dp))
            PrimaryButton("Install my M1K3 →", onClick = onInstall)
            Spacer(Modifier.height(16.dp))
        }
    }
}

@Composable
private fun TierChip(
    tier: M1K3Tier,
    isSelected: Boolean,
    isRecommended: Boolean,
    onClick: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val bgAlpha by animateFloatAsState(
        targetValue = if (isSelected) 0.18f else 0.06f,
        animationSpec = spring(stiffness = Spring.StiffnessLow),
        label = "chip-bg",
    )
    val borderColor = if (isSelected) AwakeOrange else Border

    Column(
        modifier =
            modifier
                .clip(RoundedCornerShape(12.dp))
                .background(Color.White.copy(alpha = bgAlpha))
                .border(1.dp, borderColor, RoundedCornerShape(12.dp))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                ) { onClick() }
                .padding(vertical = 14.dp, horizontal = 8.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        Text(
            tier.displayName
                .removePrefix("M1K3")
                .trim(),
            style = MaTypography.labelMedium,
            color = if (isSelected) AwakeOrange else Color.White.copy(alpha = 0.55f),
            fontWeight = if (isSelected) FontWeight.Bold else FontWeight.Normal,
        )
        Text(
            "~${tier.downloadSizeMb}MB",
            style = MaTypography.labelSmall.copy(fontSize = 9.sp),
            color = Color.White.copy(alpha = 0.35f),
        )
        if (isRecommended) {
            Text(
                "recommended",
                style = MaTypography.labelSmall.copy(fontSize = 9.sp),
                color = AwakeOrange.copy(alpha = 0.7f),
            )
        }
    }
}

// =============================================================================
// Step 3 — Awakening
// =============================================================================

private val ethosFacts =
    listOf(
        "Your conversations never leave your device.",
        "Chat works offline. Downloads and web search — only when you ask.",
        "Your data stays on your device, always.",
        "No account. No tracking. No compromise.",
        "Your intelligence. Your hardware. Your rules.",
    )

@Composable
private fun AwakeningStep(
    state: OnboardingUiState,
    onRetry: () -> Unit,
    onComplete: () -> Unit,
) {
    val isDownloading =
        state.downloadState is OnboardingDownloadState.Downloading ||
            state.downloadState is OnboardingDownloadState.Starting
    val isComplete = state.downloadState is OnboardingDownloadState.Complete
    val isFailed = state.downloadState is OnboardingDownloadState.Failed

    // Cycling fact index
    var factIndex by remember { mutableIntStateOf(0) }
    LaunchedEffect(isDownloading) {
        if (isDownloading) {
            while (true) {
                delay(4000)
                factIndex = (factIndex + 1) % ethosFacts.size
            }
        }
    }

    // Avatar brightness: dim → bright on complete
    val avatarAlpha by animateFloatAsState(
        targetValue = if (isComplete) 1f else 0.35f,
        animationSpec = tween(1500),
        label = "avatar-alpha",
    )
    val avatarScale by animateFloatAsState(
        targetValue = if (isComplete) 1f else 0.88f,
        animationSpec = spring(dampingRatio = Spring.DampingRatioMediumBouncy),
        label = "avatar-scale",
    )

    // Pulse animation for dormant state
    val pulse = rememberInfiniteTransition(label = "dormant-pulse")
    val dormantPulse by pulse.animateFloat(
        initialValue = 0.25f,
        targetValue = 0.55f,
        animationSpec = infiniteRepeatable(tween(2400, easing = EaseInOut), RepeatMode.Reverse),
        label = "dormant-pulse-float",
    )

    Column(
        modifier = Modifier.fillMaxSize().padding(horizontal = 32.dp),
        verticalArrangement = Arrangement.SpaceBetween,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Spacer(Modifier.height(16.dp))

        // Avatar orb
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Box(
                modifier =
                    Modifier
                        .size(120.dp)
                        .scale(avatarScale)
                        .alpha(avatarAlpha)
                        .clip(CircleShape)
                        .background(
                            if (isComplete) {
                                AwakeOrange.copy(alpha = 0.15f)
                            } else {
                                Color.White.copy(alpha = 0.04f)
                            },
                        ).border(
                            width = 1.5.dp,
                            color =
                                if (isComplete) {
                                    AwakeOrange
                                } else {
                                    AwakeOrange.copy(alpha = dormantPulse)
                                },
                            shape = CircleShape,
                        ),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    if (isComplete) "M" else "·",
                    color = if (isComplete) AwakeOrange else AwakeOrange.copy(alpha = dormantPulse),
                    fontSize = if (isComplete) 52.sp else 24.sp,
                    fontWeight = FontWeight.Black,
                )
            }

            Spacer(Modifier.height(32.dp))

            AnimatedContent(
                targetState =
                    when {
                        isComplete -> "awake"
                        isFailed -> "failed"
                        else -> "sleeping"
                    },
                transitionSpec = {
                    fadeIn(tween(600)) togetherWith fadeOut(tween(300))
                },
                label = "status-text",
            ) { status ->
                Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(
                        when (status) {
                            "awake" -> "M1K3 is ready."
                            "failed" -> "Something went wrong."
                            else -> "Waking up…"
                        },
                        style = MaTypography.headlineMedium.copy(fontWeight = FontWeight.Bold),
                        color =
                            when (status) {
                                "awake" -> Color.White
                                "failed" -> Color(0xFFEF4444)
                                else -> Color.White.copy(alpha = 0.5f)
                            },
                    )
                    if (status == "sleeping") {
                        Spacer(Modifier.height(8.dp))
                        Text(
                            state.selectedTier?.displayName ?: "",
                            style = MaTypography.labelSmall,
                            color = AwakeOrange,
                            letterSpacing = 1.sp,
                        )
                    }
                }
            }
        }

        // Progress section
        Column(
            modifier = Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(20.dp),
        ) {
            when (val dl = state.downloadState) {
                is OnboardingDownloadState.Downloading -> {
                    ProgressSection(dl.progressPercent, dl.downloadedMb, dl.totalMb)
                    FactCarousel(factIndex)
                }

                is OnboardingDownloadState.Starting -> {
                    LinearProgressIndicator(
                        modifier = Modifier.fillMaxWidth().clip(CircleShape),
                        color = AwakeOrange,
                        trackColor = Color.White.copy(alpha = 0.08f),
                        strokeCap = StrokeCap.Round,
                    )
                    FactCarousel(factIndex)
                }

                is OnboardingDownloadState.Failed -> {
                    Text(
                        dl.error,
                        style = MaTypography.bodySmall,
                        color = Color(0xFFEF4444).copy(alpha = 0.8f),
                        textAlign = TextAlign.Center,
                    )
                    PrimaryButton(
                        "Try again",
                        onClick = onRetry,
                        color = Color(0xFFEF4444),
                    )
                }

                is OnboardingDownloadState.Complete -> {
                    PrimaryButton("Start talking →", onClick = onComplete)
                }

                else -> {
                    FactCarousel(factIndex)
                }
            }
            Spacer(Modifier.height(8.dp))
        }
    }
}

@Composable
private fun ProgressSection(
    progressPercent: Int,
    downloadedMb: Int,
    totalMb: Int,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
        ) {
            Text(
                "$progressPercent%",
                style = MaTypography.labelSmall,
                color = AwakeOrange,
                fontWeight = FontWeight.Bold,
            )
            Text(
                "${downloadedMb}MB / ${totalMb}MB",
                style = MaTypography.labelSmall,
                color = Color.White.copy(alpha = 0.35f),
            )
        }
        LinearProgressIndicator(
            progress = { progressPercent / 100f },
            modifier = Modifier.fillMaxWidth().height(3.dp).clip(CircleShape),
            color = AwakeOrange,
            trackColor = Color.White.copy(alpha = 0.08f),
            strokeCap = StrokeCap.Round,
        )
    }
}

@Composable
private fun FactCarousel(factIndex: Int) {
    AnimatedContent(
        targetState = factIndex,
        transitionSpec = { fadeIn(tween(500)) togetherWith fadeOut(tween(300)) },
        label = "fact-carousel",
    ) { idx ->
        Text(
            ethosFacts[idx],
            style = MaTypography.bodySmall,
            color = Color.White.copy(alpha = 0.35f),
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )
    }
}

// =============================================================================
// Shared components
// =============================================================================

@Composable
private fun PrimaryButton(
    label: String,
    onClick: () -> Unit,
    color: Color = AwakeOrange,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier =
            modifier
                .fillMaxWidth()
                .clip(RoundedCornerShape(14.dp))
                .background(color.copy(alpha = 0.15f))
                .border(1.dp, color, RoundedCornerShape(14.dp))
                .clickable(
                    interactionSource = remember { MutableInteractionSource() },
                    indication = null,
                    onClick = onClick,
                ).padding(vertical = 16.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = MaTypography.labelLarge.copy(fontWeight = FontWeight.SemiBold),
            color = color,
        )
    }
}
