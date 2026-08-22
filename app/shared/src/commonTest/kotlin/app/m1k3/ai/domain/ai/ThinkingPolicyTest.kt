package app.m1k3.ai.domain.ai

import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Pixel 9a, 2026-08-22: Qwen3.5-0.8B (Mini) spent its entire 2048-token
 * budget inside <think> — 171s at ~12 tok/s — and never answered. Thinking
 * is a Big-tier capability on a phone.
 */
class ThinkingPolicyTest {
    @AfterTest
    fun resetOverride() {
        ThinkingPolicy.override = null
    }

    @Test
    fun `only Big thinks`() {
        assertTrue(ThinkingPolicy.enabled(LlmModel.Gemma4_E2B))
        assertFalse(ThinkingPolicy.enabled(LlmModel.Qwen35_0B8))
        assertFalse(ThinkingPolicy.enabled(LlmModel.Qwen35_2B))
    }

    @Test
    fun `override forces thinking on regardless of tier`() {
        ThinkingPolicy.override = true
        assertTrue(ThinkingPolicy.enabled(LlmModel.Qwen35_0B8))
        assertTrue(ThinkingPolicy.enabled(LlmModel.Qwen35_2B))
        assertTrue(ThinkingPolicy.enabled(LlmModel.Gemma4_E2B))
    }

    @Test
    fun `override forces thinking off regardless of tier`() {
        ThinkingPolicy.override = false
        assertFalse(ThinkingPolicy.enabled(LlmModel.Gemma4_E2B))
    }

    @Test
    fun `null override restores the per-model default`() {
        ThinkingPolicy.override = true
        ThinkingPolicy.override = null
        assertFalse(ThinkingPolicy.enabled(LlmModel.Qwen35_0B8))
        assertTrue(ThinkingPolicy.enabled(LlmModel.Gemma4_E2B))
    }
}
