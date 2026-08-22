package app.m1k3.ai.domain.chat

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * TDD tests for StreamingThinkTagParser.
 *
 * Extracts <think>...</think> blocks from a token stream in real-time,
 * separating thinking content from visible text. Handles Qwen3.5's
 * "< think>" tokenization quirk (space before tag name).
 */
class StreamingThinkTagParserTest {
    @Test
    fun `plain text without think tags passes through`() {
        val parser = StreamingThinkTagParser()
        parser.feed("Hello ")
        parser.feed("world!")

        assertEquals("Hello world!", parser.visibleText)
        assertNull(parser.thinkingContent)
        assertFalse(parser.isThinking)
    }

    @Test
    fun `complete think block in single token is extracted`() {
        val parser = StreamingThinkTagParser()
        parser.feed("<think>I need to greet warmly</think>Hey there!")

        assertEquals("Hey there!", parser.visibleText)
        assertEquals("I need to greet warmly", parser.thinkingContent)
        assertFalse(parser.isThinking)
    }

    @Test
    fun `think block split across multiple tokens`() {
        val parser = StreamingThinkTagParser()
        parser.feed("<think>")
        parser.feed("Analyzing the request")
        parser.feed("</think>")
        parser.feed("Hello!")

        assertEquals("Hello!", parser.visibleText)
        assertEquals("Analyzing the request", parser.thinkingContent)
        assertFalse(parser.isThinking)
    }

    @Test
    fun `isThinking true while inside think block`() {
        val parser = StreamingThinkTagParser()
        parser.feed("<think>")
        assertTrue(parser.isThinking)

        parser.feed("reasoning...")
        assertTrue(parser.isThinking)

        parser.feed("</think>")
        assertFalse(parser.isThinking)
    }

    @Test
    fun `qwen3 spaced think tag is handled`() {
        val parser = StreamingThinkTagParser()
        parser.feed("< think>")
        assertTrue(parser.isThinking)

        parser.feed("reasoning")
        parser.feed("</ think>")

        assertFalse(parser.isThinking)
        assertEquals("reasoning", parser.thinkingContent)
        assertEquals("", parser.visibleText)
    }

    @Test
    fun `text before think block is preserved`() {
        val parser = StreamingThinkTagParser()
        parser.feed("Hi <think>reasoning</think> friend!")

        assertEquals("Hi  friend!", parser.visibleText)
        assertEquals("reasoning", parser.thinkingContent)
    }

    @Test
    fun `think tag split across token boundary`() {
        // Token arrives as "<thi" then "nk>stuff</think>"
        val parser = StreamingThinkTagParser()
        parser.feed("<thi")
        parser.feed("nk>stuff</think>visible")

        assertEquals("visible", parser.visibleText)
        assertEquals("stuff", parser.thinkingContent)
    }

    @Test
    fun `unclosed think block during streaming`() {
        val parser = StreamingThinkTagParser()
        parser.feed("<think>")
        parser.feed("still thinking...")

        assertTrue(parser.isThinking)
        assertEquals("still thinking...", parser.thinkingContent)
        assertEquals("", parser.visibleText)
    }

    @Test
    fun `reset clears all state`() {
        val parser = StreamingThinkTagParser()
        parser.feed("Hello <think>thought</think>world")
        parser.reset()

        assertEquals("", parser.visibleText)
        assertNull(parser.thinkingContent)
        assertFalse(parser.isThinking)
    }

    @Test
    fun `case insensitive tags`() {
        val parser = StreamingThinkTagParser()
        parser.feed("<THINK>reasoning</THINK>visible")

        assertEquals("visible", parser.visibleText)
        assertEquals("reasoning", parser.thinkingContent)
    }

    @Test
    fun `thinking duration tracked from open to close`() {
        val parser = StreamingThinkTagParser()
        parser.feed("<think>")
        // thinkingStartMs should be set
        assertTrue(parser.thinkingStartMs > 0)

        parser.feed("</think>")
        assertTrue(parser.thinkingDurationMs >= 0)
    }

    @Test
    fun `empty think block`() {
        val parser = StreamingThinkTagParser()
        parser.feed("<think></think>Hello")

        assertEquals("Hello", parser.visibleText)
        // Empty thinking content should be null (nothing useful to show)
        assertNull(parser.thinkingContent)
        assertFalse(parser.isThinking)
    }

    // --- Finalize: unclosed think tags ---

    @Test
    fun `finalize recovers visible text from unclosed think tag`() {
        val parser = StreamingThinkTagParser()
        parser.feed("<think>I need to think about this carefully...")
        // Model never emits </think> — generation ends
        assertTrue(parser.isThinking)
        assertEquals("", parser.visibleText) // Stuck in thinking

        parser.finalize()

        // After finalize: thinking content becomes visible text
        assertFalse(parser.isThinking)
        assertTrue(parser.visibleText.contains("I need to think about this carefully"))
    }

    @Test
    fun `finalize sets thinking duration for unclosed tag`() {
        val parser = StreamingThinkTagParser()
        parser.feed("<think>reasoning...")
        assertEquals(0L, parser.thinkingDurationMs) // Not set until close

        parser.finalize()

        assertTrue(parser.thinkingDurationMs >= 0L, "Duration should be calculated on finalize")
    }

    @Test
    fun `finalize is no-op when think tag properly closed`() {
        val parser = StreamingThinkTagParser()
        parser.feed("<think>thinking</think>Hello visible")
        val visibleBefore = parser.visibleText

        parser.finalize()

        assertEquals(visibleBefore, parser.visibleText, "Finalize should not alter properly closed output")
    }

    @Test
    fun `finalize flushes pending buffer`() {
        val parser = StreamingThinkTagParser()
        parser.feed("Hello <") // Partial tag buffered
        // pending buffer has "<" — not flushed yet
        parser.finalize()

        assertTrue(parser.visibleText.contains("Hello"), "Finalize should flush pending buffer")
    }

    @Test
    fun `startInThinking routes leading tokens to thinking until close tag`() {
        // Native-chat path: Qwen template ends with `<|im_start|>assistant\n<think>\n`
        // so the stream starts INSIDE a think block without an opener token.
        val parser = StreamingThinkTagParser(startInThinking = true)
        parser.feed("The user is asking about battery.\n")
        parser.feed("</think>\n\nBattery response.")

        assertEquals("The user is asking about battery.\n", parser.thinkingContent)
        assertTrue(parser.visibleText.contains("Battery response"))
        assertFalse(parser.isThinking, "Should exit thinking mode after </think>")
    }

    @Test
    fun `startInThinking with no closing tag keeps all content in thinking then promotes on finalize`() {
        val parser = StreamingThinkTagParser(startInThinking = true)
        parser.feed("Reasoning without a closer.")
        parser.finalize()

        assertTrue(parser.visibleText.contains("Reasoning without a closer"))
    }

    @Test
    fun `startInThinking captures thinkingStartMs at construction`() {
        val before =
            kotlin.time.Clock.System
                .now()
                .toEpochMilliseconds()
        val parser = StreamingThinkTagParser(startInThinking = true)
        val after =
            kotlin.time.Clock.System
                .now()
                .toEpochMilliseconds()

        assertTrue(
            parser.thinkingStartMs in before..after,
            "startInThinking should seed thinkingStartMs at construction so durations come out right",
        )
    }
}
