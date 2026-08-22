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
        // 2026-08-20: the Mac persona (M1K3Persona.swift, DESIGN_DOCTRINE "protected
        // species") names the costume once — "wearing every sci-fi villain's look but
        // always on the user's side". That single, subverted mention is the character;
        // instructing the model to ACT theatrical is what was retired, and stays out.
        assertTrue(
            prompt.contains("always on the user's side"),
            "The costume line must keep its subversion clause",
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

    // ===== Thinking instruction (F6, 2026-08-22) =====
    //
    // `teachesThinking` is Big-tier only (see ThinkingPolicy). The builder must:
    //   1. Emit NO thinking instruction when teachesThinking is false — a
    //      thinking-OFF Qwen told to "reason inside <think>" opens a second,
    //      visible reasoning block and dumps its wiring (and the ethos) into
    //      the answer. This was unguarded in buildFull (the F6 bug).
    //   2. Never name the literal `<think>` syntax at all: the only tier that
    //      receives the instruction is Gemma 4, whose channel is
    //      `<|channel>thought`, not `<think>`. With reasoning_format=AUTO (F2)
    //      the template drives the actual thinking — the prompt only invites it.

    @Test
    fun `full prompt invites private reasoning when teachesThinking`() {
        val prompt = buildWith()
        assertTrue(
            prompt.contains("reason", ignoreCase = true),
            "Full prompt should invite private reasoning when teachesThinking",
        )
    }

    @Test
    fun `full prompt drops the thinking instruction when teachesThinking is false`() {
        val prompt =
            builder.build(SystemPromptInput(userName = "Kev", tier = SystemPromptTier.FULL, teachesThinking = false))
        assertFalse(
            prompt.contains("--- Thinking ---"),
            "teachesThinking=false must drop the FULL thinking instruction (F6)",
        )
    }

    @Test
    fun `no tier ever names the literal think tag syntax`() {
        for (tier in SystemPromptTier.entries) {
            for (teaches in listOf(true, false)) {
                val prompt =
                    builder.build(SystemPromptInput(userName = "Kev", tier = tier, teachesThinking = teaches))
                assertFalse(
                    prompt.contains("<think>"),
                    "$tier (teachesThinking=$teaches) must not name <think> — Gemma uses <|channel>thought",
                )
            }
        }
    }

    @Test
    fun `thinking instruction is optional`() {
        val off = builder.build(SystemPromptInput(userName = "Kev", tier = SystemPromptTier.COMPACT, teachesThinking = false))
        assertFalse(off.contains("reason", ignoreCase = true), "teachesThinking=false must drop the think instruction")
    }

    // Artifacts are a Big-tier capability. On the 2026-08-22 emulator walk a
    // 0.8B Mini answered "what can you help me with?" with a raw
    // <artifact type="html"> checklist — taught the format, it reached for it
    // on small talk. Small brains get markdown only.
    @Test
    fun `prompts teach artifacts only when asked to`() {
        for (tier in SystemPromptTier.entries) {
            val silent = builder.build(SystemPromptInput(userName = "Kev", tier = tier))
            assertTrue(
                !silent.contains("artifact", ignoreCase = true),
                "$tier prompt must not teach artifacts by default",
            )
            val taught = builder.build(SystemPromptInput(userName = "Kev", tier = tier, teachesArtifacts = true))
            assertTrue(
                taught.contains("<artifact", ignoreCase = true),
                "$tier prompt should teach artifacts when teachesArtifacts=true",
            )
        }
    }
}
