package app.m1k3.ai.assistant.chat

// Import domain types
import app.m1k3.ai.domain.ai.LlmModel
import app.m1k3.ai.domain.chat.ChatError
import app.m1k3.ai.domain.chat.GenerationStats
import app.m1k3.ai.domain.status.ChatStatus

/**
 * ChatUiState - Single source of truth for ChatScreen UI state.
 *
 * This comprehensive state class consolidates all UI state previously
 * scattered across multiple remember() calls and ViewModels in ChatScreen.
 *
 * **Architecture:**
 * - Immutable data class for predictable state updates
 * - Sealed classes for type-safe state variants
 * - All state changes flow through ChatScreenViewModel
 *
 * **Usage:**
 * ```kotlin
 * val uiState by viewModel.uiState.collectAsState()
 *
 * when (uiState.generationState) {
 *     is GenerationState.Streaming -> showTypingIndicator()
 *     is GenerationState.Complete -> hideTypingIndicator()
 *     // ...
 * }
 * ```
 */
data class ChatUiState(
    /** All messages in the conversation */
    val messages: List<ChatMessage> = emptyList(),
    /** Current text in the input field */
    val inputText: String = "",
    /** Current generation state (Idle, Thinking, Streaming, Complete, Failed) */
    val generationState: GenerationState = GenerationState.Idle,
    /** AI engine initialization state */
    val engineState: EngineState = EngineState.Loading,
    /** Current error to display (null if none) */
    val error: ChatError? = null,
    /** RAG info for display (e.g., "Technical (85%) • 3 facts") */
    val ragInfo: String? = null,
    /** Context window usage tracking */
    val contextWindow: ContextWindowState = ContextWindowState(),
    /** Tool state for tool calling support */
    val toolState: ToolState = ToolState(),
    /** Chat status for initial status card (null until generated) */
    val chatStatus: ChatStatus? = null,
    /** Currently selected LLM model */
    val currentModel: LlmModel = LlmModel.default,
    /** TTS speaking state */
    val isSpeaking: Boolean = false,
    /** TTS model loading state (first-load latency indicator) */
    val isLoadingTts: Boolean = false,
    /** Model download progress (null when not downloading) */
    val modelDownload: ModelDownloadState? = null,
    /** Auto voice reply - automatically speak AI responses aloud */
    val autoVoiceReply: Boolean = false,
    /** User's first name for the welcome greeting (null until loaded) */
    val userName: String? = null,
)

/**
 * AI generation state machine.
 *
 * Tracks the lifecycle of a single AI response generation.
 */
sealed class GenerationState {
    /** No generation in progress */
    data object Idle : GenerationState()

    /** AI is thinking (before first token) */
    data object Thinking : GenerationState()

    /**
     * Streaming tokens from AI.
     *
     * @property partialText Accumulated response text so far
     * @property tokenCount Number of tokens generated
     */
    data class Streaming(
        val partialText: String,
        val tokenCount: Int,
        /** Thinking content accumulating inside <think>...</think> — null when not thinking */
        val thinkingPartial: String? = null,
        /** True while inside <think> block — drives the "Thinking..." animation */
        val isThinking: Boolean = false,
    ) : GenerationState()

    /**
     * Generation completed successfully.
     *
     * @property finalText Complete response text
     * @property stats Generation statistics
     */
    data class Complete(
        val finalText: String,
        val stats: GenerationStats,
    ) : GenerationState()

    /**
     * Generation failed.
     *
     * @property error Error that caused the failure
     */
    data class Failed(
        val error: ChatError,
    ) : GenerationState()
}

/**
 * AI engine initialization state.
 */
sealed class EngineState {
    /** Engine is loading/initializing */
    data object Loading : EngineState()

    /** Engine is ready for generation */
    data object Ready : EngineState()

    /**
     * Engine failed to initialize.
     *
     * @property error Error that caused the failure
     */
    data class Failed(
        val error: ChatError,
    ) : EngineState()
}

// ChatError is imported from app.m1k3.ai.domain.chat.ChatError
// GenerationStats is imported from app.m1k3.ai.domain.chat.GenerationStats

/**
 * Extension: Get user-friendly error message for UI display.
 */
fun ChatError.toUserMessage(): String =
    when (this) {
        is ChatError.OutOfMemory -> "Not enough memory. Try closing other apps."
        is ChatError.Timeout -> "Response took too long. Please try again."
        is ChatError.ModelError -> "AI model error: $message"
        is ChatError.EngineInitError -> "Failed to start AI: $message"
        is ChatError.Unknown -> "Something went wrong: $message"
    }

/**
 * Extension: Get emoji for error type in UI display.
 */
fun ChatError.toEmoji(): String =
    when (this) {
        is ChatError.OutOfMemory -> "💾"
        is ChatError.Timeout -> "⏱️"
        is ChatError.ModelError -> "🤖"
        is ChatError.EngineInitError -> "⚙️"
        is ChatError.Unknown -> "❌"
    }

/**
 * Extension to check if generation is in progress.
 */
val GenerationState.isGenerating: Boolean
    get() = this is GenerationState.Thinking || this is GenerationState.Streaming

/**
 * Extension to check if engine is ready.
 */
val EngineState.isReady: Boolean
    get() = this is EngineState.Ready

/**
 * Extension to check if input field is enabled.
 * The input field should be enabled when the engine is ready and not generating.
 */
val ChatUiState.isInputEnabled: Boolean
    get() = engineState.isReady && !generationState.isGenerating

/**
 * Extension to check if send button should be enabled.
 * Send is only allowed when input is enabled AND there's text to send.
 */
