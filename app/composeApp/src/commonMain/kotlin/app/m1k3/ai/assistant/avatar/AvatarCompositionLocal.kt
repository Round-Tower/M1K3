package app.m1k3.ai.assistant.avatar

import androidx.compose.runtime.compositionLocalOf
import androidx.compose.runtime.staticCompositionLocalOf

/**
 * CompositionLocal providers for shared avatar state across all screens.
 *
 * Enables centralized avatar management in MainActivity while allowing
 * all screens to access and update avatar state without prop drilling.
 *
 * Usage:
 * ```kotlin
 * // In MainActivity:
 * val appAvatarVM = rememberAvatarViewModel()
 * CompositionLocalProvider(
 *     LocalSharedAvatarVM provides appAvatarVM
 * ) {
 *     // All screens can now access via CompositionLocal
 * }
 *
 * // In any screen:
 * val avatarVM = LocalSharedAvatarVM.current
 * avatarVM.setEmotion(AvatarEmotion.HAPPY)
 * ```
 */

/**
 * Provides the shared AvatarViewModel for all screens.
 *
 * Use this to:
 * - Update avatar emotion/activity from any screen
 * - Sync with AI generation state
 * - Process messages for emotion detection
 * - Control avatar animations
 *
 * Scope: App-level (MainActivity), persists across screen transitions.
 * Lifecycle: Bound to MainActivity's lifecycle, not individual screen lifecycle.
 */
val LocalSharedAvatarVM =
    staticCompositionLocalOf<AvatarViewModel?> {
        null
    }

/**
 * Provides the current AvatarState for UI rendering.
 *
 * This is a derived state - updates automatically when the ViewModel's
 * internal state changes. Use this in Composables to render avatar.
 *
 * Example:
 * ```kotlin
 * val avatarState by LocalSharedAvatarState.current
 *     ?: return // Handle null case
 *
 * DotMatrixAvatar(state = avatarState, modifier = Modifier.size(100.dp))
 * ```
 */
val LocalSharedAvatarState =
    staticCompositionLocalOf<AvatarState?> {
        null
    }
