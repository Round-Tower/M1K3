package app.m1k3.ai.domain.ai

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class PromptBudgetTest {
    @Test
    fun `text within budget is returned unchanged`() {
        val text = "short question"
        assertEquals(text, PromptBudget.trimToBudget(text, maxTokens = 1000))
    }

    @Test
    fun `text over budget is trimmed to fit`() {
        val text = "x".repeat(10_000)
        val trimmed = PromptBudget.trimToBudget(text, maxTokens = 100, charsPerToken = 4.0)
        assertTrue(trimmed.length <= 400)
    }

    @Test
    fun `trimming keeps the tail, not the head`() {
        val text = "HEAD_MARKER " + "filler ".repeat(2000) + "TAIL_MARKER"
        val trimmed = PromptBudget.trimToBudget(text, maxTokens = 50, charsPerToken = 4.0)
        assertTrue(trimmed.contains("TAIL_MARKER"))
        assertTrue(!trimmed.contains("HEAD_MARKER"))
    }

    @Test
    fun `zero or negative budget yields empty string`() {
        assertEquals("", PromptBudget.trimToBudget("anything", maxTokens = 0))
        assertEquals("", PromptBudget.trimToBudget("anything", maxTokens = -5))
    }

    @Test
    fun `estimateTokens is roughly length over chars-per-token`() {
        val text = "x".repeat(700)
        val estimate = PromptBudget.estimateTokens(text, charsPerToken = 3.5)
        assertEquals(200, estimate)
    }
}
