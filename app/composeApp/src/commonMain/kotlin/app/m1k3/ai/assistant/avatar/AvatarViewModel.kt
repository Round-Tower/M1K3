package app.m1k3.ai.assistant.avatar

import androidx.compose.runtime.*
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch

/**
 * M1K3 Avatar ViewModel
 *
 * Central state manager for avatar system:
 * - Tracks current emotion and activity
 * - Coordinates with emotion detector
 * - Syncs with AI inference states
 * - Manages transition animations
 * - Provides UI-friendly state access
 */

class AvatarViewModel(private val scope: CoroutineScope) {
    // State flows
    private val _avatarState = MutableStateFlow(AvatarState())
    val avatarState: StateFlow<AvatarState> = _avatarState.asStateFlow()

    // Message history for context-aware emotion detection
    private val recentMessages = mutableListOf<String>()
    private val maxMessageHistory = 5

    // Idle timeout management
    private var idleTimeoutJob: Job? = null
    private val idleTimeoutMs: Long = 5000 // 5 seconds

    /**
     * Set avatar emotion manually
     *
     * Cancels idle timeout since this is an active state change.
     *
     * @param emotion Target emotion
     * @param intensity Emotion intensity (0.0 to 1.0)
     * @param message Optional status message
     */
    fun setEmotion(
        emotion: AvatarEmotion,
        intensity: Float = 0.7f,
        message: String? = null
    ) {
        // Cancel idle timeout on manual emotion change
        idleTimeoutJob?.cancel()

        _avatarState.value = _avatarState.value.copy(
            emotion = emotion,
            intensity = intensity.coerceIn(0f, 1f),
            message = message
        )
    }

    /**
     * Set avatar activity (IDLE, THINKING, GENERATING, etc.)
     *
     * Automatically adjusts emotion to match activity if appropriate.
     * Starts idle timeout when activity becomes IDLE.
     *
     * @param activity Target activity state
     */
    fun setActivity(activity: AvatarActivity) {
        val currentState = _avatarState.value

        // Cancel any existing idle timeout
        idleTimeoutJob?.cancel()

        // Update activity
        val newState = if (activity != currentState.activity) {
            // Auto-adjust emotion for certain activities
            val newEmotion = when (activity) {
                AvatarActivity.LISTENING -> AvatarEmotion.THINKING
                AvatarActivity.THINKING -> AvatarEmotion.THINKING
                AvatarActivity.GENERATING -> AvatarEmotion.EXCITED
                AvatarActivity.ERROR -> AvatarEmotion.ANGRY
                else -> currentState.emotion
            }

            currentState.copy(
                activity = activity,
                emotion = newEmotion,
                intensity = if (activity.isActive) 0.7f else 0.5f
            )
        } else {
            currentState
        }

        _avatarState.value = newState

        // Start idle timeout if activity is IDLE
        if (activity == AvatarActivity.IDLE) {
            startIdleTimeout()
        }
    }

    /**
     * Start idle timeout timer
     *
     * After 5 seconds of IDLE activity, resets avatar to neutral state.
     */
    private fun startIdleTimeout() {
        idleTimeoutJob = scope.launch {
            delay(idleTimeoutMs)
            // Only reset if still IDLE after delay
            if (_avatarState.value.activity == AvatarActivity.IDLE) {
                resetToIdleState()
            }
        }
    }

    /**
     * Reset avatar to neutral idle state
     *
     * Called after idle timeout expires. Resets:
     * - Emotion to NEUTRAL
     * - Intensity to minimal (0.3)
     * - Activity stays IDLE
     * - Clears status message
     */
    private fun resetToIdleState() {
        _avatarState.value = _avatarState.value.copy(
            emotion = AvatarEmotion.NEUTRAL,
            intensity = 0.3f,
            activity = AvatarActivity.IDLE,
            message = null
        )
    }

    /**
     * Process message and update avatar emotion
     *
     * Analyzes message text to detect emotion and updates avatar accordingly.
     *
     * @param text Message text to analyze
     * @param isUserMessage Whether this is a user message (vs AI response)
     */
    fun processMessage(text: String, isUserMessage: Boolean = true) {
        // Add to message history
        recentMessages.add(text)
        if (recentMessages.size > maxMessageHistory) {
            recentMessages.removeAt(0)
        }

        // Detect emotion from context
        val detection = if (recentMessages.size >= 2) {
            EmotionDetector.detectEmotionFromContext(recentMessages)
        } else {
            EmotionDetector.detectEmotion(text)
        }

        // Only update if confidence is reasonable
        if (detection.confidence > 0.3f) {
            _avatarState.value = _avatarState.value.copy(
                emotion = detection.emotion,
                intensity = detection.intensity,
                message = if (detection.detectedKeywords.isNotEmpty()) {
                    "Detected: ${detection.detectedKeywords.joinToString(", ")}"
                } else null
            )
        }
    }

