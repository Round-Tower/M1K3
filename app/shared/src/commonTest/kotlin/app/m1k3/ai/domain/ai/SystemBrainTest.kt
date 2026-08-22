package app.m1k3.ai.domain.ai

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * TDD coverage for [MiniBrainPolicy.resolve] — the rule that decides whether
 * [M1K3Tier.Mini] answers via the platform's own system model (Gemini Nano on
 * Android) or falls back to our Qwen3.5-0.8B weights.
 */
class SystemBrainTest {
    @Test
    fun `available system model resolves to SystemModel`() {
        val result = MiniBrainPolicy.resolve(SystemBrainAvailability.Available)
        assertEquals(MiniBrain.SystemModel, result)
    }

    @Test
    fun `downloadable system model resolves to SystemModel`() {
        val result = MiniBrainPolicy.resolve(SystemBrainAvailability.Downloadable(sizeHintMb = 1400))
        assertEquals(MiniBrain.SystemModel, result)
    }

    @Test
    fun `downloading system model resolves to SystemModel`() {
        val result = MiniBrainPolicy.resolve(SystemBrainAvailability.Downloading(percent = 40))
        assertEquals(MiniBrain.SystemModel, result)
    }

    @Test
    fun `unavailable system model falls back to Qwen weights`() {
        val result = MiniBrainPolicy.resolve(SystemBrainAvailability.Unavailable("device not eligible"))
        assertEquals(MiniBrain.Weights(LlmModel.Qwen35_0B8), result)
    }

    @Test
    fun `unavailable falls back regardless of qwenDownloaded flag`() {
        val downloaded = MiniBrainPolicy.resolve(SystemBrainAvailability.Unavailable("x"), qwenDownloaded = true)
        val notDownloaded = MiniBrainPolicy.resolve(SystemBrainAvailability.Unavailable("x"), qwenDownloaded = false)
        assertEquals(downloaded, notDownloaded)
    }
}
