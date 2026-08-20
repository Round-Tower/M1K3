package app.m1k3.ai.assistant.avatar

import app.m1k3.ai.domain.tools.ToolCategory

/**
 * Maps a tool invocation to the avatar emotion M1K3 should feel when it runs.
 *
 * Rules of thumb:
 *   * Failure is always [AvatarEmotion.SAD] — user-visible empathy.
 *   * Specific tools override category defaults (flashlight is EXCITED even
 *     though its category is SYSTEM).
 *   * Categories are the last resort for unknown tools; an unknown tool in
 *     a known category borrows its vibe.
 *
 * Pure function — no side effects, no platform, unit-tested.
 *
 * MurphySig: kev+claude / confidence 0.7 / 2026-04-19
 * Rationale: the avatar is M1K3's voice when text isn't. Making it react
 * to tool results is cheap personality — a sparrow that lights up when
 * you ask for the flashlight feels alive in a way a static icon doesn't.
 */
object ToolEmotionMap {
    private val specificToolEmotions: Map<String, AvatarEmotion> =
        mapOf(
            "toggle_flashlight" to AvatarEmotion.EXCITED,
            "set_timer" to AvatarEmotion.EXCITED,
            "set_alarm" to AvatarEmotion.EXCITED,
            "web_search" to AvatarEmotion.THINKING,
            "get_current_time" to AvatarEmotion.NEUTRAL,
            "get_battery_level" to AvatarEmotion.NEUTRAL,
            "set_volume" to AvatarEmotion.HAPPY,
        )

    private val categoryFallback: Map<ToolCategory, AvatarEmotion> =
        mapOf(
            ToolCategory.KNOWLEDGE to AvatarEmotion.THINKING,
            ToolCategory.APPS to AvatarEmotion.HAPPY,
            ToolCategory.SYSTEM to AvatarEmotion.HAPPY,
            ToolCategory.DEVICE_INFO to AvatarEmotion.NEUTRAL,
            ToolCategory.MEDIA to AvatarEmotion.EXCITED,
            ToolCategory.COMMUNICATION to AvatarEmotion.LOVE,
            ToolCategory.FILES to AvatarEmotion.NEUTRAL,
        )

    fun emotionFor(
        toolId: String,
        category: ToolCategory?,
        success: Boolean,
    ): AvatarEmotion {
        if (!success) return AvatarEmotion.SAD
        specificToolEmotions[toolId]?.let { return it }
        category?.let { categoryFallback[it] }?.let { return it }
        return AvatarEmotion.NEUTRAL
    }
}
