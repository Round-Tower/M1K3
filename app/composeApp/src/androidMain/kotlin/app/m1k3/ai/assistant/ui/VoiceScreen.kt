package app.m1k3.ai.assistant.ui

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import app.m1k3.ai.assistant.avatar.AvatarActivity
import app.m1k3.ai.assistant.avatar.AvatarState
import app.m1k3.ai.assistant.avatar.DotMatrixAvatar
import app.m1k3.ai.assistant.avatar.LocalSharedAvatarState
import app.m1k3.ai.assistant.avatar.LocalSharedAvatarVM
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaTypography
import app.m1k3.ai.assistant.voice.VoiceLoopController
import app.m1k3.ai.domain.voice.PoliteEndpoint
import app.m1k3.ai.domain.voice.VoiceLoopState
import kotlinx.coroutines.flow.MutableStateFlow

/**
 * The full-screen caption a [VoiceLoopState] renders — verbatim from the iOS
 * shell (macos/M1K3iOSApp/VoiceScreen.swift) so voice mode reads the same on
 * every M1K3 surface.
 */
internal fun voiceCaptionText(state: VoiceLoopState): String =
    when (state) {
        is VoiceLoopState.Idle -> "Tap the mic to talk"
        is VoiceLoopState.Listening -> state.partial.ifEmpty { "Listening…" }
        is VoiceLoopState.AwaitingAnswer -> "Thinking…"
        is VoiceLoopState.Speaking -> state.answer
        is VoiceLoopState.Ended -> ""
    }

internal fun voiceAccessibilityLabel(state: VoiceLoopState): String =
    when (state) {
        is VoiceLoopState.Idle -> "Voice mode, microphone parked"
        is VoiceLoopState.Listening -> "Listening"
        is VoiceLoopState.AwaitingAnswer -> "Thinking"
        is VoiceLoopState.Speaking -> "Speaking"
        is VoiceLoopState.Ended -> "Voice mode ended"
    }

/** Teach the spoken submit button only while it's actionable. */
internal fun showsPoliteHint(state: VoiceLoopState): Boolean = state is VoiceLoopState.Listening

/**
 * Voice-first mode, full screen: the pixel face IS the interface. A big live
 * avatar, one caption line that tracks the loop state, and glass-simple
 * controls — tap to talk, tap to interrupt, X to leave. Everything routes
 * through the package-TDD'd [VoiceLoopController]; this view renders its
 * state and forwards intents. Mirrors macos/M1K3iOSApp/VoiceScreen.swift.
 */
@Composable
fun VoiceScreen(
    controller: VoiceLoopController,
    onExit: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val state by controller.state.collectAsState()
    val lastError by controller.lastError.collectAsState()
    val context = LocalContext.current
    val avatarVM = LocalSharedAvatarVM.current
    val collectedAvatarState by (avatarVM?.avatarState ?: MutableStateFlow(null)).collectAsState()
    val avatarState = LocalSharedAvatarState.current ?: collectedAvatarState ?: AvatarState()

    var hasMicPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) ==
                PackageManager.PERMISSION_GRANTED,
        )
    }
    val permissionLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            hasMicPermission = granted
            if (granted) controller.begin()
        }

    LaunchedEffect(Unit) {
        if (hasMicPermission) {
            controller.begin()
        } else {
            permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    DisposableEffect(Unit) {
        onDispose { controller.exit() }
    }

    if (avatarVM != null) {
        LaunchedEffect(state) {
            when (state) {
                is VoiceLoopState.Listening -> avatarVM.setActivity(AvatarActivity.LISTENING)
                is VoiceLoopState.AwaitingAnswer -> avatarVM.startThinking()
                is VoiceLoopState.Speaking -> avatarVM.startSpeaking()
                VoiceLoopState.Idle, VoiceLoopState.Ended -> avatarVM.returnToIdle()
            }
        }
    }

    Box(
        modifier =
            modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(listOf(MaColors.BgPrimary, MaColors.Black)),
                ),
    ) {
        Column(
            modifier = Modifier.fillMaxSize().padding(bottom = 36.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.height(48.dp))

            Box(
                modifier =
                    Modifier
                        .size(280.dp)
                        .padding(horizontal = 32.dp)
                        .clickable(enabled = state is VoiceLoopState.Speaking) { controller.interrupt() }
                        .semantics { contentDescription = voiceAccessibilityLabel(state) },
                contentAlignment = Alignment.Center,
            ) {
                DotMatrixAvatar(state = avatarState)
            }

            Spacer(Modifier.height(28.dp))

            Column(
                modifier = Modifier.fillMaxWidth().padding(horizontal = 32.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
            ) {
                Text(
                    text = voiceCaptionText(state),
                    style = MaTypography.titleMedium,
                    color = MaColors.textPrimary(),
                    textAlign = TextAlign.Center,
                    maxLines = 4,
                )
                lastError?.let { error ->
                    Text(
                        text = error,
                        style = MaTypography.bodySmall,
                        color = MaColors.Orange,
                        textAlign = TextAlign.Center,
                    )
                }
                if (showsPoliteHint(state)) {
                    Text(
                        text = PoliteEndpoint.UI_HINT,
                        style = MaTypography.bodySmall,
                        color = MaColors.textMuted(),
                    )
                }
            }

            Spacer(Modifier.weight(1f))

            when (state) {
                VoiceLoopState.Idle -> {
                    FilledTonalIconButton(
                        // The mic is the retry path too: a denied permission re-asks
                        // instead of driving the recogniser into a permission error.
                        onClick = {
                            if (hasMicPermission) {
                                controller.begin()
                            } else {
                                permissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
                            }
                        },
                        modifier = Modifier.size(64.dp),
                    ) {
                        Icon(Icons.Default.Mic, contentDescription = "Start listening")
                    }
                }

                is VoiceLoopState.Speaking -> {
                    FilledTonalIconButton(
                        onClick = { controller.interrupt() },
                        modifier = Modifier.size(64.dp),
                    ) {
                        Icon(Icons.Default.Stop, contentDescription = "Interrupt")
                    }
                }

                else -> {
                    Spacer(Modifier.height(64.dp))
                }
            }
        }

        IconButton(
            onClick = onExit,
            modifier = Modifier.align(Alignment.TopEnd).padding(20.dp),
        ) {
            Icon(
                Icons.Default.Close,
                contentDescription = "Leave voice mode",
                tint = MaColors.textPrimary(),
            )
        }
    }
}
