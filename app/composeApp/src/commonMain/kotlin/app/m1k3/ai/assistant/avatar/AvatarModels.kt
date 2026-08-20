package app.m1k3.ai.assistant.avatar

import androidx.compose.ui.graphics.Color
import app.m1k3.ai.assistant.design.tokens.MaColors

/**
 * 間 AI Avatar System - Data Models
 *
 * Defines emotions, states, and visual properties for the robot avatar.
 * Inspired by M1K3's desktop avatar system, adapted for mobile.
 *
 * Philosophy: Minimalist robot design with 8 expressive emotions
 */

/**
 * Avatar emotion types
 *
 * 8 distinct emotional states with visual characteristics
 */
enum class AvatarEmotion(
    val displayName: String,
    val emoji: String,
    val primaryColor: Color,
    val description: String,
) {
    HAPPY(
        displayName = "Happy",
        emoji = "😊",
        primaryColor = Color(0xFF4CAF50), // Green
        description = "Joyful, content, satisfied",
    ),
    SAD(
        displayName = "Sad",
        emoji = "😢",
        primaryColor = Color(0xFF2196F3), // Blue
        description = "Melancholy, disappointed, down",
    ),
    ANGRY(
        displayName = "Angry",
        emoji = "😠",
        primaryColor = Color(0xFFF44336), // Red
        description = "Frustrated, irritated, upset",
    ),
    SURPRISED(
        displayName = "Surprised",
        emoji = "😲",
        primaryColor = Color(0xFFFFEB3B), // Yellow
        description = "Astonished, shocked, amazed",
    ),
    LOVE(
        displayName = "Love",
        emoji = "😍",
        primaryColor = Color(0xFFE91E63), // Pink
        description = "Affectionate, adoring, caring",
    ),
    THINKING(
        displayName = "Thinking",
        emoji = "🤔",
        primaryColor = Color(0xFF9C27B0), // Purple
        description = "Pondering, processing, analyzing",
    ),
    SLEEPY(
        displayName = "Sleepy",
        emoji = "😴",
        primaryColor = Color(0xFF607D8B), // Blue-gray
        description = "Tired, drowsy, resting",
    ),
    EXCITED(
        displayName = "Excited",
        emoji = "🤩",
        primaryColor = MaColors.Orange, // M1K3 orange
        description = "Enthusiastic, energized, thrilled",
    ),
    NEUTRAL(
        displayName = "Neutral",
        emoji = "😐",
        primaryColor = MaColors.TextSecondary, // Gray
        description = "Calm, balanced, composed",
    ),
    ;

    companion object {
        fun fromString(name: String): AvatarEmotion = entries.find { it.name.equals(name, ignoreCase = true) } ?: NEUTRAL
    }
}

/**
 * Avatar activity state
 *
 * Represents what the AI is currently doing
 */
enum class AvatarActivity(
    val displayName: String,
    val description: String,
) {
    IDLE(
        displayName = "Idle",
        description = "Waiting for input",
    ),
    LISTENING(
        displayName = "Listening",
        description = "Processing user input",
    ),
    THINKING(
        displayName = "Thinking",
        description = "Analyzing and reasoning",
    ),
    GENERATING(
        displayName = "Generating",
        description = "Creating response",
    ),
    SPEAKING(
        displayName = "Speaking",
        description = "Delivering response",
    ),
    ERROR(
        displayName = "Error",
        description = "Encountered an issue",
    ),
    ;

    val isActive: Boolean
        get() = this != IDLE && this != ERROR
}

/**
 * Avatar visual state
 *
 * Complete state snapshot for rendering
 */
data class AvatarState(
    val emotion: AvatarEmotion = AvatarEmotion.NEUTRAL,
    val activity: AvatarActivity = AvatarActivity.IDLE,
    val intensity: Float = 0.5f, // 0.0 (subtle) to 1.0 (extreme)
    val animationProgress: Float = 0.0f, // 0.0 to 1.0 for transitions
    val message: String? = null, // Optional status message
) {
    /**
     * Get current display color based on emotion and intensity
     */
    val displayColor: Color
        get() {
            val baseColor = emotion.primaryColor
            // Blend with white/black based on intensity
            return if (intensity > 0.5f) {
                // More intense = brighter
                Color(
                    red = baseColor.red + (1f - baseColor.red) * (intensity - 0.5f) * 0.5f,
                    green = baseColor.green + (1f - baseColor.green) * (intensity - 0.5f) * 0.5f,
                    blue = baseColor.blue + (1f - baseColor.blue) * (intensity - 0.5f) * 0.5f,
                )
            } else {
                // Less intense = darker
                Color(
                    red = baseColor.red * (intensity * 2f),
                    green = baseColor.green * (intensity * 2f),
                    blue = baseColor.blue * (intensity * 2f),
                )
            }
        }

    /**
     * Check if avatar should be animating
     */
    val isAnimating: Boolean
        get() = activity.isActive || animationProgress > 0f

    companion object {
        /**
         * Create state from AI activity
         */
        fun fromActivity(activity: AvatarActivity): AvatarState {
            val emotion =
                when (activity) {
                    AvatarActivity.IDLE -> AvatarEmotion.NEUTRAL
                    AvatarActivity.LISTENING -> AvatarEmotion.THINKING
                    AvatarActivity.THINKING -> AvatarEmotion.THINKING
                    AvatarActivity.GENERATING -> AvatarEmotion.EXCITED
                    AvatarActivity.SPEAKING -> AvatarEmotion.HAPPY
                    AvatarActivity.ERROR -> AvatarEmotion.ANGRY
                }
            return AvatarState(
                emotion = emotion,
                activity = activity,
                intensity = if (activity.isActive) 0.7f else 0.5f,
            )
        }
    }
}

/**
 * Usage Examples:
 * ```kotlin
 * // Create default state
 * val state = AvatarState()
 *
 * // Set emotion with intensity
 * val happyState = AvatarState(
 *     emotion = AvatarEmotion.HAPPY,
 *     intensity = 0.8f
 * )
 *
 * // Create state from activity
 * val thinkingState = AvatarState.fromActivity(AvatarActivity.THINKING)
 * ```
 */
