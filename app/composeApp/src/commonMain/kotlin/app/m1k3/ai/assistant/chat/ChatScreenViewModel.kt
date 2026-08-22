package app.m1k3.ai.assistant.chat

import androidx.compose.runtime.Composable
import androidx.compose.runtime.State
import androidx.compose.runtime.collectAsState
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import app.m1k3.ai.assistant.ai.BaseLlmEngine
import app.m1k3.ai.assistant.chat.usecase.ChatWithToolsUseCase
import app.m1k3.ai.assistant.chat.usecase.ContextRetrievalUseCase
import app.m1k3.ai.assistant.database.MaDatabase
import app.m1k3.ai.assistant.history.ConversationRepository
import app.m1k3.ai.assistant.memory.MemoryManager
import app.m1k3.ai.assistant.platform.DeviceInfoProviderInterface
import app.m1k3.ai.assistant.platform.PreferenceKeys
import app.m1k3.ai.assistant.platform.PreferencesStoreInterface
import app.m1k3.ai.assistant.platform.getDeviceTier
import app.m1k3.ai.assistant.utils.Logger
import app.m1k3.ai.domain.ai.LlmModel
import app.m1k3.ai.domain.chat.ChatError
import app.m1k3.ai.domain.chat.EnrichedContext
import app.m1k3.ai.domain.chat.GenerationStats
import app.m1k3.ai.domain.chat.StreamingThinkTagParser
import app.m1k3.ai.domain.chat.events.ChatEvent
import app.m1k3.ai.domain.chat.format.ChatFormat
import app.m1k3.ai.domain.chat.services.ContextAssembler
import app.m1k3.ai.domain.chat.services.DefaultChatFormatter
import app.m1k3.ai.domain.chat.services.DeviceContextFormatter
import app.m1k3.ai.domain.chat.services.UnifiedPromptBuilder
import app.m1k3.ai.domain.history.UNTITLED_CONVERSATION_TITLE
import app.m1k3.ai.domain.platform.DateTimeProviderInterface
import app.m1k3.ai.domain.platform.DeviceContext
import app.m1k3.ai.domain.system.MaSystemPromptBuilder
import app.m1k3.ai.domain.system.SystemPromptInput
import app.m1k3.ai.domain.system.SystemPromptTier
import app.m1k3.ai.domain.tools.ToolResult
import app.m1k3.ai.domain.tools.services.ToolRegistry
import app.m1k3.ai.domain.usecases.chat.LlmOutputProcessor
import app.m1k3.ai.domain.voice.SpeechTextPolish
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import kotlin.time.Clock

private val logger = Logger.withTag("ChatScreenViewModel")

/**
 * ChatScreenViewModel - Manages ChatScreen UI state with MVVM architecture.
 *
 * This ViewModel consolidates all state management previously scattered across
 * ChatScreen.kt's 12+ responsibilities into a single, testable class.
 *
 * **Architecture (MVVM with Use Cases):**
 * - Single StateFlow for all UI state (ChatUiState)
 * - Delegates to use cases for business logic:
 *   - ContextRetrievalUseCase: RAG + memory retrieval
 *   - GenerationConfigBuilder: Device-adaptive config
 * - Handles side effects: database, state updates
 *
 * **Responsibilities:**
 * - UI state management via ChatUiState
 * - AI engine initialization
 * - Coordinating message flow with use cases
 * - Error handling
 */
