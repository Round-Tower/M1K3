package app.m1k3.ai.assistant.ui

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.GraphicEq
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Snackbar
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import app.m1k3.ai.assistant.MainActivity
import app.m1k3.ai.assistant.app.InitializationViewModel
import app.m1k3.ai.assistant.avatar.LocalSharedAvatarVM
import app.m1k3.ai.assistant.chat.ChatMessage
import app.m1k3.ai.assistant.chat.ChatScreenViewModel
import app.m1k3.ai.assistant.chat.ContextWindowState
import app.m1k3.ai.assistant.chat.GenerationState
import app.m1k3.ai.assistant.chat.ModelDownloadState
import app.m1k3.ai.assistant.chat.collectAsState
import app.m1k3.ai.assistant.chat.isGenerating
import app.m1k3.ai.assistant.chat.isInputEnabled
import app.m1k3.ai.assistant.chat.toEmoji
import app.m1k3.ai.assistant.chat.toUserMessage
import app.m1k3.ai.assistant.design.components.MaChatBubbleAI
import app.m1k3.ai.assistant.design.components.MaChatBubbleUser
import app.m1k3.ai.assistant.design.components.ThinkingPill
import app.m1k3.ai.assistant.design.components.ToolCallPill
import app.m1k3.ai.assistant.design.haptics.rememberHapticFeedback
import app.m1k3.ai.assistant.design.theme.MaTheme
import app.m1k3.ai.assistant.design.tokens.MaColors
import app.m1k3.ai.assistant.design.tokens.MaRadius
import app.m1k3.ai.assistant.design.tokens.MaSpacing
import app.m1k3.ai.assistant.design.tokens.MaTypography
import app.m1k3.ai.assistant.stt.AndroidSttEngine
import app.m1k3.ai.assistant.ui.components.ChatContextBar
import app.m1k3.ai.assistant.ui.components.ChatContextBarState
import app.m1k3.ai.assistant.ui.components.ChatInputBar
import app.m1k3.ai.assistant.ui.components.ChatInputBarContainer
import app.m1k3.ai.assistant.ui.components.ChatMessageList
import app.m1k3.ai.assistant.ui.components.ClearConversationDialog
import app.m1k3.ai.assistant.ui.components.ContextWindowIndicator
import app.m1k3.ai.domain.ai.LlmModel
import app.m1k3.ai.domain.ai.M1K3Tier
import app.m1k3.ai.domain.chat.ChatError
import app.m1k3.ai.domain.stt.SttState
import app.m1k3.ai.domain.stt.isListening
import org.jetbrains.compose.ui.tooling.preview.Preview
import org.koin.androidx.compose.koinViewModel
import org.koin.core.parameter.parametersOf
import androidx.compose.runtime.collectAsState as collectFlowAsState

