package app.m1k3.ai.domain.voice

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class UtteranceCompletenessTest {
    @Test
    fun `sentence punctuation is complete`() {
        assertTrue(UtteranceCompleteness.looksComplete("What time is it?"))
        assertTrue(UtteranceCompleteness.looksComplete("Set a timer."))
    }

    @Test
    fun `dangling words and commas are incomplete`() {
        assertFalse(UtteranceCompleteness.looksComplete("tell me about the"))
        assertFalse(UtteranceCompleteness.looksComplete("I was thinking,"))
        assertFalse(UtteranceCompleteness.looksComplete("so, um"))
        assertFalse(UtteranceCompleteness.looksComplete(""))
    }

    @Test
    fun `unpunctuated but whole reads complete`() {
        assertTrue(UtteranceCompleteness.looksComplete("what time is it"))
    }
}
