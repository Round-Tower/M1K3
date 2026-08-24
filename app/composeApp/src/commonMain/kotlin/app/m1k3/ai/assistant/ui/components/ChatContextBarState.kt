package app.m1k3.ai.assistant.ui.components

import app.m1k3.ai.assistant.chat.ChatUiState
import app.m1k3.ai.assistant.chat.GenerationState
import app.m1k3.ai.domain.ai.LlmModel

/**
 * Compact, immutable slice of ChatUiState that the ChatContextBar renders.
 *
 * Pure data — no Compose references — so the mapping logic is unit-testable
 * and the composable stays a thin renderer over deterministic inputs.
 */
data class ChatContextBarState(
    val currentModel: LlmModel,
    val contextPercent: Int,
    val lastTokensPerSecond: Float?,
    val status: ChatContextBarStatus,
) {
    companion object {
        fun from(
            uiState: ChatUiState,
            isListening: Boolean,
            partialTranscript: String,
        ): ChatContextBarState {
            val percent =
                uiState.contextWindow.usagePercent
                    .toInt()
                    .coerceIn(0, 100)
            val tokensPerSecond =
                (uiState.generationState as? GenerationState.Complete)
                    ?.stats
                    ?.tokensPerSecond
            val status = resolveStatus(uiState, isListening, partialTranscript)

            return ChatContextBarState(
                currentModel = uiState.currentModel,
                contextPercent = percent,
                lastTokensPerSecond = tokensPerSecond,
                status = status,
            )
        }

        private fun resolveStatus(
            uiState: ChatUiState,
            isListening: Boolean,
            partialTranscript: String,
        ): ChatContextBarStatus =
            when {
                isListening -> {
                    ChatContextBarStatus.Listening(partialTranscript)
                }

                uiState.toolState.isExecuting -> {
                    val toolId =
                        uiState.toolState.executedTools
                            .lastOrNull()
                            ?.toolId ?: "tool"
                    ChatContextBarStatus.ToolRunning(toolId)
                }

                else -> {
                    ChatContextBarStatus.Idle
                }
            }
    }
}

/**
 * Discriminated status slot — drives the third zone of the context bar.
 * Listening overtakes the whole bar; ToolRunning is a subtle inline chip.
 */
sealed class ChatContextBarStatus {
    data object Idle : ChatContextBarStatus()

    data class ToolRunning(
        val toolId: String,
    ) : ChatContextBarStatus()

    data class Listening(
        val partial: String,
    ) : ChatContextBarStatus()
}