/**
 * M1K3 AI - Chat Screen
 *
 * Beautiful chat interface with live AI responses.
 * 100% local inference - privacy first!
 *
 * **Architecture:**
 * - Uses ChatScreenViewModel for state management
 * - Delegates to extracted components (ChatInputBar, ChatHeroSplash, etc.)
 * - Minimal UI logic - ViewModel handles business logic
 *
 * **Responsibilities:**
 * - Compose UI layout
 * - Event delegation to ViewModel
 * - Avatar state synchronization
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ChatScreen(
    onNavigateToSettings: () -> Unit = {},
    onNavigateToVoiceMode: () -> Unit = {},
    onClearConversationClick: (() -> Unit)? = null,
    projectId: String = "default",
) {
    rememberCoroutineScope()
    val listState = rememberLazyListState()
    val context = LocalContext.current
    val viewModel =
        koinViewModel<ChatScreenViewModel> {
            parametersOf(projectId)
        }

    // Avatar state management - use shared app-level ViewModel from CompositionLocal
    val avatarVM = LocalSharedAvatarVM.current

    val uiState by viewModel.collectAsState()
    var showClearDialog by remember { mutableStateOf(false) }
    var inputFocused by remember { mutableStateOf(false) }
    val haptics = rememberHapticFeedback()

    // Speech-to-Text engine
    val sttEngine = remember { AndroidSttEngine(context) }
    val sttState by sttEngine.state.collectFlowAsState()

    // Cleanup STT on dispose
    DisposableEffect(Unit) {
        onDispose { sttEngine.release() }
    }

    // When STT produces a result, populate the input field
    LaunchedEffect(sttState) {
        when (val state = sttState) {
            is SttState.Result -> {
                haptics.success()
                viewModel.updateInputText(state.text)
            }

            is SttState.Error -> {
                haptics.error()
            }

            else -> {}
        }
    }

    // onClearConversationClick wired below — button placed in input row

    // Sync avatar with generation state + haptics on state transitions
    if (avatarVM != null) {
        LaunchedEffect(uiState.generationState) {
            when (val genState = uiState.generationState) {
                is GenerationState.Thinking -> {
                    avatarVM.startThinking()
                }

                is GenerationState.Streaming -> {
                    if (avatarVM.currentActivity != app.m1k3.ai.assistant.avatar.AvatarActivity.SPEAKING) {
                        avatarVM.startSpeaking()
                    }
                    // Real-time emotion detection from streaming text —
                    // avatar reacts to what the model is saying as it generates.
                    // Detect directly (not processMessage) to avoid polluting
                    // conversation history with cumulative partial fragments.
                    val detection =
                        app.m1k3.ai.assistant.avatar.EmotionDetector
                            .detectEmotion(genState.partialText)
                    if (detection.confidence > 0.3f) {
                        avatarVM.setEmotion(detection.emotion, detection.intensity)
                    }
                }

                is GenerationState.Complete -> {
                    haptics.success()
                    avatarVM.processMessage(genState.finalText, isUserMessage = false)
                    kotlinx.coroutines.delay(2000)
                    avatarVM.returnToIdle()
                }

                is GenerationState.Failed -> {
                    haptics.error()
                    avatarVM.showError("Generation failed")
                    kotlinx.coroutines.delay(2000)
                    avatarVM.returnToIdle()
                }

                else -> {}
            }
        }
    } else {
        // No avatar VM — still fire haptics on generation events
        LaunchedEffect(uiState.generationState) {
            when (uiState.generationState) {
                is GenerationState.Complete -> {
                    haptics.success()
                }

                is GenerationState.Failed -> {
                    haptics.error()
                }

                else -> {}
            }
        }
    }

    // Tool-driven avatar emotion — the avatar reacts when a tool fires.
    // Runs AFTER the Complete handler's returnToIdle delay so the emotion
    // lingers long enough for the user to see it.
    if (avatarVM != null) {
        val executedCount = uiState.toolState.executedTools.size
        LaunchedEffect(executedCount) {
            if (executedCount == 0) return@LaunchedEffect
            val latest = uiState.toolState.executedTools.lastOrNull() ?: return@LaunchedEffect
            kotlinx.coroutines.delay(2200) // let the Complete handler's returnToIdle settle
            val emotion =
                app.m1k3.ai.assistant.avatar.ToolEmotionMap.emotionFor(
                    toolId = latest.toolId,
                    category = null,
                    success = latest.isSuccess,
                )
            avatarVM.setEmotion(emotion, intensity = 0.9f)
        }
    }

    // Engine failed overlay — shown when model is missing or corrupt
    val engineState = uiState.engineState
    if (engineState is app.m1k3.ai.assistant.chat.EngineState.Failed) {
        androidx.compose.foundation.layout.Box(
            modifier = Modifier.fillMaxSize(),
            contentAlignment = Alignment.Center,
        ) {
            androidx.compose.foundation.layout.Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(16.dp),
                modifier = Modifier.padding(32.dp),
            ) {
                androidx.compose.material3.Text(
                    text = "M1K3 needs a model",
                    style = MaTypography.headlineSmall,
                    color = MaColors.textPrimary(),
                )
                androidx.compose.material3.Text(
                    text = engineState.error.toUserMessage(),
                    style = MaTypography.bodyMedium,
                    color = MaColors.textMuted(),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
                androidx.compose.material3.Button(
                    onClick = { viewModel.retryEngineInit() },
                ) {
                    androidx.compose.material3.Text("Download again")
                }
            }
        }
        return@ChatScreen
    }

    // Initialize AI engine + consume shared text
    LaunchedEffect(Unit) {
        viewModel.initializeEngine()

        // Check for shared text from ACTION_SEND intent
        val sharedText = MainActivity.consumeSharedText()
        if (sharedText != null) {
            viewModel.sendSharedText(sharedText)
        }
    }

    // Stick-to-bottom: true when the last visible item is one of the last
    // few entries, so we only auto-scroll if the user hasn't wandered up
    // to read older messages.
    val stickToBottom by remember {
        androidx.compose.runtime.derivedStateOf {
            val info = listState.layoutInfo
            val total = info.totalItemsCount
            if (total == 0) {
                true
            } else {
                val lastVisible = info.visibleItemsInfo.lastOrNull()?.index ?: -1
                lastVisible >= total - 2
            }
        }
    }

    // Auto-scroll when new messages arrive (only if user is near bottom).
    LaunchedEffect(uiState.messages.size) {
        if (uiState.messages.isNotEmpty() && stickToBottom) {
            runCatching { listState.animateScrollToItem(uiState.messages.size - 1) }
        }
    }

    // Stream-stick: while tokens are streaming and the user is near bottom,
    // keep the last message pinned as new content pushes it upward.
    LaunchedEffect(uiState.generationState, uiState.messages.size) {
        if (uiState.generationState.isGenerating && stickToBottom && uiState.messages.isNotEmpty()) {
            runCatching { listState.scrollToItem(uiState.messages.size - 1) }
        }
    }

    // Focus-stick: when the user taps into the input, surface the most
    // recent message so the keyboard doesn't obscure where they were.
    LaunchedEffect(inputFocused) {
        if (inputFocused && uiState.messages.isNotEmpty()) {
            runCatching { listState.animateScrollToItem(uiState.messages.size - 1) }
        }
    }

    // Dictation-into-the-field toggle — a DIFFERENT job from the toolbar's
    // full-screen "Voice mode" (below): this types by voice, it doesn't hold
    // a spoken conversation. Same AndroidSttEngine instance as before.
    val dictationToggle: (() -> Unit)? =
        if (sttEngine.isAvailable()) {
            {
                if (sttState.isListening) sttEngine.stopListening() else sttEngine.startListening()
            }
        } else {
            null
        }

    val currentBrainCaption =
        M1K3Tier
            .all()
            .find { it.model == uiState.currentModel }
            ?.displayName
            ?.removeSuffix(" M1K3")
            ?: uiState.currentModel.displayName

    Scaffold(
        topBar = {
            TopAppBar(
                // No title text — the wordmark lives in the empty-state hero;
                // once chatting, the transcript owns the screen.
                title = {},
                actions = {
                    IconButton(
                        onClick = { showClearDialog = true },
                        enabled = uiState.messages.isNotEmpty() && !uiState.generationState.isGenerating,
                    ) {
                        Icon(Icons.Default.Edit, contentDescription = "New chat")
                    }
                    IconButton(
                        onClick = onNavigateToVoiceMode,
                        enabled = uiState.isInputEnabled,
                    ) {
                        Icon(Icons.Default.GraphicEq, contentDescription = "Voice mode")
                    }
                    IconButton(onClick = onNavigateToSettings) {
                        Icon(Icons.Default.Settings, contentDescription = "Settings")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaColors.bgPrimary()),
            )
        },
        containerColor = MaColors.bgPrimary(),
    ) { scaffoldPadding ->
        Box(
            modifier =
                Modifier
                    .fillMaxSize()
                    .padding(top = scaffoldPadding.calculateTopPadding())
                    .animateContentSize(),
        ) {
            // Layer 1: Messages list (behind overlays)
            // Note: ContextWindowIndicator retired — its % lives in the
            // ChatContextBar footer now (one signal, one place).
            Column(modifier = Modifier.fillMaxSize()) {
                // Messages list
                ChatMessageList(
                    messages = uiState.messages,
                    isGenerating = uiState.generationState.isGenerating,
                    listState = listState,
                    onSpeak = { text -> viewModel.speakMessage(text) },
                    brainCaption = currentBrainCaption,
                    brainReady = uiState.isInputEnabled,
                    onStarterTap = { prompt ->
                        avatarVM?.processMessage(prompt, isUserMessage = true)
                        viewModel.updateInputText(prompt)
                        viewModel.sendMessage()
                    },
                    generationState = uiState.generationState,
                )
            }

            // Download progress overlay
            uiState.modelDownload?.let { downloadState ->
                ModelDownloadOverlay(
                    state = downloadState,
                    modifier =
                        Modifier
                            .align(Alignment.BottomCenter)
                            .padding(bottom = 120.dp),
                )
            }

            // Bottom overlay: context bar + input bar with gradient
            val partialTranscript = (sttState as? SttState.Listening)?.partialText ?: ""
            val contextBarState =
                ChatContextBarState.from(
                    uiState = uiState,
                    isListening = sttState.isListening,
                    partialTranscript = partialTranscript,
                )
            // Floating "island" cluster: input + footer share one rounded
            // elevated surface, set off from the nav bar with breathing room

            val islandShape = RoundedCornerShape(MaRadius.xxl)
            Column(
                modifier =
                    Modifier
                        .align(Alignment.BottomCenter)
                        .fillMaxWidth()
                        .navigationBarsPadding()
                        .imePadding()
                        .padding(horizontal = MaSpacing.sm, vertical = MaSpacing.sm)
                        .clip(islandShape)
                        .background(MaColors.bgElevated(), islandShape)
                        .border(1.dp, MaColors.borderSubtle(), islandShape),
            ) {
                ChatInputBar(
                    text = uiState.inputText,
                    onTextChange = { viewModel.updateInputText(it) },
                    onSend = {
                        avatarVM?.processMessage(uiState.inputText, isUserMessage = true)
                        viewModel.sendMessage()
                    },
                    enabled = uiState.isInputEnabled,
                    isListening = sttState.isListening,
                    onMicClick = dictationToggle,
                    listeningPartialText = partialTranscript,
                    onFocusChanged = { focused -> inputFocused = focused },
                    isGenerating = uiState.generationState.isGenerating,
                    onStop = { viewModel.stopGeneration() },
                )
                ChatContextBar(
                    state = contextBarState,
                    availableModels = LlmModel.all(),
                    onModelSwitch = { model ->
                        haptics.medium()
                        viewModel.switchModel(model)
                    },
                    enabled = uiState.isInputEnabled,
                )
            }

            // Error dialog — haptic on appear
            uiState.error?.let { error ->
                LaunchedEffect(error) {
                    haptics.error()
                }
                ErrorSnackbar(
                    error = error,
                    onDismiss = {
                        haptics.light()
                        viewModel.clearError()
                    },
                )
            }

            // Clear conversation dialog
            if (showClearDialog) {
                ClearConversationDialog(
                    messageCount = uiState.messages.size,
                    onConfirm = {
                        haptics.strong()
                        viewModel.clearConversation()
                        showClearDialog = false
                    },
                    onDismiss = {
                        haptics.light()
                        showClearDialog = false
                    },
                )
            }
        }
    }

    // Expose clear callback to parent (legacy hook — parent may show its own dialog)
    LaunchedEffect(onClearConversationClick) {
        // This registers the callback - when parent calls it, we show the dialog
    }
}

/**
 * Error Snackbar - Shows error messages.
 */