val ChatUiState.canSendMessage: Boolean
    get() = isInputEnabled && inputText.isNotBlank()

/**
 * Signed: Kev + claude-sonnet-4-6, 2026-04-06
 * Format: MurphySig v0.1 (https://murphysig.dev/spec)
 *
 * Context: Auto voice reply extensions. shouldAutoSpeak is a pure computed property
 * — no side effects, fully testable. The guard against isSpeaking prevents double-play
 * if the user taps speak manually while auto-reply is enabled. Defaults to false so
 * new users aren't surprised by a speaking phone.
 *
 * Confidence: 0.9 — logic is simple and well-tested (10 tests passing).
 */

/**
 * Extension to check if auto-speak should trigger.
 *
 * True when:
 * - autoVoiceReply is enabled
 * - Generation just completed with non-empty text
 * - Not already speaking
 */
val ChatUiState.shouldAutoSpeak: Boolean
    get() =
        autoVoiceReply &&
            !isSpeaking &&
            generationState is GenerationState.Complete &&
            (generationState as GenerationState.Complete).finalText.isNotBlank()

/**
 * Single chat message in the conversation.
 */
data class ChatMessage(
    /** Message text content */
    val text: String,
    /** True if sent by user, false if from AI assistant */
    val isUser: Boolean,
    /** Message timestamp in milliseconds since epoch */
    val timestamp: Long = 0,
    /** True if this message represents an error */
    val isError: Boolean = false,
    /** Inference statistics for AI messages (e.g., "⚡ 42 tokens in 3.0s") */
    val inferenceStats: String? = null,
    /** RAG sources used for this response */
    val ragSources: String? = null,
    /** HTML artifact generated by the model (rendered in WebView). Null for plain text. */
    val artifact: app.m1k3.ai.domain.chat.artifact.ArtifactData? = null,
    /** Thinking content from <think>...</think> block. Shown in collapsible ThinkingPill. */
    val thinkingContent: String? = null,
    /** How long the model spent thinking in milliseconds. Shown as "Thought for Xs". */
    val thinkingDurationMs: Long? = null,
    /** Tool execution results for this message (shown in ToolCallPill) */
    val toolResults: List<ToolExecutionResult> = emptyList(),
    /** True if this is a status message (displayed as card, not chat bubble) */
    val isStatusMessage: Boolean = false,
    // Status card fields (only used when isStatusMessage = true)
    /** Memory count for status card */
    val statusMemoryCount: Long? = null,
    /** Max context tokens for status card */
    val statusMaxTokens: Int? = null,
    /** Device tier name for status card */
    val statusDeviceTier: String? = null,
)

/**
 * Context window usage state for displaying token consumption.
 */
data class ContextWindowState(
    /** Number of conversation history messages included in context */
    val historyMessageCount: Int = 0,
    /** Estimated tokens used by conversation history */
    val historyTokens: Int = 0,
    /** Maximum context tokens based on device tier */
    val maxContextTokens: Int = 4096,
    /** Device tier name for display */
    val deviceTier: String = "Unknown",
) {
    /** Percentage of context window used (0-100) */
    val usagePercent: Float
        get() = if (maxContextTokens > 0) (historyTokens.toFloat() / maxContextTokens * 100) else 0f

    /** Formatted context usage for display */
    fun formatUsage(): String = "$historyTokens / $maxContextTokens tokens"

    /** Format as compact badge */
    fun formatCompact(): String =
        when {
            historyMessageCount == 0 -> "No history"
            else -> "$historyMessageCount msgs (${usagePercent.toInt()}%)"
        }
}

/**
 * Tool execution state for agentic capabilities.
 *
 * Tracks pending confirmations and executed tool results.
 */
data class ToolState(
    /** Tools awaiting user confirmation */
    val pendingConfirmations: List<ToolConfirmation> = emptyList(),
    /** Results from executed tools (for display) */
    val executedTools: List<ToolExecutionResult> = emptyList(),
    /** Whether tools are currently executing */
    val isExecuting: Boolean = false,
) {
    /** Whether there are pending confirmations */
    val hasPendingConfirmations: Boolean
        get() = pendingConfirmations.isNotEmpty()
}

/**
 * Tool confirmation request for user approval.
 */
data class ToolConfirmation(
    /** Unique ID for this confirmation request */
    val id: String,
    /** Tool ID being requested */
    val toolId: String,
    /** Human-readable tool name */
    val toolName: String,
    /** Description of what the tool will do */
    val description: String,
    /** Arguments being passed to the tool */
    val arguments: Map<String, String>,
)

/**
 * Result from an executed tool.
 */
data class ToolExecutionResult(
    /** Tool ID that was executed */
    val toolId: String,
    /** Human-readable result for display */
    val displayResult: String,
    /** Whether execution was successful */
    val isSuccess: Boolean,
    /** Error message if failed */
    val errorMessage: String? = null,
)

/**
 * Model download state for large GGUF models.
 *
 * Tracks progress when downloading models like Gemma 4 E2B
 * that are too large to bundle in the APK.
 */
sealed class ModelDownloadState {
    /** Download is starting */
    data class Starting(
        val modelName: String,
    ) : ModelDownloadState()

    /** Download in progress with percentage */
    data class InProgress(
        val modelName: String,
        val progressPercent: Int,
        val downloadedMB: Long,
        val totalMB: Long,
    ) : ModelDownloadState()

    /** Download complete, model ready */
    data class Complete(
        val modelName: String,
    ) : ModelDownloadState()

    /** Download failed */
    data class Failed(
        val modelName: String,
        val error: String,
    ) : ModelDownloadState()
}
