package app.m1k3.ai.assistant.ui.components

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.unit.dp
import app.m1k3.ai.assistant.chat.ChatMessage
import app.m1k3.ai.assistant.design.components.TypingIndicatorBubble
import app.m1k3.ai.assistant.design.preview.PreviewFixtures
import app.m1k3.ai.assistant.design.theme.MaTheme
import app.m1k3.ai.assistant.ui.ChatBubble
import org.jetbrains.compose.ui.tooling.preview.Preview

/**
 * Scrollable list of chat messages with typing indicator.
 *
 * Features:
 * - Lazy loading for performance with large conversations
 * - Typing indicator during AI generation
 * - Proper spacing and padding for overlays (header, input bar)
 * - Content size animation for smooth updates
 *
 * @param messages List of chat messages to display
 * @param isGenerating Whether AI is currently generating a response
 * @param listState LazyList state for scroll control
 * @param modifier Optional modifier for customization
 */
@Composable
fun ChatMessageList(
    messages: List<ChatMessage>,
    isGenerating: Boolean,
    listState: LazyListState,
    onSpeak: ((String) -> Unit)? = null,
    userContext: app.m1k3.ai.domain.context.UserContext? = null,
    onRequestLocation: (() -> Unit)? = null,
    onRequestHealth: (() -> Unit)? = null,
    onRequestScreenTime: (() -> Unit)? = null,
    generationState: app.m1k3.ai.assistant.chat.GenerationState = app.m1k3.ai.assistant.chat.GenerationState.Idle,
    modifier: Modifier = Modifier,
) {
    LazyColumn(
        state = listState,
        modifier =
            modifier
                .testTag("message_list")
                .animateContentSize()
                .fillMaxSize(),
        verticalArrangement = Arrangement.spacedBy(12.dp),
        contentPadding =
            PaddingValues(
                top = 180.dp,
                bottom = 200.dp,
            ),
    ) {
        // Hero splash: while the user hasn't typed yet, replace the
        // small status card with a full-bleed avatar + greeting so the
        // app's personality lands first. Any AI-generated welcome
        // messages still render below the hero.
        val preConversation = messages.none { it.isUser }
        if (preConversation) {
            item {
                ChatHeroSplash(
                    userContext = userContext,
                    onRequestLocation = onRequestLocation,
                    onRequestHealth = onRequestHealth,
                    onRequestScreenTime = onRequestScreenTime,
                )
            }
            items(messages.filter { !it.isStatusMessage }) { message ->
                val isLastAiMessage = !message.isUser && message == messages.lastOrNull { !it.isUser }
                val streamingState = generationState as? app.m1k3.ai.assistant.chat.GenerationState.Streaming
                ChatBubble(
                    message = message,
                    userContext = userContext,
                    onRequestLocation = onRequestLocation,
                    onRequestHealth = onRequestHealth,
                    onRequestScreenTime = onRequestScreenTime,
                    onSpeak = onSpeak,
                    isStreaming = isLastAiMessage && streamingState != null,
                    isThinking = isLastAiMessage && (streamingState?.isThinking == true),
                )
            }
        } else {
            items(messages) { message ->
                val isLastAiMessage = !message.isUser && message == messages.lastOrNull { !it.isUser }
                val streamingState = generationState as? app.m1k3.ai.assistant.chat.GenerationState.Streaming
                ChatBubble(
                    message = message,
                    userContext = userContext,
                    onRequestLocation = onRequestLocation,
                    onRequestHealth = onRequestHealth,
                    onRequestScreenTime = onRequestScreenTime,
                    onSpeak = onSpeak,
                    isStreaming = isLastAiMessage && streamingState != null,
                    isThinking = isLastAiMessage && (streamingState?.isThinking == true),
                )
            }
        }

        // Typing indicator while AI is generating
        if (isGenerating) {
            item {
                TypingIndicatorBubble(
                    modifier =
                        Modifier
                            .fillMaxWidth()
                            .testTag("typing_indicator")
                            .padding(),
                )
            }
        }
    }
}

// ============================================================
// Previews
// ============================================================

@Preview
@Composable
private fun ChatMessageListEmptyPreview() {
    MaTheme {
        ChatMessageList(
            messages = emptyList(),
            isGenerating = false,
            listState = rememberLazyListState(),
            modifier = Modifier.fillMaxSize(),
        )
    }
}

@Preview
@Composable
private fun ChatMessageListWithMessagesPreview() {
    MaTheme {
        ChatMessageList(
            messages =
                listOf(
                    ChatMessage(
                        text = "Hello! How are you?",
                        isUser = true,
                        timestamp = System.currentTimeMillis(),
                    ),
                    ChatMessage(
                        text = "I'm doing great! How can I help you?",
                        isUser = false,
                        timestamp = System.currentTimeMillis(),
                    ),
                ),
            isGenerating = false,
            listState = rememberLazyListState(),
            modifier = Modifier.fillMaxSize(),
        )
    }
}

@Preview
@Composable
private fun ChatMessageListGeneratingPreview() {
    MaTheme {
        ChatMessageList(
            messages =
                listOf(
                    ChatMessage(
                        text = "Tell me about machine learning",
                        isUser = true,
                        timestamp = System.currentTimeMillis(),
                    ),
                ),
            isGenerating = true,
            listState = rememberLazyListState(),
            modifier = Modifier.fillMaxSize(),
        )
    }
}
