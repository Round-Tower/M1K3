package app.m1k3.ai.assistant.navigation

/**
 * M1K3 - Navigation Routes
 *
 * Type-safe navigation destinations for the M1K3 mobile app.
 * Implements sealed class hierarchy for compile-time safety.
 *
 * **Philosophy:**
 * Chat is the app. Everything else — Memories, Documents, Conversations,
 * Settings — is a workspace room reached by pushing onto Chat's single
 * NavigationStack-equivalent back stack (no drawer, no bottom nav).
 */
sealed class Screen(
    val route: String,
) {
    /**
     * Chat screen - the app's home. Main AI conversation interface.
     */
    data object Chat : Screen("chat")

    /**
     * History screen - Browse and search past conversations ("Conversations" in UI).
     */
    data object History : Screen("history")

    /**
     * Settings screen - App configuration and preferences
     */
    data object Settings : Screen("settings")

    /**
     * Memories screen — search what M1K3 remembers, on device.
     */
    data object Memories : Screen("memories")

    /**
     * Documents screen — list + manage personal-knowledge sources the user imported.
     */
    data object Documents : Screen("documents")

    /**
     * Voice mode — full-screen, spoken conversation. M1K3 owns the turn
     * boundary (see `VoiceLoopController`), not the recogniser.
     */
    data object VoiceMode : Screen("voice")

    /**
     * Open Source Licenses screen - All third-party libraries, assets, and attributions
     */
    data object Licenses : Screen("licenses")

    /**
     * Onboarding screen — first-launch experience.
     *
     * Shown once: detects hardware tier, names the user's M1K3 (Mini/Lil/Big),
     * downloads the appropriate model, and introduces the app's ethos while
     * the intelligence machine wakes up.
     */
    data object Onboarding : Screen("onboarding")

    /**
     * Conversation Detail screen - View specific conversation messages
     *
     * Route: "conversation/{conversationId}"
     * Args: conversationId (Long)
     */
    data class ConversationDetail(
        val conversationId: Long,
    ) : Screen("conversation/$conversationId") {
        companion object {
            const val route = "conversation/{conversationId}"
            const val argConversationId = "conversationId"
        }
    }
}
