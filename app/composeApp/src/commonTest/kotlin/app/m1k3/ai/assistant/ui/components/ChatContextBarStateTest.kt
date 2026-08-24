package app.m1k3.ai.assistant.ui.components

import app.m1k3.ai.assistant.chat.ChatUiState
import app.m1k3.ai.assistant.chat.ContextWindowState
import app.m1k3.ai.assistant.chat.GenerationState
import app.m1k3.ai.assistant.chat.ToolExecutionResult
import app.m1k3.ai.assistant.chat.ToolState
import app.m1k3.ai.domain.ai.LlmModel
import app.m1k3.ai.domain.chat.GenerationStats
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Tests for the pure-data mapper that reduces ChatUiState into the
 * compact shape the ChatContextBar needs — keeps the composable
 * deterministic and the mapping logic verifiable off-device.
 */
class ChatContextBarStateTest {
    @Test
    fun `from maps model and context percent from ChatUiState`() {
        val uiState =
            ChatUiState(
                currentModel = LlmModel.Qwen35_2B,
                contextWindow =
                    ContextWindowState(
                        historyMessageCount = 4,
                        historyTokens = 1024,
                        maxContextTokens = 4096,
                        deviceTier = "Flagship",
                    ),
            )

        val state = ChatContextBarState.from(uiState, isListening = false, partialTranscript = "")

        assertEquals(LlmModel.Qwen35_2B, state.currentModel)
        assertEquals(25, state.contextPercent)
    }

    @Test
    fun `context percent clamps above 100 to 100`() {
        val uiState =
            ChatUiState(
                contextWindow =
                    ContextWindowState(
                        historyTokens = 8000,
                        maxContextTokens = 4096,
                    ),
            )

        val state = ChatContextBarState.from(uiState, isListening = false, partialTranscript = "")

        assertEquals(100, state.contextPercent)
    }

    @Test
    fun `last tokens per second populated only when generation complete`() {
        val streaming =
            ChatUiState(
                generationState =
                    GenerationState.Streaming(
                        partialText = "hi",
                        tokenCount = 3,
                    ),
            )
        assertNull(
            ChatContextBarState
                .from(streaming, isListening = false, partialTranscript = "")
                .lastTokensPerSecond,
        )

        val complete =
            ChatUiState(
                generationState =
                    GenerationState.Complete(
                        finalText = "done",
                        stats =
                            GenerationStats(
                                tokenCount = 42,
                                durationMs = 2800,
                                tokensPerSecond = 15.3f,
                            ),
                    ),
            )
        assertEquals(
            15.3f,
            ChatContextBarState
                .from(complete, isListening = false, partialTranscript = "")
                .lastTokensPerSecond,
        )
    }

    @Test
    fun `listening state takes priority over tool execution in status slot`() {
        val uiState =
            ChatUiState(
                toolState =
                    ToolState(
                        isExecuting = true,
                        executedTools = listOf(ToolExecutionResult(toolId = "battery", displayResult = "", isSuccess = true)),
                    ),
            )

        val state =
            ChatContextBarState.from(
                uiState,
                isListening = true,
                partialTranscript = "testing one two",
            )

        assertTrue(state.status is ChatContextBarStatus.Listening)
        assertEquals("testing one two", (state.status as ChatContextBarStatus.Listening).partial)
    }

    @Test
    fun `tool execution populates status slot when not listening`() {
        val uiState =
            ChatUiState(
                toolState =
                    ToolState(
                        isExecuting = true,
                        executedTools = listOf(ToolExecutionResult(toolId = "web_search", displayResult = "", isSuccess = true)),
                    ),
            )

        val state = ChatContextBarState.from(uiState, isListening = false, partialTranscript = "")

        assertTrue(state.status is ChatContextBarStatus.ToolRunning)
        assertEquals("web_search", (state.status as ChatContextBarStatus.ToolRunning).toolId)
    }

    @Test
    fun `idle generation with no tools returns Idle status`() {
        val uiState = ChatUiState()

        val state = ChatContextBarState.from(uiState, isListening = false, partialTranscript = "")

        assertEquals(ChatContextBarStatus.Idle, state.status)
    }
}
