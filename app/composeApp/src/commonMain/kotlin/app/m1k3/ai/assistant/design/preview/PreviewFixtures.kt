package app.m1k3.ai.assistant.design.preview

import kotlinx.datetime.Clock

/**
 * Shared Preview Fixtures for Compose Previews
 *
 * Provides mock data and utility callbacks for all component previews.
 * These fixtures are for preview/testing only—do NOT use in production code.
 *
 * **Usage in Previews:**
 * ```kotlin
 * @Preview
 * @Composable
 * private fun MyComponentPreview() {
 *     MaTheme {
 *         MyComponent(
 *             text = PreviewFixtures.sampleText,
 *             onClick = PreviewFixtures.noOpOnClick
 *         )
 *     }
 * }
 * ```
 */
object PreviewFixtures {

    // ============================================================
    // Text Content Fixtures
    // ============================================================

    const val sampleText = "Sample Text"

    const val sampleShortText = "Hi!"

    const val sampleLongText =
        "This is a much longer message that spans multiple lines to test how components " +
        "handle text wrapping and layout constraints. It should gracefully wrap and maintain readability."

    const val sampleMultilineText =
        "Line 1\nLine 2\nLine 3"

    // ============================================================
    // Chat Message Fixtures
    // ============================================================

    /**
     * Sample user message timestamp (Unix milliseconds)
     * Represents current time when fixture is created
     */
    val sampleUserMessageTimestamp: Long
        get() = Clock.System.now().toEpochMilliseconds()

    /**
     * Sample AI message timestamp (1 second after user message)
     */
    val sampleAiMessageTimestamp: Long
        get() = sampleUserMessageTimestamp + 1000

    // ============================================================
    // Pet/Avatar Stats Fixtures
    // ============================================================

    /**
     * Sample pet stats: Happy state
     * (Happiness: 85, Energy: 70, Knowledge: 60)
     */
    val samplePetStatsHappy = mapOf(
        "happiness" to 85,
        "energy" to 70,
        "knowledge" to 60
    )

    /**
     * Sample pet stats: Tired state
     * (Happiness: 60, Energy: 20, Knowledge: 50)
     */
    val samplePetStatsTired = mapOf(
        "happiness" to 60,
        "energy" to 20,
        "knowledge" to 50
    )

    /**
     * Sample pet stats: Sad state
     * (Happiness: 15, Energy: 40, Knowledge: 30)
     */
    val samplePetStatsSad = mapOf(
        "happiness" to 15,
        "energy" to 40,
        "knowledge" to 30
    )

    /**
     * Sample pet stats: Balanced state
     * (Happiness: 70, Energy: 75, Knowledge: 80)
     */
    val samplePetStatsBalanced = mapOf(
        "happiness" to 70,
        "energy" to 75,
        "knowledge" to 80
    )

    // ============================================================
    // No-Op Callbacks (for stateless previews)
    // ============================================================

    /**
     * No-op callback for onClick actions
     */
    val noOpOnClick: () -> Unit = {}

    /**
     * No-op callback for text input changes
     */
    val noOpOnTextChange: (String) -> Unit = {}

    /**
     * No-op callback for sending messages
     */
    val noOpOnMessageSend: (String) -> Unit = {}

    /**
     * No-op callback for navigation
     */
    val noOpOnNavigate: (String) -> Unit = {}

    /**
     * No-op callback for item selection
     */
    val noOpOnSelect: (String) -> Unit = {}

    /**
     * No-op callback for state toggling
     */
    val noOpOnToggle: (Boolean) -> Unit = {}

    // ============================================================
    // Button Text Fixtures
    // ============================================================

    const val buttonTextPrimary = "Primary Action"
    const val buttonTextSecondary = "Secondary Action"
    const val buttonTextCancel = "Cancel"
    const val buttonTextConfirm = "Confirm"
    const val buttonTextSend = "Send"
    const val buttonTextNext = "Next"
    const val buttonTextBack = "Back"
    const val buttonTextSkip = "Skip"
    const val buttonTextContinue = "Continue"

    // ============================================================
    // Input Field Fixtures
    // ============================================================

    const val sampleInputText = "Sample input text"
    const val sampleInputPlaceholder = "Enter text..."
    const val sampleInputError = "This field is required"
    const val sampleInputHelperText = "Enter your message"

    // ============================================================
    // List Item Fixtures
    // ============================================================

    val sampleListItems = listOf(
        "Item 1",
        "Item 2",
        "Item 3",
        "Item 4",
        "Item 5"
    )

