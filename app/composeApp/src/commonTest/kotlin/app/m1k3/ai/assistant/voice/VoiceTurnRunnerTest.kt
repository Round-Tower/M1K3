package app.m1k3.ai.assistant.voice

import app.m1k3.ai.assistant.chat.ChatMessage
import app.m1k3.ai.assistant.chat.ChatUiState
import app.m1k3.ai.assistant.chat.GenerationState
import app.m1k3.ai.domain.chat.ChatError
import app.m1k3.ai.domain.chat.GenerationStats
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * The whole-answer bridge voice mode uses to run a turn through the SAME
 * ChatScreenViewModel path typed chat uses — no second source of truth.
 * Deliberately decoupled from a real ChatScreenViewModel (no DB/engine
 * scaffolding needed): it only reads a [ChatUiState] flow and calls two
 * plain callbacks, so it's testable with a bare fake.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class VoiceTurnRunnerTest {
    private fun stats() = GenerationStats(tokenCount = 1, durationMs = 1, tokensPerSecond = 1.0f)

    @Test
    fun `sends the question and resolves once generation completes`() =
        runTest {
            val ui = MutableStateFlow(ChatUiState())
            var sentText: String? = null
            var sendCalled = 0

            val job =
                launch {
                    val result =
                        runVoiceTurn(
                            question = "what time is it",
                            uiState = ui,
                            updateInputText = { sentText = it },
                            sendMessage = { sendCalled++ },
                        )
                    assertTrue(result.isSuccess)
                    assertEquals("Half nine.", result.getOrNull())
                }

            // Let the coroutine reach its first suspension (awaiting uiState).
            testScheduler.runCurrent()
            assertEquals("what time is it", sentText)
            assertEquals(1, sendCalled)

            ui.value =
                ui.value.copy(
                    messages = ui.value.messages + ChatMessage(text = "what time is it", isUser = true, timestamp = 0),
                    generationState = GenerationState.Thinking,
                )
            testScheduler.runCurrent()

            ui.value =
                ui.value.copy(
                    generationState = GenerationState.Complete("Half nine.", stats()),
                )
            job.join()
        }

    @Test
    fun `a stale completed state from the PREVIOUS turn does not resolve the new one`() =
        runTest {
            // The generationState is already Complete (from an old turn) BEFORE
            // this turn's question is even sent — the message-count guard is
            // what stops the bridge returning the stale answer immediately.
            val ui =
                MutableStateFlow(
                    ChatUiState(
                        messages = listOf(ChatMessage(text = "old", isUser = false, timestamp = 0)),
                        generationState = GenerationState.Complete("stale answer", stats()),
                    ),
                )

            val job =
                launch {
                    val result =
                        runVoiceTurn(
                            question = "a new question",
                            uiState = ui,
                            updateInputText = {},
                            sendMessage = {},
                        )
                    assertEquals("fresh answer", result.getOrNull())
                }

            testScheduler.runCurrent()
            assertTrue(job.isActive) // must NOT have resolved off the stale state

            ui.value =
                ui.value.copy(
                    messages = ui.value.messages + ChatMessage(text = "a new question", isUser = true, timestamp = 1),
                    generationState = GenerationState.Complete("fresh answer", stats()),
                )
            job.join()
        }

    @Test
    fun `a failed generation surfaces the error message`() =
        runTest {
            val ui = MutableStateFlow(ChatUiState())
            val job =
                launch {
                    val result =
                        runVoiceTurn(
                            question = "q",
                            uiState = ui,
                            updateInputText = {},
                            sendMessage = {},
                        )
                    assertTrue(result.isFailure)
                    assertEquals(
                        "Something went wrong: boom",
                        result.exceptionOrNull()?.message,
                    )
                }
            testScheduler.runCurrent()
            ui.value =
                ui.value.copy(
                    messages = ui.value.messages + ChatMessage(text = "q", isUser = true, timestamp = 0),
                    generationState = GenerationState.Failed(ChatError.Unknown("boom")),
                )
            job.join()
        }

    @Test
    fun `an empty final answer is treated as a failure, not silence`() =
        runTest {
            val ui = MutableStateFlow(ChatUiState())
            val job =
                launch {
                    val result =
                        runVoiceTurn(
                            question = "q",
                            uiState = ui,
                            updateInputText = {},
                            sendMessage = {},
                        )
                    assertTrue(result.isFailure)
                    assertEquals("The model had nothing to say.", result.exceptionOrNull()?.message)
                }
            testScheduler.runCurrent()
            ui.value =
                ui.value.copy(
                    messages = ui.value.messages + ChatMessage(text = "q", isUser = true, timestamp = 0),
                    generationState = GenerationState.Complete("", stats()),
                )
            job.join()
        }
}
