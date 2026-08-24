package app.m1k3.ai.domain.voice

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * Port of the Mac's SpeechTextPolish: what TTS actually SAYS should never be
 * the raw markdown/citation-laden chat text. Pure text transform so it's
 * unit-testable without a speech engine.
 */
class SpeechTextPolishTest {
    @Test
    fun `plain text passes through unchanged`() {
        assertEquals("Half nine.", SpeechTextPolish.polish("Half nine."))
    }

    @Test
    fun `strips bold and italic emphasis markers`() {
        assertEquals("The answer is 42.", SpeechTextPolish.polish("The answer is **42**."))
        assertEquals("A dry wit.", SpeechTextPolish.polish("A *dry* wit."))
        assertEquals("Underlined word.", SpeechTextPolish.polish("_Underlined_ word."))
    }

    @Test
    fun `strips inline code backticks`() {
        assertEquals("Run npm install first.", SpeechTextPolish.polish("Run `npm install` first."))
    }

    @Test
    fun `drops fenced code blocks entirely`() {
        val raw = "Here you go:\n```kotlin\nval x = 1\n```\nDone."
        assertEquals("Here you go:\n\nDone.", SpeechTextPolish.polish(raw))
    }

    @Test
    fun `markdown links speak the label only`() {
        assertEquals("See the docs for more.", SpeechTextPolish.polish("See the [docs](https://example.com/x) for more."))
    }

    @Test
    fun `bare urls speak the host only`() {
        assertEquals(
            "Find it at example.com.",
            SpeechTextPolish.polish("Find it at https://example.com/path?x=1."),
        )
    }

    @Test
    fun `drops think blocks`() {
        assertEquals(
            "The answer is 42.",
            SpeechTextPolish.polish("<think>let me reason about this</think>The answer is 42."),
        )
    }

    @Test
    fun `collapses excess whitespace left behind by stripping`() {
        assertEquals("One two.", SpeechTextPolish.polish("One **  ** two."))
    }

    @Test
    fun `blank input polishes to blank`() {
        assertEquals("", SpeechTextPolish.polish(""))
        assertEquals("", SpeechTextPolish.polish("   "))
    }
}