    val sampleLongListItems = List(20) { index ->
        "Item ${index + 1}"
    }

    // ============================================================
    // Inference Stats Fixtures
    // ============================================================

    const val sampleInferenceStatsShort = "42 tok/s"
    const val sampleInferenceStatsMedium = "42 tok/s • 128 tokens"
    const val sampleInferenceStatsLong = "42 tok/s • 128 tokens • 3.0s"

    // ============================================================
    // RAG Source Fixtures
    // ============================================================

    const val sampleRagSourceSingle =
        "📄 Wikipedia: Machine Learning\n" +
        "   Excerpt: ML is a subset of AI..."

    const val sampleRagSourceMultiple =
        "📄 Wikipedia: Machine Learning\n" +
        "   Excerpt: ML is a subset of AI...\n" +
        "📚 Documentation: TensorFlow Guide\n" +
        "   Excerpt: TensorFlow provides...\n" +
        "🔗 Blog: Neural Networks Explained\n" +
        "   Excerpt: Neural networks mimic..."

    // ============================================================
    // Status/State Fixtures
    // ============================================================

    const val statusLoading = "Loading..."
    const val statusEmpty = "No items"
    const val statusError = "An error occurred"
    const val statusSuccess = "Success!"

    // ============================================================
    // Conversation Message Sequences
    // ============================================================

    /**
     * Sample conversation: Welcome exchange
     *
     * User: "Hello!"
     * AI: "Hi there! How can I help?"
     */
    val sampleConversationWelcome: List<Pair<Boolean, String>> = listOf(
        Pair(true, "Hello!"),
        Pair(false, "Hi there! How can I help you today?")
    )

    /**
     * Sample conversation: Knowledge question
     *
     * User: "What is machine learning?"
     * AI: "Machine learning is a subset of artificial intelligence..."
     */
    val sampleConversationKnowledge: List<Pair<Boolean, String>> = listOf(
        Pair(true, "What is machine learning?"),
        Pair(
            false,
            "Machine learning is a subset of artificial intelligence where systems learn and improve from experience without being explicitly programmed. It uses algorithms to analyze patterns in data."
        )
    )

    /**
     * Sample conversation: Long exchange
     *
     * Multiple turn conversation for testing scroll and layout.
     */
    val sampleConversationLong: List<Pair<Boolean, String>> = listOf(
        Pair(true, "Tell me about AI."),
        Pair(false, "Artificial Intelligence (AI) is the simulation of human intelligence by machines. Here are the key areas:\n\n1. Machine Learning\n2. Natural Language Processing\n3. Computer Vision\n4. Robotics"),
        Pair(true, "Which one is most important?"),
        Pair(false, "They're all important, but Machine Learning has the broadest applications today, powering recommendation systems, image recognition, and autonomous vehicles."),
        Pair(true, "Thanks for explaining!"),
        Pair(false, "You're welcome! Feel free to ask more questions anytime.")
    )

    // ============================================================
    // Color Swatches for Design System Preview
    // ============================================================

    val colorNames = listOf(
        "Primary",
        "Secondary",
        "Tertiary",
        "Error",
        "Success",
        "Warning",
        "Info"
    )

    // ============================================================
    // Accessibility & Density Fixtures
    // ============================================================

    const val longAccessibilityLabel =
        "This is a long accessibility label that describes the purpose and function of this component for screen reader users."

    const val multilineAccessibilityLabel =
        "Line 1 of accessibility description.\n" +
        "Line 2 of accessibility description.\n" +
        "Line 3 of accessibility description."

    /**
     * Create an AvatarState with given emotion and activity
     * Available emotions: HAPPY, NEUTRAL, THINKING, EXCITED, CONCERNED, TIRED
     * Available activities: IDLE, LISTENING, THINKING, GENERATING, SPEAKING, ERROR
     */
    fun createAvatarState(
        emotion: String = "HAPPY",
        activity: String = "IDLE",
        intensity: Float = 1f
    ) = mapOf(
        "emotion" to emotion,
        "activity" to activity,
        "intensity" to intensity,
        "isAnimating" to (activity != "IDLE")
    )

    val avatarHappyIdle = createAvatarState(emotion = "HAPPY", activity = "IDLE")
    val avatarThinking = createAvatarState(emotion = "THINKING", activity = "THINKING")
    val avatarGenerating = createAvatarState(emotion = "HAPPY", activity = "GENERATING")
    val avatarError = createAvatarState(emotion = "CONCERNED", activity = "ERROR")
}