    /**
     * Sync avatar with AI inference state
     *
     * Call this when AI state changes (idle → generating → complete).
     *
     * @param isGenerating Whether AI is currently generating
     * @param isError Whether an error occurred
     */
    fun syncWithAI(isGenerating: Boolean, isError: Boolean = false) {
        val activity = when {
            isError -> AvatarActivity.ERROR
            isGenerating -> AvatarActivity.GENERATING
            else -> AvatarActivity.IDLE
        }
        setActivity(activity)
    }

    /**
     * Set thinking state (processing user input)
     */
    fun startThinking() {
        setActivity(AvatarActivity.THINKING)
    }

    /**
     * Set generating state (creating response)
     */
    fun startGenerating() {
        setActivity(AvatarActivity.GENERATING)
    }

    /**
     * Set speaking state (delivering response)
     */
    fun startSpeaking() {
        setActivity(AvatarActivity.SPEAKING)
    }

    /**
     * Return to idle state
     */
    fun returnToIdle() {
        setActivity(AvatarActivity.IDLE)
        // Gradually fade intensity
        scope.launch {
            var currentIntensity = _avatarState.value.intensity
            while (currentIntensity > 0.5f) {
                currentIntensity -= 0.05f
                _avatarState.value = _avatarState.value.copy(
                    intensity = currentIntensity.coerceAtLeast(0.5f)
                )
                delay(100)
            }
        }
    }

    /**
     * Set error state
     */
    fun showError(errorMessage: String) {
        _avatarState.value = _avatarState.value.copy(
            emotion = AvatarEmotion.ANGRY,
            activity = AvatarActivity.ERROR,
            intensity = 0.8f,
            message = errorMessage
        )
    }

    /**
     * Clear error and return to neutral
     */
    fun clearError() {
        _avatarState.value = _avatarState.value.copy(
            emotion = AvatarEmotion.NEUTRAL,
            activity = AvatarActivity.IDLE,
            intensity = 0.5f,
            message = null
        )
    }

    /**
     * Temporary emotion flash
     *
     * Shows emotion briefly then returns to previous state.
     * Useful for quick reactions (e.g., "thinking..." → flash THINKING for 1s)
     *
     * @param emotion Emotion to flash
     * @param duration Duration in milliseconds
     */
    fun flashEmotion(emotion: AvatarEmotion, duration: Long = 1000) {
        val previousState = _avatarState.value
        setEmotion(emotion, intensity = 0.9f)

        scope.launch {
            delay(duration)
            _avatarState.value = previousState
        }
    }

    /**
     * Reset to default state
     */
    fun reset() {
        _avatarState.value = AvatarState()
        recentMessages.clear()
    }

    /**
     * Get current emotion
     */
    val currentEmotion: AvatarEmotion
        get() = _avatarState.value.emotion

    /**
     * Get current activity
     */
    val currentActivity: AvatarActivity
        get() = _avatarState.value.activity

    /**
     * Check if avatar is currently active/animating
     */
    val isActive: Boolean
        get() = _avatarState.value.isAnimating
}

/**
 * Create and remember avatar view model
 *
 * @return Avatar view model scoped to composition
 */
@Composable
fun rememberAvatarViewModel(): AvatarViewModel {
    val scope = rememberCoroutineScope()
    return remember { AvatarViewModel(scope) }
}

/**
 * Collect avatar state as Compose State
 *
 * @param viewModel Avatar view model
 * @return Current avatar state
 */
@Composable
fun AvatarViewModel.collectAsState(): State<AvatarState> {
    return avatarState.collectAsState()
}

/**
 * Usage Examples:
 * ```kotlin
 * @Composable
 * fun ChatScreen() {
 *     val avatarVM = rememberAvatarViewModel()
 *     val avatarState by avatarVM.collectAsState()
 *
 *     // Update avatar based on AI state
 *     LaunchedEffect(isGenerating) {
 *         avatarVM.syncWithAI(isGenerating)
 *     }
 *
 *     // Process user message
 *     fun onSendMessage(text: String) {
 *         avatarVM.processMessage(text, isUserMessage = true)
 *         // ... send to AI
 *     }
 *
 *     // Process AI response
 *     LaunchedEffect(aiResponse) {
 *         if (aiResponse != null) {
 *             avatarVM.processMessage(aiResponse, isUserMessage = false)
 *             avatarVM.startSpeaking()
 *         }
 *     }
 *
 *     // Display avatar
 *     DotMatrixAvatar(state = avatarState)
 * }
 *
 * // Manual emotion control
 * Button(onClick = { avatarVM.setEmotion(AvatarEmotion.HAPPY, 0.9f) }) {
 *     Text("Make Happy")
 * }
 *
 * // Activity tracking
 * avatarVM.startThinking()           // User typing detected
 * avatarVM.startGenerating()         // AI inference started
 * avatarVM.startSpeaking()           // Streaming response
 * avatarVM.returnToIdle()            // Conversation paused
 *
 * // Error handling
 * avatarVM.showError("Model failed to load")
 * ```
 */
