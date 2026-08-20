package app.m1k3.ai.assistant.ui.components

import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.staticCompositionLocalOf

/**
 * Actions the top-level Toolbar can render on behalf of the current screen.
 *
 * Lets a screen (today: ChatScreen) publish its own callbacks up to the
 * shared Toolbar without the parent Scaffold having to know about them.
 * The local is provided above the Scaffold, and screens mutate the
 * backing MutableState to publish (or clear) their callbacks per lifecycle.
 *
 * When `onNewChat` is null the Toolbar hides the affordance entirely.
 */
data class ToolbarActions(
    val onNewChat: (() -> Unit)? = null,
)

val LocalToolbarActions =
    staticCompositionLocalOf<State<ToolbarActions>> {
        mutableStateOf(ToolbarActions())
    }