@Composable
private fun ErrorSnackbar(
    error: ChatError,
    onDismiss: () -> Unit,
) {
    Snackbar(
        modifier = Modifier.padding(16.dp),
        action = {
            TextButton(onClick = onDismiss) {
                Text("Dismiss", color = MaColors.White)
            }
        },
        containerColor = MaColors.Error,
        contentColor = MaColors.White,
    ) {
        Text("${error.toEmoji()} ${error.toUserMessage()}")
    }
}

/**
 * ChatBubble - Renders a single message bubble or status card.
 */
@Composable
fun ChatBubble(
    message: ChatMessage,
    onSpeak: ((String) -> Unit)? = null,
    isStreaming: Boolean = false,
    isThinking: Boolean = false,
) {
    when {
        // No welcome/status card — chat shows messages, nothing else
        // (macos/docs/DESIGN_DOCTRINE.md principle 7). `isStatusMessage`
        // is never set anymore (see ChatScreenViewModel.primeSystemPrompt);
        // an old persisted status row just falls through and renders as a
        // plain assistant bubble rather than vanishing.
        message.isUser -> {
            MaChatBubbleUser(
                text = message.text,
                timestamp = message.timestamp,
            )
        }

        else -> {
            MaChatBubbleAI(
                text = message.text,
                timestamp = message.timestamp,
                inferenceStats = message.inferenceStats,
                isError = message.isError,
                ragSources = message.ragSources,
                onSpeak =
                    if (onSpeak != null) {
                        { onSpeak(message.text) }
                    } else {
                        null
                    },
                artifactContent =
                    message.artifact?.let { artifact ->
                        { ArtifactView(artifact = artifact) }
                    },
                thinkingPill =
                    if (!message.thinkingContent.isNullOrEmpty() || isThinking) {
                        {
                            ThinkingPill(
                                thinkingContent = message.thinkingContent,
                                isThinking = isThinking,
                                thinkingDurationMs = message.thinkingDurationMs,
                                modifier = Modifier.padding(bottom = 4.dp),
                            )
                        }
                    } else {
                        null
                    },
                toolCallsPill =
                    if (message.toolResults.isNotEmpty()) {
                        {
                            ToolCallPill(
                                toolResults = message.toolResults,
                                isExecuting = false,
                                modifier = Modifier.padding(bottom = 4.dp),
                            )
                        }
                    } else {
                        null
                    },
                isStreaming = isStreaming,
            )
        }
    }
}

