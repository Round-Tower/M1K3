package app.m1k3.ai.assistant.design.haptics

import android.view.HapticFeedbackConstants
import android.view.View
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalView

/**
 * M1K3 Haptic Feedback System
 *
 * Provides tactile feedback for user interactions:
 * - Light touch feedback for typing, button presses
 * - Medium feedback for confirmations, send actions
 * - Strong feedback for errors, important events
 *
 * Philosophy: Subtle, intentional haptics that enhance UX without being intrusive
 */

/**
 * Haptic feedback intensity levels
 */
enum class HapticFeedbackType {
    /**
     * Light tap - For UI interactions, typing start
     * Android: KEYBOARD_TAP
     */
    LIGHT,

    /**
     * Medium click - For button presses, confirmations
     * Android: VIRTUAL_KEY
     */
    MEDIUM,

    /**
     * Strong feedback - For important actions, send messages
     * Android: LONG_PRESS
     */
    STRONG,

    /**
     * Success pattern - For successful operations
     * Android: CONFIRM
     */
    SUCCESS,

    /**
     * Error pattern - For errors, validation failures
     * Android: REJECT
     */
    ERROR
}

/**
 * Haptic feedback controller
 *
 * Manages haptic feedback across the app with consistent patterns.
 */
class HapticFeedbackController(private val view: View) {

    /**
     * Trigger haptic feedback
     *
     * @param type Feedback intensity/type
     * @param enabled Whether haptics are enabled (user preference)
     */
    fun performHapticFeedback(
        type: HapticFeedbackType,
        enabled: Boolean = true
    ) {
        if (!enabled) return

        val feedbackConstant = when (type) {
            HapticFeedbackType.LIGHT -> HapticFeedbackConstants.KEYBOARD_TAP
            HapticFeedbackType.MEDIUM -> HapticFeedbackConstants.VIRTUAL_KEY
            HapticFeedbackType.STRONG -> HapticFeedbackConstants.LONG_PRESS
            HapticFeedbackType.SUCCESS -> {
                // API 30+ has CONFIRM, fallback to VIRTUAL_KEY
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                    HapticFeedbackConstants.CONFIRM
                } else {
                    HapticFeedbackConstants.VIRTUAL_KEY
                }
            }
            HapticFeedbackType.ERROR -> {
                // API 30+ has REJECT, fallback to LONG_PRESS
                if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.R) {
                    HapticFeedbackConstants.REJECT
                } else {
                    HapticFeedbackConstants.LONG_PRESS
                }
            }
        }

        view.performHapticFeedback(
            feedbackConstant,
            HapticFeedbackConstants.FLAG_IGNORE_VIEW_SETTING
        )
    }

    /**
     * Light tap feedback - For subtle interactions
     */
    fun light(enabled: Boolean = true) = performHapticFeedback(HapticFeedbackType.LIGHT, enabled)

    /**
     * Medium click feedback - For button presses
     */
    fun medium(enabled: Boolean = true) = performHapticFeedback(HapticFeedbackType.MEDIUM, enabled)

    /**
     * Strong feedback - For important actions
     */
    fun strong(enabled: Boolean = true) = performHapticFeedback(HapticFeedbackType.STRONG, enabled)

    /**
     * Success feedback - For successful operations
     */
    fun success(enabled: Boolean = true) = performHapticFeedback(HapticFeedbackType.SUCCESS, enabled)

    /**
     * Error feedback - For errors
     */
    fun error(enabled: Boolean = true) = performHapticFeedback(HapticFeedbackType.ERROR, enabled)
}

/**
 * Remember haptic feedback controller
 *
 * Creates a haptic feedback controller tied to the current view.
 *
 * @return HapticFeedbackController instance
 */
@Composable
fun rememberHapticFeedback(): HapticFeedbackController {
    val view = LocalView.current
    return remember(view) { HapticFeedbackController(view) }
}

/**
 * Usage Examples:
 * ```kotlin
 * @Composable
 * fun ChatInput() {
 *     val haptics = rememberHapticFeedback()
 *     var text by remember { mutableStateOf("") }
 *
 *     TextField(
 *         value = text,
 *         onValueChange = {
 *             if (text.isEmpty() && it.isNotEmpty()) {
 *                 haptics.light()  // Feedback when typing starts
 *             }
 *             text = it
 *         }
 *     )
 *
 *     Button(
 *         onClick = {
 *             haptics.strong()  // Feedback on send
 *             sendMessage(text)
 *         }
 *     ) {
 *         Text("Send")
 *     }
 * }
 *
 * @Composable
 * fun ErrorDialog() {
 *     val haptics = rememberHapticFeedback()
 *
 *     LaunchedEffect(Unit) {
 *         haptics.error()  // Feedback when error appears
 *     }
 * }
 * ```
 */
