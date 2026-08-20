package app.m1k3.ai.domain.platform

/**
 * Preference Keys - Common preference key constants.
 *
 * Centralized constants for preference keys used throughout the app.
 * These are duplicated in the domain layer to avoid app-layer dependencies.
 *
 * **Note:** Keep in sync with `app.m1k3.ai.assistant.platform.PreferenceKeys`
 */
object PreferenceKeys {
    /** RAG (Retrieval-Augmented Generation) enabled */
    const val RAG_ENABLED = "rag_enabled"

    /** Tool calling (agentic capabilities) enabled */
    const val TOOLS_ENABLED = "tools_enabled"

    /** Haptic feedback enabled */
    const val HAPTICS_ENABLED = "haptics_enabled"

    /** Dark mode preference */
    const val DARK_MODE = "dark_mode"

    /** Voice output enabled */
    const val VOICE_ENABLED = "voice_enabled"

    /** Auto voice reply - automatically speak AI responses */
    const val VOICE_AUTO_REPLY = "voice_auto_reply"

    /** Selected avatar model ID */
    const val SELECTED_AVATAR = "selected_avatar"

    /** User-set display name (overrides GET_ACCOUNTS detection) */
    const val USER_NAME = "user_name"

    /** Debug mode enabled */
    const val DEBUG_MODE = "debug_mode"

    /** Current project ID */
    const val CURRENT_PROJECT_ID = "current_project_id"
}
