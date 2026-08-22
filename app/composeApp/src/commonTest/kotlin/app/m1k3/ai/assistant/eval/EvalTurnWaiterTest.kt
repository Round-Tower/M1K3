package app.m1k3.ai.assistant.eval

import app.m1k3.ai.assistant.chat.GenerationState
import app.m1k3.ai.domain.chat.GenerationStats
import kotlinx.coroutines.async
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

private fun stats(tokens: Int) = GenerationStats(tokenCount = tokens, durationMs = 100, tokensPerSecond = 10f)

class EvalTurnWaiterTest {
    @Test
    fun `does not match a stale terminal state left over from a previous turn`() =
        runTest {
            // The exact live bug: the flow starts already Complete (fixture 1's
            // answer), and sendMessage()'s Thinking/Streaming/Complete for the
            // NEW turn hasn't landed yet.
            val states = MutableStateFlow<GenerationState>(GenerationState.Complete("stale answer", stats(1)))

            val outcome =
                async {
                    waitForTurnCompletion(states, turnStartTimeoutMs = 10_000, fixtureTimeoutMs = 10_000)
                }
            runCurrent()

            states.value = GenerationState.Thinking
            runCurrent()
            states.value = GenerationState.Streaming(partialText = "fr", tokenCount = 1)
            runCurrent()
            states.value = GenerationState.Complete("fresh answer", stats(2))

            val terminal = outcome.await()
            assertTrue(terminal is GenerationState.Complete)
            assertEquals("fresh answer", terminal.finalText)
        }

    @Test
    fun `the very first turn, starting from Idle, is not treated as already-terminal`() =
        runTest {
            val states = MutableStateFlow<GenerationState>(GenerationState.Idle)

            val outcome = async { waitForTurnCompletion(states, turnStartTimeoutMs = 10_000, fixtureTimeoutMs = 10_000) }
            runCurrent()

            states.value = GenerationState.Thinking
            runCurrent()
            states.value = GenerationState.Complete("hello", stats(1))

            val terminal = outcome.await()
            assertTrue(terminal is GenerationState.Complete)
            assertEquals("hello", terminal.finalText)
        }

    @Test
    fun `a Failed terminal state is returned, not just Complete`() =
        runTest {
            val states = MutableStateFlow<GenerationState>(GenerationState.Idle)
            val outcome = async { waitForTurnCompletion(states, turnStartTimeoutMs = 10_000, fixtureTimeoutMs = 10_000) }
            runCurrent()

            states.value = GenerationState.Streaming(partialText = "", tokenCount = 0)
            runCurrent()
            states.value =
                GenerationState.Failed(
                    app.m1k3.ai.domain.chat.ChatError
                        .Timeout("too slow"),
                )

            assertTrue(outcome.await() is GenerationState.Failed)
        }

    @Test
    fun `returns null when the turn never leaves a terminal state (never starts)`() =
        runTest {
            val states = MutableStateFlow<GenerationState>(GenerationState.Complete("stale", stats(1)))
            val terminal = waitForTurnCompletion(states, turnStartTimeoutMs = 1_000, fixtureTimeoutMs = 1_000)
            assertNull(terminal)
        }

    @Test
    fun `returns null when the turn starts but never finishes`() =
        runTest {
            val states = MutableStateFlow<GenerationState>(GenerationState.Idle)
            val outcome = async { waitForTurnCompletion(states, turnStartTimeoutMs = 5_000, fixtureTimeoutMs = 1_000) }
            runCurrent()
            states.value = GenerationState.Thinking
            // Never emits Complete/Failed — the fixture timeout must fire.
            assertNull(outcome.await())
        }

    @Test
    fun `onStreaming fires once per observed Streaming state before the terminal one`() =
        runTest {
            val states = MutableStateFlow<GenerationState>(GenerationState.Idle)
            var streamingHits = 0
            val outcome =
                async {
                    waitForTurnCompletion(
                        states,
                        turnStartTimeoutMs = 10_000,
                        fixtureTimeoutMs = 10_000,
                        onStreaming = { streamingHits++ },
                    )
                }
            runCurrent()
            states.value = GenerationState.Streaming(partialText = "a", tokenCount = 1)
            runCurrent()
            states.value = GenerationState.Complete("a", stats(1))

            outcome.await()
            assertEquals(1, streamingHits)
        }
}