class ChatScreenViewModel(
    private var aiEngine: BaseLlmEngine,
    private val conversationRepo: ConversationRepository,
    private val database: MaDatabase,
    private val deviceInfo: DeviceInfoProviderInterface,
    private val preferences: PreferencesStoreInterface,
    private val projectId: String = "",
    private val memoryManager: MemoryManager? = null,
    private val passageRetriever: app.m1k3.ai.domain.passages.usecases.RetrievePassagesUseCase? = null,
    // Tool calling support (optional - when provided, enables agentic capabilities)
    private val toolRegistry: ToolRegistry? = null,
    private val processLlmOutput: LlmOutputProcessor? = null,
    // DateTime provider for context-aware prompts (optional for backwards compatibility)
    private val dateTimeProvider: DateTimeProviderInterface? = null,
    // Engine factory for runtime model switching (optional)
    private val engineFactory: ((LlmModel) -> BaseLlmEngine)? = null,
    // Model download check (platform-injected, optional — for large downloadable models)
    private val isModelDownloaded: ((LlmModel) -> Boolean)? = null,
    // Model download trigger (platform-injected, optional)
    private val downloadModel: ((LlmModel, (ModelDownloadState) -> Unit) -> Unit)? = null,
    /** Deletes a model's weights from disk — the retry path after a file that downloaded but won't load. */
    private val deleteModel: ((LlmModel) -> Boolean)? = null,
    // TTS callbacks (platform-injected, optional)
    private val onSpeakText: (suspend (String) -> Unit)? = null,
    // User's first name for a personalised welcome (platform-injected, optional)
    private val userNameProvider: (() -> String?)? = null,
    // Tool execution history (optional — logs every tool call for analytics)
    private val toolExecutionDataSource: app.m1k3.ai.assistant.tools.ToolExecutionDataSource? = null,
    // The brain actually loaded into [aiEngine] (platform-injected). Without
    // this, ChatUiState's default (LlmModel.default = Lil) is what Settings'
    // Brain section shows as selected — regardless of which tier onboarding
    // actually installed and this engine actually loaded.
    private val initialModel: LlmModel = LlmModel.default,
) : ViewModel() {
    // ===== Use Cases (lazy initialization) =====

    private val contextRetrieval: ContextRetrievalUseCase by lazy {
        ContextRetrievalUseCase(
            deviceInfo = deviceInfo,
            preferences = preferences,
            database = database,
            projectId = projectId,
            memoryManager = memoryManager,
            passageRetriever = passageRetriever,
        )
    }

    private val configBuilder: GenerationConfigBuilder by lazy {
        GenerationConfigBuilder(deviceInfo)
    }

    /**
     * DeviceContextFormatter for prompt enrichment.
     */
    private val deviceContextFormatter = DeviceContextFormatter()

    /**
     * UnifiedPromptBuilder for consistent prompt formatting.
     * Rebuilt on model switch to use the correct ChatFormat.
     */
    private var promptBuilder: UnifiedPromptBuilder = createPromptBuilder(LlmModel.default.chatFormat)

    private fun createPromptBuilder(format: ChatFormat): UnifiedPromptBuilder {
        val formatter = DefaultChatFormatter(format)
        val assembler = ContextAssembler()
        return UnifiedPromptBuilder(formatter, assembler, deviceContextFormatter)
    }

    /**
     * ChatWithToolsUseCase for agentic capabilities.
     * Only created when tool dependencies are provided AND tools are enabled in preferences.
     * Rebuilt on model switch to use the updated engine and prompt builder.
     */
    private var chatWithTools: ChatWithToolsUseCase? = createChatWithTools()

    private fun createChatWithTools(): ChatWithToolsUseCase? {
        val toolsEnabled = preferences.getBoolean(PreferenceKeys.TOOLS_ENABLED, true)
        return if (toolsEnabled && toolRegistry != null && processLlmOutput != null) {
            ChatWithToolsUseCase(
                aiEngine = aiEngine,
                contextRetrieval = contextRetrieval,
                processLlmOutput = processLlmOutput,
                toolRegistry = toolRegistry,
                configBuilder = configBuilder,
                promptBuilder = promptBuilder,
                webSearchEnabled = { preferences.getBoolean(PreferenceKeys.WEB_SEARCH_ENABLED, true) },
            )
        } else {
            null
        }
    }

    /** Whether tool calling is enabled */
    val isToolCallingEnabled: Boolean
        get() = chatWithTools != null

    /** System prompt builder — builds tiered M1K3 personality prompts */
    private val systemPromptBuilder = MaSystemPromptBuilder()

    /**
     * Compact system prompt — built once after context is loaded, injected
     * into every message. COMPACT tier to preserve context window budget.
     */
    private var compactSystemPrompt: String? = null

    // Track confirmed tools for re-execution
    private val confirmedToolIds = mutableSetOf<String>()

    // ===== State =====

    private val _uiState = MutableStateFlow(ChatUiState(currentModel = initialModel))
    val uiState: StateFlow<ChatUiState> = _uiState.asStateFlow()

    // Session tracking
    private var currentConversationId: Long? = null

    init {
        loadMessages()
        initializeConversation()
        loadAutoVoiceReplyPreference()
    }

    // ===== Public Actions =====

    /**
     * Initialize the AI engine.
     * Call this from LaunchedEffect(Unit) in the composable.
     */

    /**
     * Retry engine initialization — called from the "Re-download" / "Retry" button
     * shown when EngineState.Failed. Resets state to Loading and re-runs init.
     */
    fun retryEngineInit() {
        aiEngine.release()
        _uiState.update { it.copy(engineState = EngineState.Loading, error = null) }
        val model = _uiState.value.currentModel
        val factory = engineFactory
        // A file that downloaded but won't load is the common case here (a bad
        // conversion, a torn write). Re-running init on the same bytes can't help —
        // throw the file away and fetch it again when we have the means to.
        if (factory != null && downloadModel != null) {
            deleteModel?.invoke(model) // false = nothing on disk, which also wants a download
            startModelDownload(model, factory)
            return
        }
        initializeEngine(force = true)
    }

    fun initializeEngine(force: Boolean = false) {
        // An init already in flight counts as done: ChatScreen's LaunchedEffect
        // re-enters whenever the Failed branch flips back to Loading, which used to
        // fire a second load on top of every retry (two loads per tap on the Pixel).
        // (Can't key this off EngineState.Loading — that's also the initial state.)
        if (!force && (_uiState.value.engineState is EngineState.Ready || engineInitInFlight)) {
            logger.d { "Engine already initialized or initializing" }
            return
        }
        engineInitInFlight = true

        viewModelScope.launch {
            try {
                logger.i { "Initializing AI engine..." }
                _uiState.update { it.copy(engineState = EngineState.Loading) }

                val result = aiEngine.initialize()

                result
                    .onSuccess {
                        _uiState.update { it.copy(engineState = EngineState.Ready) }
                        logger.i { "AI engine ready" }

                        if (_uiState.value.messages.isEmpty()) {
                            primeSystemPrompt()
                        }
                    }.onFailure { e ->
                        val error = ChatError.EngineInitError(e.message ?: "Initialization failed")
                        _uiState.update { it.copy(engineState = EngineState.Failed(error)) }
                        logger.e(e) { "Engine initialization failed" }
                    }
            } catch (e: Exception) {
                logger.e(e) { "Failed to initialize AI engine" }
                val error = mapExceptionToError(e)
                _uiState.update { it.copy(engineState = EngineState.Failed(error)) }
            } finally {
                engineInitInFlight = false
            }
        }
    }

    private var engineInitInFlight = false

    /**
     * Update the input text field.
     */
    fun updateInputText(text: String) {
        _uiState.update { it.copy(inputText = text) }
    }

    /**
     * Send a message and generate AI response.
     */
    fun sendMessage() {
        val inputText = _uiState.value.inputText.trim()
        if (inputText.isBlank()) return
        if (_uiState.value.generationState.isGenerating) return

        viewModelScope.launch {
            try {
                // Clear input and add user message
                val userMessage =
                    ChatMessage(
                        text = inputText,
                        isUser = true,
                        timestamp = Clock.System.now().toEpochMilliseconds(),
                    )

                _uiState.update {
                    it.copy(
                        inputText = "",
                        messages = it.messages + userMessage,
                        generationState = GenerationState.Thinking,
                        error = null,
                    )
                }

                // Record user message
                recordMessage(inputText, "user", 0)

                // Generate AI response
                generateResponse(inputText)
            } catch (e: Exception) {
                logger.e(e) { "Failed to send message" }
                val error = mapExceptionToError(e)
                _uiState.update {
                    it.copy(
                        generationState = GenerationState.Failed(error),
                        error = error,
                    )
                }
            }
        }
    }

    /**
     * Clear the current error.
     */
    fun clearError() {
        _uiState.update { it.copy(error = null) }
    }

    /**
     * Switch the active LLM model.
     *
     * Releases the current engine, creates a new one via the factory,
     * and re-initializes. Disables input during the switch.
     */
    fun switchModel(model: LlmModel) {
        val factory =
            engineFactory ?: run {
                logger.w { "No engine factory, cannot switch models" }
                return
            }

        if (model == _uiState.value.currentModel) return
        if (_uiState.value.generationState.isGenerating) return

        // Check if model needs downloading (large models like Gemma 4)
        if (model.minRamGB > 0 && isModelDownloaded?.invoke(model) == false) {
            logger.i { "Model ${model.displayName} needs download" }
            startModelDownload(model, factory)
            return
        }

        performModelSwitch(model, factory)
    }

    /**
     * Start downloading a model, then switch to it on completion.
     */
    private fun startModelDownload(
        model: LlmModel,
        factory: (LlmModel) -> BaseLlmEngine,
    ) {
        val download =
            downloadModel ?: run {
                logger.w { "No download function, cannot download ${model.displayName}" }
                return
            }

        _uiState.update {
            it.copy(modelDownload = ModelDownloadState.Starting(model.displayName))
        }

        download(model) { state ->
            _uiState.update { it.copy(modelDownload = state) }

            if (state is ModelDownloadState.Complete) {
                // Download finished — now switch
                performModelSwitch(model, factory)
                _uiState.update { it.copy(modelDownload = null) }
            } else if (state is ModelDownloadState.Failed) {
                // Clear download state after a delay
                viewModelScope.launch {
                    kotlinx.coroutines.delay(3000)
                    _uiState.update { it.copy(modelDownload = null) }
                }
            }
        }
    }

    /**
     * Perform the actual model switch (release old, create new, init).
     */
    private fun performModelSwitch(
        model: LlmModel,
        factory: (LlmModel) -> BaseLlmEngine,
    ) {
        viewModelScope.launch {
            try {
                logger.i { "Switching model to ${model.displayName}" }
                _uiState.update {
                    it.copy(
                        currentModel = model,
                        engineState = EngineState.Loading,
                    )
                }

                // Release old engine
                aiEngine.release()

                // Create and initialize new engine
                aiEngine = factory(model)

                // Rebuild prompt builder and tools for new model's chat format
                promptBuilder = createPromptBuilder(model.chatFormat)
                chatWithTools = createChatWithTools()

                val result = aiEngine.initialize()

                result
                    .onSuccess {
                        _uiState.update { it.copy(engineState = EngineState.Ready) }
                        logger.i { "Switched to ${model.displayName}" }
                        // Clear and regenerate welcome with new model
                        clearConversation()
                    }.onFailure { e ->
                        val error = ChatError.EngineInitError("Failed to load ${model.displayName}: ${e.message}")
                        _uiState.update { it.copy(engineState = EngineState.Failed(error), error = error) }
                        logger.e(e) { "Model switch failed" }
                    }
            } catch (e: Exception) {
                logger.e(e) { "Model switch error" }
                _uiState.update {
                    it.copy(
                        engineState = EngineState.Failed(mapExceptionToError(e)),
                        error = mapExceptionToError(e),
                    )
                }
            }
        }
    }

    /**
     * Send text from an external share intent.
     *
     * Bypasses the input field — adds user message and generates response immediately.
     */
    fun sendSharedText(text: String) {
        val trimmed = text.trim()
        if (trimmed.isBlank()) return
        if (_uiState.value.generationState.isGenerating) return

        viewModelScope.launch {
            val userMessage =
                ChatMessage(
                    text = trimmed,
                    isUser = true,
                    timestamp = Clock.System.now().toEpochMilliseconds(),
                )

            _uiState.update {
                it.copy(
                    messages = it.messages + userMessage,
                    generationState = GenerationState.Thinking,
                    error = null,
                )
            }

            recordMessage(trimmed, "user", 0)
            generateResponse(trimmed)
        }
    }

    /**
     * Synthesize and play speech for a message.
     *
     * Uses the platform-injected TTS callback.
     */
    fun speakMessage(text: String) {
        val speak =
            onSpeakText ?: run {
                logger.w { "TTS not available" }
                return
            }

        viewModelScope.launch {
            try {
                _uiState.update { it.copy(isLoadingTts = true, isSpeaking = true) }
                speak(SpeechTextPolish.polish(text).ifBlank { text })
            } catch (e: Exception) {
                logger.e(e) { "TTS playback failed" }
            } finally {
                _uiState.update { it.copy(isLoadingTts = false, isSpeaking = false) }
            }
        }
    }

    /**
     * Toggle auto voice reply on/off.
     *
     * Persists preference and updates UI state.
     */
    fun toggleAutoVoiceReply() {
        val newValue = !_uiState.value.autoVoiceReply
        preferences.setBoolean(PreferenceKeys.VOICE_AUTO_REPLY, newValue)
        _uiState.update { it.copy(autoVoiceReply = newValue) }
        logger.i { "Auto voice reply: $newValue" }
    }

    /**
     * Load auto voice reply preference from storage.
     */
    private fun loadAutoVoiceReplyPreference() {
        val enabled = preferences.getBoolean(PreferenceKeys.VOICE_AUTO_REPLY, false)
        _uiState.update { it.copy(autoVoiceReply = enabled) }
    }

    /**
     * Auto-speak the completed response if auto voice reply is enabled.
     *
     * Called after generation completes. Checks shouldAutoSpeak guard.
     */
    private fun autoSpeakIfEnabled() {
        val state = _uiState.value
        if (!state.shouldAutoSpeak) return

        val finalText = (state.generationState as? GenerationState.Complete)?.finalText ?: return
        speakMessage(finalText)
    }

    /**
     * Clear all conversation history.
     */
    fun clearConversation() {
        viewModelScope.launch {
            try {
                logger.i { "Clearing conversation for project: $projectId" }

                database.messageQueries.deleteMessagesForProject(projectId)

                val conversations = conversationRepo.getConversationsByProject(projectId)
                conversations.forEach { conv ->
                    conversationRepo.deleteConversation(conv.id)
                }

                _uiState.update {
                    it.copy(
                        messages = emptyList(),
                        error = null,
                        toolState = ToolState(),
                    )
                }

                currentConversationId = null
                confirmedToolIds.clear()
                initializeConversation()
                primeSystemPrompt() // re-prime on new chat

                logger.i { "Conversation cleared" }
            } catch (e: Exception) {
                logger.e(e) { "Failed to clear conversation" }
                _uiState.update {
                    it.copy(error = ChatError.Unknown("Failed to clear: ${e.message}"))
                }
            }
        }
    }

    /**
     * Confirm a pending tool execution.
     *
     * @param confirmationId The ID of the confirmation to approve
     */
    fun confirmTool(confirmationId: String) {
        val confirmation =
            _uiState.value.toolState.pendingConfirmations
                .find { it.id == confirmationId }
        if (confirmation == null) {
            logger.w { "Confirmation not found: $confirmationId" }
            return
        }

        logger.i { "User confirmed tool: ${confirmation.toolId}" }
        confirmedToolIds.add(confirmation.toolId)

        // Remove from pending and re-execute
        _uiState.update { state ->
            state.copy(
                toolState =
                    state.toolState.copy(
                        pendingConfirmations = state.toolState.pendingConfirmations.filter { it.id != confirmationId },
                    ),
            )
        }

        // Re-send the last user message to trigger tool execution
        val lastUserMessage = _uiState.value.messages.lastOrNull { it.isUser }
        if (lastUserMessage != null) {
            viewModelScope.launch {
                generateResponseWithTools(lastUserMessage.text)
            }
        }
    }

    /**
     * Deny a pending tool execution.
     *
     * @param confirmationId The ID of the confirmation to deny
     */
    fun denyTool(confirmationId: String) {
        val confirmation =
            _uiState.value.toolState.pendingConfirmations
                .find { it.id == confirmationId }
        if (confirmation == null) {
            logger.w { "Confirmation not found: $confirmationId" }
            return
        }

        logger.i { "User denied tool: ${confirmation.toolId}" }

        // Remove from pending
        _uiState.update { state ->
            state.copy(
                toolState =
                    state.toolState.copy(
                        pendingConfirmations = state.toolState.pendingConfirmations.filter { it.id != confirmationId },
                    ),
                generationState = GenerationState.Idle,
            )
        }
    }

    // ===== Internal Methods =====

    private fun loadMessages() {
        viewModelScope.launch {
            try {
                val dbMessages =
                    database.messageQueries
                        .getMessagesForProject(projectId)
                        .executeAsList()

                val chatMessages =
                    dbMessages.map { msg ->
                        ChatMessage(
                            text = msg.content,
                            isUser = msg.role == "user",
                            timestamp = msg.timestamp,
                            isError = false,
                            inferenceStats = msg.tokens?.let { "⚡ $it tokens" },
                            ragSources = msg.rag_sources,
                        )
                    }

                _uiState.update { it.copy(messages = chatMessages) }
                logger.i { "Loaded ${chatMessages.size} messages" }
            } catch (e: Exception) {
                logger.e(e) { "Failed to load messages" }
            }
        }
    }

    private fun initializeConversation() {
        viewModelScope.launch {
            try {
                currentConversationId =
                    conversationRepo.createConversation(
                        projectId = projectId,
                        title = UNTITLED_CONVERSATION_TITLE,
                    )
            } catch (e: Exception) {
                logger.e(e) { "Failed to create conversation" }
            }
        }
    }

    /**
     * Build and install the system prompt M1K3 uses for every real turn in
     * this conversation. No LLM call, no message added to the transcript.
     *
     * This used to be `generateWelcomeMessage()`: building the prompt was a
     * side effect of also having the model generate a spoken self-intro
     * ("Good morning, M1K3. I'm here...") — the model greeting itself, on
     * an "empty" chat that was never actually empty. iOS has no welcome
     * generation; the hero face + starter chips ARE the empty state
     * (doctrine: chat shows messages, nothing else).
     */
    private suspend fun primeSystemPrompt() {
        // Guard: don't attempt if engine isn't ready (race during model switch)
        if (_uiState.value.engineState != EngineState.Ready) {
            logger.w { "Skipping system-prompt priming — engine not ready (${_uiState.value.engineState})" }
            return
        }

        // Fetch the user's name so replies can be personalised.
        val userName =
            try {
                userNameProvider?.invoke()
            } catch (_: Exception) {
                null
            }
        if (userName != null) {
            _uiState.update { it.copy(userName = userName) }
        }

        val deviceTier = deviceInfo.getDeviceTier()
        // Context window scales with device tier
        val maxContextTokens =
            when (deviceTier) {
                app.m1k3.ai.domain.platform.DeviceTier.FLAGSHIP -> 8192
                app.m1k3.ai.domain.platform.DeviceTier.HIGH_END -> 6144
                app.m1k3.ai.domain.platform.DeviceTier.MID_RANGE -> 4096
                else -> 2048
            }

        try {
            val dayOfWeek = dateTimeProvider?.getDayOfWeekName()
            val currentDate = dateTimeProvider?.getFormattedDate()
            val promptInput =
                SystemPromptInput(
                    tier = SystemPromptTier.COMPACT,
                    userName = userName,
                    dayOfWeek = dayOfWeek,
                    currentDate = currentDate,
                    deviceTierName = deviceTier.name.lowercase().replaceFirstChar { it.uppercase() },
                    contextWindowTokens = maxContextTokens,
                    // Artifacts are a Big-tier capability (see SystemPromptInput.teachesArtifacts).
                    teachesArtifacts = _uiState.value.currentModel == LlmModel.Gemma4_E2B,
                    availableTools =
                        if (chatWithTools != null) {
                            toolRegistry?.getAllTools()?.map { it.id } ?: emptyList()
                        } else {
                            emptyList()
                        },
                )
            compactSystemPrompt = systemPromptBuilder.build(promptInput)
            chatWithTools?.systemPrompt = compactSystemPrompt ?: ""
            logger.i { "System prompt primed (${compactSystemPrompt?.length ?: 0} chars)" }
        } catch (e: Exception) {
            logger.e(e) { "Failed to prime system prompt" }
        }
    }

    private suspend fun generateResponse(prompt: String) {
        // Use ChatWithToolsUseCase if available for agentic capabilities
        if (chatWithTools != null) {
            generateResponseWithTools(prompt)
            return
        }

        // Legacy path: direct AI generation without tool support
        val placeholderMessage =
            ChatMessage(
                text = "",
                isUser = false,
                timestamp = Clock.System.now().toEpochMilliseconds(),
            )

        _uiState.update {
            it.copy(messages = it.messages + placeholderMessage)
        }

        try {
            // Use ContextRetrievalUseCase for context building
            val context = contextRetrieval.retrieveContext(prompt)

            // Update context window state for UI display
            updateContextWindowState(context)

            // Use GenerationConfigBuilder for device-adaptive config
            val config = configBuilder.buildFromIntent(context.intentCategory)

            // Build device context for context-aware prompts
            val deviceTier = deviceInfo.getDeviceTier()
            val deviceContext =
                dateTimeProvider?.let { dtProvider ->
                    DeviceContext.from(
                        dateTimeProvider = dtProvider,
                        deviceInfoProvider = deviceInfo,
                        deviceTier = deviceTier,
                    )
                }

            val thinkParser = StreamingThinkTagParser()
            var tokenCount = 0
            val startTime = Clock.System.now().toEpochMilliseconds()

            // Build full prompt with context using UnifiedPromptBuilder
            val fullPrompt =
                promptBuilder.build(
                    userPrompt = prompt,
                    context = context,
                    tools = emptyList(), // Legacy path has no tools
                    systemPrompt = compactSystemPrompt ?: "",
                    deviceContext = deviceContext,
                )

            val result =
                aiEngine.generateStreaming(
                    prompt = fullPrompt,
                    config = config,
                    onToken = { token ->
                        if (token.isNotEmpty()) {
                            thinkParser.feed(token)
                            tokenCount++

                            _uiState.update { state ->
                                val updatedMessages = state.messages.toMutableList()
                                if (updatedMessages.isNotEmpty()) {
                                    updatedMessages[updatedMessages.lastIndex] =
                                        updatedMessages.last().copy(
                                            text = thinkParser.visibleText,
                                            thinkingContent = thinkParser.thinkingContent,
                                        )
                                }
                                state.copy(
                                    messages = updatedMessages,
                                    generationState =
                                        GenerationState.Streaming(
                                            partialText = thinkParser.visibleText,
                                            tokenCount = tokenCount,
                                            thinkingPartial = thinkParser.thinkingContent,
                                            isThinking = thinkParser.isThinking,
                                        ),
                                )
                            }
                        }
                    },
                )

            result
                .onSuccess {
                    handleGenerationSuccess(thinkParser, tokenCount, startTime, context)
                }.onFailure { e ->
                    handleGenerationFailure(e)
                }
        } catch (e: Exception) {
            handleGenerationFailure(e)
        }
    }

    /**
     * Generate response using ChatWithToolsUseCase for agentic capabilities.
     * Handles tool execution, confirmations, and result display.
     */
    private suspend fun generateResponseWithTools(prompt: String) {
        val useCase =
            chatWithTools ?: run {
                logger.w { "ChatWithToolsUseCase not available, falling back to legacy path" }
                return
            }

        // Build device context for context-aware prompts
        val deviceTier = deviceInfo.getDeviceTier()
        val deviceContext =
            dateTimeProvider?.let { dtProvider ->
                DeviceContext.from(
                    dateTimeProvider = dtProvider,
                    deviceInfoProvider = deviceInfo,
                    deviceTier = deviceTier,
                )
            }

        val placeholderMessage =
            ChatMessage(
                text = "",
                isUser = false,
                timestamp = Clock.System.now().toEpochMilliseconds(),
            )

        _uiState.update {
            it.copy(
                messages = it.messages + placeholderMessage,
                toolState = it.toolState.copy(isExecuting = false),
            )
        }

        try {
            useCase.execute(prompt, confirmedToolIds, deviceContext).collect { event ->
                when (event) {
                    is ChatEvent.Started -> {
                        _uiState.update { it.copy(generationState = GenerationState.Thinking) }
                    }

                    is ChatEvent.RetrievingContext -> {
                        // Keep thinking state while retrieving context
                    }

                    is ChatEvent.ContextRetrieved -> {
                        updateContextWindowState(event.context)
                    }

                    is ChatEvent.Generating -> {
                        // Keep thinking state while generating
                    }

                    is ChatEvent.Streaming -> {
                        _uiState.update { state ->
                            val updatedMessages = state.messages.toMutableList()
                            if (updatedMessages.isNotEmpty()) {
                                updatedMessages[updatedMessages.lastIndex] =
                                    updatedMessages.last().copy(
                                        text = event.partialText,
                                        // Show live thinking content during streaming
                                        thinkingContent = event.thinkingPartial,
                                    )
                            }
                            state.copy(
                                messages = updatedMessages,
                                generationState =
                                    GenerationState.Streaming(
                                        partialText = event.partialText,
                                        tokenCount = event.tokenCount,
                                        thinkingPartial = event.thinkingPartial,
                                        isThinking = event.isThinking,
                                    ),
                            )
                        }
                    }

                    is ChatEvent.ToolsExecuted -> {
                        handleToolsExecuted(event)
                        persistToolExecutions(event.results, prompt)
                    }

                    is ChatEvent.Complete -> {
                        handleToolsComplete(event)
                    }

                    is ChatEvent.Failed -> {
                        val chatError = event.error
                        _uiState.update { state ->
                            val updatedMessages = state.messages.dropLast(1)
                            state.copy(
                                messages = updatedMessages,
                                generationState = GenerationState.Failed(chatError),
                                error = chatError,
                                toolState = state.toolState.copy(isExecuting = false),
                            )
                        }
                    }
                }
            }
        } catch (e: Exception) {
            handleGenerationFailure(e)
        }
    }

    private fun handleToolsExecuted(event: ChatEvent.ToolsExecuted) {
        val executedResults =
            event.results.map { result ->
                when (result) {
                    is ToolResult.Success -> {
                        ToolExecutionResult(
                            toolId = result.toolId,
                            displayResult = result.output,
                            isSuccess = true,
                        )
                    }

                    is ToolResult.Failure -> {
                        ToolExecutionResult(
                            toolId = result.toolId,
                            displayResult = result.error.displayMessage,
                            isSuccess = false,
                            errorMessage = result.error.displayMessage,
                        )
                    }

                    is ToolResult.RequiresConfirmation -> {
                        ToolExecutionResult(
                            toolId = result.toolId,
                            displayResult = "Awaiting confirmation",
                            isSuccess = false,
                        )
                    }
                }
            }

        val pendingConfirmations =
            event.results
                .filterIsInstance<ToolResult.RequiresConfirmation>()
                .map { result ->
                    ToolConfirmation(
                        id = "confirm_${result.toolId}_${Clock.System.now().toEpochMilliseconds()}",
                        toolId = result.toolId,
                        toolName = result.toolId.replace("_", " ").replaceFirstChar { it.uppercase() },
                        description = result.confirmationPrompt,
                        arguments = result.pendingCall.arguments,
                    )
                }

        _uiState.update { state ->
            state.copy(
                toolState =
                    ToolState(
                        pendingConfirmations = pendingConfirmations,
                        executedTools = executedResults,
                        isExecuting = false,
                    ),
            )
        }

        logger.i { "Tools executed: ${executedResults.size}, pending confirmations: ${pendingConfirmations.size}" }
    }

    @OptIn(kotlin.uuid.ExperimentalUuidApi::class)
    private fun persistToolExecutions(
        results: List<app.m1k3.ai.domain.tools.ToolResult>,
        userQuery: String,
    ) {
        val ds = toolExecutionDataSource ?: return
        val now = Clock.System.now().toEpochMilliseconds()
        viewModelScope.launch(Dispatchers.IO) {
            results.forEach { result ->
                try {
                    val id =
                        kotlin.uuid.Uuid
                            .random()
                            .toString()
                    when (result) {
                        is app.m1k3.ai.domain.tools.ToolResult.Success -> {
                            ds.record(
                                id = id,
                                toolId = result.toolId,
                                query = userQuery,
                                result = result.output,
                                success = true,
                                errorMessage = null,
                                executionTimeMs = result.executionTimeMs,
                                timestamp = now,
                                messageId = null,
                                projectId = projectId,
                            )
                        }

                        is app.m1k3.ai.domain.tools.ToolResult.Failure -> {
                            ds.record(
                                id = id,
                                toolId = result.toolId,
                                query = userQuery,
                                result = null,
                                success = false,
                                errorMessage = result.error.displayMessage,
                                executionTimeMs = result.executionTimeMs,
                                timestamp = now,
                                messageId = null,
                                projectId = projectId,
                            )
                        }

                        is app.m1k3.ai.domain.tools.ToolResult.RequiresConfirmation -> { /* skip */ }
                    }
                } catch (e: Exception) {
                    logger.w { "Failed to persist tool execution: ${e.message}" }
                }
            }
        }
    }

    private fun handleToolsComplete(event: ChatEvent.Complete) {
        val response = event.response
        val stats = response.stats

        // Build display text including tool results
        val displayText = response.getDisplayText()

        _uiState.update { state ->
            val updatedMessages = state.messages.toMutableList()
            if (updatedMessages.isNotEmpty()) {
                updatedMessages[updatedMessages.lastIndex] =
                    updatedMessages.last().copy(
                        text = displayText,
                        inferenceStats = stats.formatFull(),
                        ragSources = stats.ragSources,
                        toolResults = state.toolState.executedTools,
                    )
            }
            state.copy(
                messages = updatedMessages,
                generationState =
                    GenerationState.Complete(
                        finalText = displayText,
                        stats = stats,
                    ),
                ragInfo = stats.ragInfo,
                toolState = state.toolState.copy(isExecuting = false),
            )
        }

        recordMessage(
            content = displayText,
            role = "assistant",
            tokens = stats.tokenCount,
            ragSources = stats.ragSources,
            ragConfidence = stats.ragConfidence,
        )

        logger.i { "Response with tools: ${stats.tokenCount} tokens in ${stats.durationMs}ms" }

        // Auto voice reply: speak the response if enabled
        autoSpeakIfEnabled()
    }

    private fun handleGenerationSuccess(
        thinkParser: StreamingThinkTagParser,
        tokenCount: Int,
        startTime: Long,
        context: EnrichedContext,
    ) {
        val duration = Clock.System.now().toEpochMilliseconds() - startTime
        val stats =
            GenerationStats(
                tokenCount = tokenCount,
                durationMs = duration,
                tokensPerSecond = if (duration > 0) tokenCount * 1000f / duration else 0f,
                ragInfo = context.ragInfo,
                ragSources = context.ragSources,
                ragConfidence = context.ragConfidence,
            )

        // Finalize parser — handles unclosed <think> tags
        thinkParser.finalize()

        val finalText = cleanFormatTokens(thinkParser.visibleText)

        _uiState.update { state ->
            val updatedMessages = state.messages.toMutableList()
            if (updatedMessages.isNotEmpty()) {
                val parseResult =
                    app.m1k3.ai.domain.chat.artifact.ArtifactParser
                        .parse(finalText)
                val artifact = parseResult.artifacts.firstOrNull()
                updatedMessages[updatedMessages.lastIndex] =
                    updatedMessages.last().copy(
                        text = finalText,
                        inferenceStats = stats.formatFull(),
                        ragSources = context.ragSources,
                        artifact = artifact,
                        thinkingContent = thinkParser.thinkingContent,
                        thinkingDurationMs = if (thinkParser.thinkingContent != null) thinkParser.thinkingDurationMs else null,
                    )
            }
            state.copy(
                messages = updatedMessages,
                generationState =
                    GenerationState.Complete(
                        finalText = finalText,
                        stats = stats,
                    ),
                ragInfo = context.ragInfo,
            )
        }

        recordMessage(
            content = finalText,
            role = "assistant",
            tokens = tokenCount,
            ragSources = context.ragSources,
            ragConfidence = context.ragConfidence,
        )

        logger.i { "Response generated: $tokenCount tokens in ${duration}ms (${stats.formatSpeed()})" }

        // Auto voice reply: speak the response if enabled
        autoSpeakIfEnabled()
    }

    private fun handleGenerationFailure(e: Throwable) {
        logger.e(e as? Exception ?: RuntimeException(e)) { "Generation failed" }
        val chatError = mapExceptionToError(e as? Exception ?: RuntimeException(e))
        _uiState.update { state ->
            val updatedMessages = state.messages.dropLast(1)
            state.copy(
                messages = updatedMessages,
                generationState = GenerationState.Failed(chatError),
                error = chatError,
            )
        }
    }

    private fun recordMessage(
        content: String,
        role: String,
        tokens: Int,
        ragSources: String? = null,
        ragConfidence: Double? = null,
    ) {
        viewModelScope.launch {
            try {
                val now = Clock.System.now().toEpochMilliseconds()
                val messageId = "msg_${now}_${(0..9999).random()}"

                database.messageQueries.insertMessage(
                    id = messageId,
                    project_id = projectId,
                    conversation_id = currentConversationId,
                    role = role,
                    content = content,
                    tokens = tokens.toLong(),
                    timestamp = now,
                    image_uri = null,
                    sentiment_valence = null,
                    sentiment_arousal = null,
                    sentiment_dominance = null,
                    sentiment_emotion = null,
                    sentiment_intensity = null,
                    rag_sources = ragSources,
                    rag_confidence = ragConfidence,
                )

                if (role == "user") {
                    currentConversationId?.let { convId ->
                        val conv = conversationRepo.getConversationById(convId)
                        if (conv?.title == UNTITLED_CONVERSATION_TITLE) {
                            val title = content.take(50) + if (content.length > 50) "..." else ""
                            conversationRepo.updateConversationTitle(convId, title)
                        }
                        conversationRepo.incrementMessageCount(convId, tokens.toLong())
                    }
                }
            } catch (e: Exception) {
                logger.w(e) { "Failed to record message" }
            }
        }
    }

    private fun updateContextWindowState(context: EnrichedContext) {
        val historyLines = context.conversationHistory?.lines()?.size ?: 0
        val historyMessageCount = (historyLines + 1) / 2 // Approximate: 2 lines per message pair

        // Estimate tokens: ~4 chars per token for English text
        val estimatedTokens = (context.context.length * 0.25f).toInt()

        // Get device tier info
        val ramGb = deviceInfo.getDeviceRamGB()
        val deviceTier =
            when {
                ramGb >= 12 -> "Flagship"
                ramGb >= 8 -> "High-End"
                ramGb >= 6 -> "Mid-Range"
                else -> "Budget"
            }

        // Max context based on device tier (rough approximation)
        val maxContext =
            when {
                ramGb >= 12 -> 8192
                ramGb >= 8 -> 6144
                ramGb >= 6 -> 4096
                else -> 2048
            }

        _uiState.update { state ->
            state.copy(
                contextWindow =
                    ContextWindowState(
                        historyMessageCount = historyMessageCount,
                        historyTokens = estimatedTokens,
                        maxContextTokens = maxContext,
                        deviceTier = deviceTier,
                    ),
            )
        }
    }

    private fun mapExceptionToError(e: Exception): ChatError {
        val message = e.message ?: "Unknown error"
        return when {
            message.contains("OutOfMemory", ignoreCase = true) -> ChatError.OutOfMemory(message)
            message.contains("timeout", ignoreCase = true) -> ChatError.Timeout(message)
            message.contains("model", ignoreCase = true) -> ChatError.ModelError(message)
            else -> ChatError.Unknown(message)
        }
    }

    companion object {
        /** Strip format tokens from accumulated text (handles split-token reassembly). */
        private val FORMAT_TOKEN_REGEX =
            Regex(
                "</?\\s*(?:start|end)[_\\s]*(?:of)[_\\s]*(?:turn)\\s*>|" +
                    "</?\\s*tool_?call\\s*>|" +
                    "<\\|im_(?:start|end)\\|?>|<\\|endoftext\\|?>|" +
                    "<eos>|<bos>|" +
                    "(?:start|end)[_\\s]+of[_\\s]+turn",
                RegexOption.IGNORE_CASE,
            )

        fun cleanFormatTokens(text: String): String = FORMAT_TOKEN_REGEX.replace(text, "").trim()
    }
}

/**
 * Collect ChatScreenViewModel state as Compose State.
 */
@Composable
fun ChatScreenViewModel.collectAsState(): State<ChatUiState> = uiState.collectAsState()