/**
 * Download progress overlay for large model downloads.
 */
@Composable
private fun ModelDownloadOverlay(
    state: ModelDownloadState,
    modifier: Modifier = Modifier,
) {
    Row(
        modifier =
            modifier
                .fillMaxWidth()
                .padding(horizontal = 16.dp)
                .background(
                    color = MaColors.bgElevated(),
                    shape = RoundedCornerShape(12.dp),
                ).border(
                    width = 1.dp,
                    color = MaColors.OrangeDim,
                    shape = RoundedCornerShape(12.dp),
                ).padding(16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        when (state) {
            is ModelDownloadState.Starting -> {
                CircularProgressIndicator(
                    modifier = Modifier.size(24.dp),
                    color = MaColors.Orange,
                    strokeWidth = 2.dp,
                )
                Text(
                    "Preparing ${state.modelName}...",
                    style = app.m1k3.ai.assistant.design.tokens.MaTypography.bodyMedium,
                    color = MaColors.textPrimary(),
                )
            }

            is ModelDownloadState.InProgress -> {
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        "Downloading ${state.modelName}",
                        style = app.m1k3.ai.assistant.design.tokens.MaTypography.bodyMedium,
                        color = MaColors.textPrimary(),
                    )
                    Spacer(Modifier.size(4.dp))
                    LinearProgressIndicator(
                        progress = { state.progressPercent / 100f },
                        modifier = Modifier.fillMaxWidth(),
                        color = MaColors.Orange,
                        trackColor = MaColors.bgSecondary(),
                    )
                    Text(
                        "${state.downloadedMB}MB / ${state.totalMB}MB (${state.progressPercent}%)",
                        style = app.m1k3.ai.assistant.design.tokens.MaTypography.labelSmall,
                        color = MaColors.textMuted(),
                    )
                }
            }

            is ModelDownloadState.Complete -> {
                Text(
                    "${state.modelName} ready!",
                    style = app.m1k3.ai.assistant.design.tokens.MaTypography.bodyMedium,
                    color = MaColors.Success,
                )
            }

            is ModelDownloadState.Failed -> {
                Text(
                    "Download failed: ${state.error}",
                    style = app.m1k3.ai.assistant.design.tokens.MaTypography.bodyMedium,
                    color = MaColors.Error,
                )
            }
        }
    }
}

