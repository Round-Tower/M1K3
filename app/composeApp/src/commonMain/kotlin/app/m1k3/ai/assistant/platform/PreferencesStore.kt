package app.m1k3.ai.assistant.platform

import kotlinx.coroutines.flow.Flow

/**
 * PreferencesStoreInterface.
 *
 * @deprecated Use app.m1k3.ai.domain.platform.PreferencesStoreInterface instead.
 * This typealias exists for backward compatibility.
 */
typealias PreferencesStoreInterface = app.m1k3.ai.domain.platform.PreferencesStoreInterface

/**
 * PreferencesStore - Platform abstraction for key-value preferences.
 *
 * Provides reactive preferences access for feature flags and settings.
 * All operations are thread-safe.
 *
 * **Usage:**
 * ```kotlin
 * val prefs = PreferencesStore(context)  // Android
 *
 * // Sync access
 * val isEnabled = prefs.getBoolean("rag_enabled", true)
 * prefs.setBoolean("rag_enabled", false)
 *
 * // Reactive access
 * prefs.observeBoolean("rag_enabled", true).collect { enabled ->
 *     // React to changes
 * }
 * ```
 */
expect class PreferencesStore : PreferencesStoreInterface {
    // ===== Boolean =====

    /**
     * Get a boolean preference.
     *
     * @param key Preference key
     * @param default Default value if not set
     * @return Current value or default
     */
    override fun getBoolean(
        key: String,
        default: Boolean,
    ): Boolean

    /**
     * Set a boolean preference.
     *
     * @param key Preference key
     * @param value Value to store
     */
    override fun setBoolean(
        key: String,
        value: Boolean,
    )

    /**
     * Observe a boolean preference as a Flow.
     *
     * @param key Preference key
     * @param default Default value if not set
     * @return Flow that emits when preference changes
     */
    override fun observeBoolean(
        key: String,
        default: Boolean,
    ): Flow<Boolean>

    // ===== String =====

    /**
     * Get a string preference.
     *
     * @param key Preference key
     * @param default Default value if not set
     * @return Current value or default
     */
    override fun getString(
        key: String,
        default: String?,
    ): String?

    /**
     * Set a string preference.
     *
     * @param key Preference key
     * @param value Value to store (null removes the preference)
     */
    override fun setString(
        key: String,
        value: String?,
    )

    // ===== Int =====

    /**
     * Get an integer preference.
     *
     * @param key Preference key
     * @param default Default value if not set
     * @return Current value or default
     */
    override fun getInt(
        key: String,
        default: Int,
    ): Int

    /**
     * Set an integer preference.
     *
     * @param key Preference key
     * @param value Value to store
     */
    override fun setInt(
        key: String,
        value: Int,
    )

    // ===== Operations =====

    /**
     * Check if a preference exists.
     *
     * @param key Preference key
     * @return true if preference exists
     */
    override fun contains(key: String): Boolean

    /**
     * Remove a preference.
     *
     * @param key Preference key
     */
    override fun remove(key: String)

    /**
     * Clear all preferences.
     */
    override fun clear()
}

/**
 * Common preference keys used throughout the app.
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

    /** User-set display name (overrides GET_ACCOUNTS detection) */
    const val USER_NAME = "user_name"

    /** Debug mode enabled */
    const val DEBUG_MODE = "debug_mode"

    /** Current project ID */
    const val CURRENT_PROJECT_ID = "current_project_id"

    /** Whether the user has completed first-launch onboarding */
    const val ONBOARDING_COMPLETE = "onboarding_complete"

    /** Selected Kokoro voice ID — matches Voice.id (e.g. "bm_daniel", "af_bella") */
    const val SELECTED_VOICE = "selected_voice"

    /** The M1K3 tier the user selected during onboarding ("mini" / "lil" / "big") */
    const val SELECTED_M1K3_TIER = "selected_m1k3_tier"
}
