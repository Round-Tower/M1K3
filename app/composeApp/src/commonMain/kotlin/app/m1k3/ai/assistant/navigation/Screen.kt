package app.m1k3.ai.assistant.navigation

/**
 * 間 AI - Navigation Routes
 *
 * Type-safe navigation destinations for the 間 AI mobile app.
 * Implements sealed class hierarchy for compile-time safety.
 *
 * **Philosophy:**
 * Navigation should be simple, predictable, and type-safe.
 * Every screen is a destination, every destination has a route.
 *
 * **Bottom Nav Tabs:**
 * - Chat: Main AI conversation interface
 * - History: Browse past conversations
 * - Settings: App configuration and preferences
 */
sealed class Screen(
    val route: String,
) {
    /**
     * Chat screen - Main AI conversation interface
     */
    data object Chat : Screen("chat")

    /**
     * History screen - Browse and search past conversations
     */
    data object History : Screen("history")

    /**
     * Settings screen - App configuration and preferences
     */
    data object Settings : Screen("settings")

    /**
     * Documents screen — list + manage personal-knowledge sources the user imported.
     */
    data object Documents : Screen("documents")

    /**
     * About M1K3 screen - App mission, privacy-first messaging, version info
     */
    data object About : Screen("about")

    /**
     * Help & Documentation screen - Feature guides, tips, FAQ
     */
    data object Help : Screen("help")

    /**
     * Send Feedback screen - GitHub issues, bug reports, feature requests
     */
    data object Feedback : Screen("feedback")

    /**
     * Privacy Policy screen - Zero-network promise, data handling
     */
    data object Privacy : Screen("privacy")

    /**
     * Open Source Licenses screen - All third-party libraries, assets, and attributions
     */
    data object Licenses : Screen("licenses")

    /**
     * Export Data screen - Backup conversations
     */
    data object Export : Screen("export")

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

    companion object {
        /**
         * Get all bottom nav destinations
         */
        val bottomNavScreens =
            listOf(
                Chat,
                History,
                Settings,
            )

        /**
         * Get route from Screen instance
         */
        fun Screen.getRoute(): String = this.route

        /**
         * Check if route is a bottom nav destination
         */
        fun isBottomNavDestination(route: String?): Boolean = bottomNavScreens.any { it.route == route }
    }
}