// ============================================================
// Previews
// ============================================================

@Preview
@Composable
private fun ChatScreenEmptyPreview() {
    MaTheme {
        Box(
            modifier =
                Modifier
                    .fillMaxSize()
                    .background(MaColors.BgPrimary),
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                ChatMessageList(
                    messages = emptyList(),
                    isGenerating = false,
                    listState = rememberLazyListState(),
                )
            }

            ChatInputBarContainer(
                inputBar = {
                    ChatInputBar(
                        text = "",
                        onTextChange = {},
                        onSend = {},
                        enabled = true,
                    )
                },
                modifier = Modifier.align(Alignment.BottomCenter),
            )
        }
    }
}

@Preview
@Composable
private fun ChatScreenWithMessagesPreview() {
    MaTheme {
        Box(
            modifier =
                Modifier
                    .fillMaxSize()
                    .background(MaColors.BgPrimary),
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                ChatMessageList(
                    messages =
                        listOf(
                            ChatMessage(
                                text = "What is machine learning?",
                                isUser = true,
                                timestamp = System.currentTimeMillis(),
                            ),
                            ChatMessage(
                                text = "Machine learning is a subset of artificial intelligence that enables systems to learn and improve from experience without being explicitly programmed.",
                                isUser = false,
                                timestamp = System.currentTimeMillis(),
                                inferenceStats = "⚡ 42 tokens in 2.3s",
                            ),
                        ),
                    isGenerating = false,
                    listState = rememberLazyListState(),
                )
            }

            ChatInputBarContainer(
                inputBar = {
                    ChatInputBar(
                        text = "",
                        onTextChange = {},
                        onSend = {},
                        enabled = true,
                    )
                },
                modifier = Modifier.align(Alignment.BottomCenter),
            )
        }
    }
}

@Preview
@Composable
private fun ChatScreenGeneratingPreview() {
    MaTheme {
        Box(
            modifier =
                Modifier
                    .fillMaxSize()
                    .background(MaColors.BgPrimary),
        ) {
            Column(modifier = Modifier.fillMaxSize()) {
                ContextWindowIndicator(
                    state =
                        ContextWindowState(
                            historyMessageCount = 5,
                            historyTokens = 500,
                            maxContextTokens = 4096,
                            deviceTier = "High-end",
                        ),
                )

                ChatMessageList(
                    messages =
                        listOf(
                            ChatMessage(
                                text = "Explain quantum computing",
                                isUser = true,
                                timestamp = System.currentTimeMillis(),
                            ),
                        ),
                    isGenerating = true,
                    listState = rememberLazyListState(),
                )
            }

            ChatInputBarContainer(
                inputBar = {
                    ChatInputBar(
                        text = "",
                        onTextChange = {},
                        onSend = {},
                        enabled = false,
                    )
                },
                modifier = Modifier.align(Alignment.BottomCenter),
            )
        }
    }
}
