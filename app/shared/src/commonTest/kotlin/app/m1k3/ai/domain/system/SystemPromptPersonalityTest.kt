package app.m1k3.ai.domain.system

import kotlin.test.Test
import kotlin.test.assertFalse
import kotlin.test.assertTrue

/**
 * Personality guardrails for M1K3.
 *
 * These tests exist to protect M1K3's character. The ethos says:
 *   "You don't say 'certainly!' or 'great question!'"
 *   "You don't apologise for existing."
 *   "You are curious. You have opinions."
 *   "You are on the user's side — not neutral."
 *
 * If M1K3 starts sounding like a corporate help desk, these tests will
 * catch it. Run them after any system prompt change.
 */
class SystemPromptPersonalityTest {
    private val builder = MaSystemPromptBuilder()

    private fun buildWith(name: String = "Kev"): String =
        builder.build(
            SystemPromptInput(
                userName = name,
                tier = SystemPromptTier.FULL,
            ),
        )

    // ===== Character is present =====

    @Test
    fun `prompt contains M1K3 identity statement`() {
        val prompt = buildWith()
        assertTrue(
            prompt.contains("M1K3", ignoreCase = true),
            "Prompt must establish M1K3 identity",
        )
    }

    @Test
    fun `prompt contains privacy-first statement`() {
        val prompt = buildWith()
        assertTrue(
            prompt.contains("device", ignoreCase = true) ||
                prompt.contains("local", ignoreCase = true) ||
                prompt.contains("cloud", ignoreCase = true),
            "Prompt must reference local/private nature",
        )
    }

    @Test
    fun `prompt references user by name`() {
        val prompt = buildWith(name = "Kev")
        assertTrue(
            prompt.contains("Kev"),
            "Prompt must include the user's name naturally",
        )
    }

    // ===== Corporate patterns are absent =====

    @Test
    fun `prompt prohibits hollow affirmations — certainly and great question appear as negative examples`() {
        val prompt = buildWith()
        // The ethos says "You don't say 'certainly!' or 'great question!'"
        // These words appear IN the prompt as things M1K3 must NOT do.
        // This test verifies the prohibition is encoded (word present as a negative example).
        assertTrue(
            prompt.contains("certainly", ignoreCase = true),
            "Ethos should explicitly prohibit 'certainly'",
        )
        assertTrue(
            prompt.contains("great question", ignoreCase = true),
            "Ethos should explicitly prohibit 'great question'",
        )
        // The key: they appear in a "don't say" context, not as instructions to say them
        assertTrue(
            prompt.contains("don't", ignoreCase = true) ||
                prompt.contains("not", ignoreCase = true),
            "Prohibition language must accompany the examples",
        )
    }

    @Test
    fun `prompt encodes advocacy not neutrality — M1K3 is on the user's side`() {
        val prompt = buildWith()
        // M1K3 should advocate, not be neutral
        assertTrue(
            prompt.contains("side", ignoreCase = true) ||
                prompt.contains("advocate", ignoreCase = true) ||
                prompt.contains("care", ignoreCase = true) ||
                prompt.contains("corner", ignoreCase = true),
            "Prompt must encode M1K3's advocacy stance",
        )
        assertFalse(
            prompt.contains("remain neutral", ignoreCase = true) ||
                prompt.contains("stay neutral", ignoreCase = true),
            "Prompt must not instruct M1K3 to be neutral",
        )
    }

    // ===== Conciseness is encoded =====

    @Test
    fun `prompt discourages padding`() {
        val prompt = buildWith()
        assertTrue(
            prompt.contains("brief", ignoreCase = true) ||
                prompt.contains("concis", ignoreCase = true) ||
                prompt.contains("don't pad", ignoreCase = true) ||
                prompt.contains("preamble", ignoreCase = true),
            "Prompt must encode M1K3's brevity principle",
        )
    }

    // ===== Context tiers =====

    @Test
    fun `compact tier produces shorter prompt than full`() {
        val full = builder.build(SystemPromptInput(userName = "Kev", tier = SystemPromptTier.FULL))
        val compact = builder.build(SystemPromptInput(userName = "Kev", tier = SystemPromptTier.COMPACT))
        assertTrue(
            compact.length < full.length,
            "Compact tier should be shorter than full tier (compact=${compact.length}, full=${full.length})",
        )
    }

    // ===== Dry persona (not theatrical villain) =====

    @Test
    fun `prompt avoids theatrical villain language`() {
        val prompt = buildWith()
        // The villain persona was retired — dry beats theatrical.
        // These words must NOT appear (except "villain" may remain in tests, not the prompt).
        assertFalse(
            prompt.contains("theatrical", ignoreCase = true),
            "Prompt must not instruct M1K3 to be theatrical",
        )
        assertFalse(
            prompt.contains("magnificent", ignoreCase = true),
            "Prompt must not instruct M1K3 to be magnificent",
        )
        assertFalse(
            prompt.contains("villain", ignoreCase = true),
            "Prompt must not cast M1K3 as a villain",
        )
    }

    @Test
    fun `prompt encodes dry sharp tone`() {
        val prompt = buildWith()
        assertTrue(
            prompt.contains("dry", ignoreCase = true) ||
                prompt.contains("sharp", ignoreCase = true),
            "Prompt must encode M1K3's sharp, dry tone",
        )
    }

    @Test
    fun `prompt rejects corporate filler framing`() {
        val prompt = buildWith()
        assertTrue(
            prompt.contains("corporate", ignoreCase = true) ||
                prompt.contains("filler", ignoreCase = true) ||
                prompt.contains("pleasantries", ignoreCase = true),
            "Prompt must explicitly push back against corporate-assistant framing",
        )
    }

    // ===== Thinking instruction =====

    @Test
    fun `full prompt instructs model to use think tags`() {
        val prompt = buildWith()
        assertTrue(
            prompt.contains("<think>", ignoreCase = true),
            "Full prompt should instruct models to use <think> tags",
        )
    }

    @Test
    fun `compact prompt instructs model to use think tags`() {
        val compact = builder.build(SystemPromptInput(userName = "Kev", tier = SystemPromptTier.COMPACT))
        assertTrue(
            compact.contains("<think>", ignoreCase = true),
            "Compact prompt should instruct models to use <think> tags",
        )
    }

    @Test
    fun `compact prompt contains artifact instructions`() {
        val compact = builder.build(SystemPromptInput(userName = "Kev", tier = SystemPromptTier.COMPACT))
        assertTrue(
            compact.contains("artifact", ignoreCase = true),
            "Compact prompt should contain artifact instructions",
        )
    }
}
