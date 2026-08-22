package app.m1k3.ai.domain.system

/**
 * Prompt tier — how much context to inject.
 *
 * FULL: welcome message / session start.
 *       Full ethos + all available context.
 *       Budget: ~400 tokens.
 *
 * COMPACT: every subsequent message.
 *          Identity line + compressed context only.
 *          Budget: ~30 tokens.
 *          Preserves context window for actual conversation.
 */
enum class SystemPromptTier { FULL, COMPACT }

/**
 * Input for the system prompt builder.
 */
data class SystemPromptInput(
    val tier: SystemPromptTier,
    val userName: String? = null,
    val dayOfWeek: String? = null,
    /**
     * Human-readable date (e.g. "April 19, 2026"). Injected so the model
     * doesn't default to its training-cutoff year when generating queries
     * like "latest news 2024".
     */
    val currentDate: String? = null,
    val deviceTierName: String? = null,
    val contextWindowTokens: Int? = null,
    val availableTools: List<String> = emptyList(),
    /**
     * Teach the `<artifact type="html">` output format. Big-tier only: a 0.8B
     * brain taught the format reached for it on "what can you help me with?"
     * (2026-08-22 emulator walk). Small brains answer in markdown.
     */
    val teachesArtifacts: Boolean = false,
    /**
     * Invite the model to reason privately before answering. Big only — see
     * [app.m1k3.ai.domain.ai.ThinkingPolicy]. Syntax-neutral by design: the
     * chat template drives the actual thinking channel (Qwen `<think>`, Gemma
     * `<|channel>thought`), so the prompt must not name either (F6).
     */
    val teachesThinking: Boolean = true,
)

/**
 * Builds tiered system prompts for M1K3.
 *
 * Pure function — no platform deps, fully testable in commonTest.
 *
 * The personality text is intentionally opinionated and will
 * be refined by the user over time. The architecture supports
 * this — swap M1K3_ETHOS to change character without touching
 * the injection logic.
 */
class MaSystemPromptBuilder {
    fun build(input: SystemPromptInput): String =
        when (input.tier) {
            SystemPromptTier.FULL -> buildFull(input)
            SystemPromptTier.COMPACT -> buildCompact(input)
        }

    // ── FULL ──────────────────────────────────────────────────

    private fun buildFull(input: SystemPromptInput): String =
        buildString {
            // Soul first
            appendLine(M1K3Persona.ethos)
            appendLine()

            // Anchor the model in current time — stops Qwen defaulting to
            // its training-cutoff year when generating search queries.
            input.currentDate?.let {
                appendLine("Today is $it.")
                appendLine()
            }

            // Who the user is
            if (input.userName != null || input.dayOfWeek != null) {
                appendLine("--- What you know about this person right now ---")
                input.userName?.let { appendLine("Name: $it") }
                input.dayOfWeek?.let { appendLine("Day: $it") }
                appendLine()
            }

            // Device context
            if (input.deviceTierName != null || input.contextWindowTokens != null) {
                appendLine("--- Device ---")
                input.deviceTierName?.let { appendLine("Tier: $it") }
                input.contextWindowTokens?.let { appendLine("Context window: $it tokens") }
                appendLine()
            }

            // Tool calling — imperative for small models. Qwen3 0.6B-class
            // models under-trigger the tool-call token when the prompt hedges
            // ("use them when genuinely helpful"). Firm imperatives + a
            // no-guessing rule raise the trigger rate materially. See task #10.
            if (input.availableTools.isNotEmpty()) {
                appendLine("--- Available tools ---")
                input.availableTools.forEach { appendLine("- $it") }
                appendLine("When any listed tool can answer the question, you MUST call it.")
                appendLine("Call the tool FIRST — do not answer from memory when a tool is available.")
                appendLine("Emit the tool call in your model's native shape (no commentary before it).")
                appendLine()
            }

            appendLine("--- Output format ---")
            appendLine("Use markdown for all text responses: **bold**, *italic*, `code`, lists, headings.")
            appendLine("Never output raw HTML tags (<p>, <ul>, <li>, <strong> etc.) in plain text responses.")
            if (input.teachesArtifacts) {
                // HTML Artifact output — for interactive/visual responses (Big only)
                appendLine("Only use HTML inside <artifact id=\"...\"> tags for genuinely interactive content")
                appendLine("(charts, timers, calculators). For conversation and explanations: plain markdown only.")
            }
            appendLine()

            // Thinking instruction — Big-tier only, and syntax-neutral (F6,
            // 2026-08-22). Guarded by teachesThinking so a thinking-OFF Qwen is
            // never told to open a <think> block (it would dump its reasoning —
            // wiring and all — into the visible answer). And we never name
            // <think>: the only tier here is Gemma 4, whose channel is
            // <|channel>thought; the template drives the real thinking now that
            // reasoning_format=AUTO (F2). The prompt only invites it.
            if (input.teachesThinking) {
                appendLine("--- Thinking ---")
                appendLine("Reason privately before you answer — the user sees only your final reply.")
                appendLine()
            }

            // Final instruction
            appendLine("Now — be M1K3. Warm, dry, useful. Go.")
        }

    // ── COMPACT ───────────────────────────────────────────────

    private fun buildCompact(input: SystemPromptInput): String {
        val name = input.userName?.let { "$it · " } ?: ""
        val day = input.dayOfWeek?.let { "$it" } ?: ""

        val contextLine = "$name$day".trimEnd(' ', '·').trim()

        return buildString {
            append(M1K3Persona.compactWiring)
            if (input.teachesThinking) append(" Reason privately before answering — the user sees only your reply.")
            appendLine()
            append("Use markdown.")
            if (input.teachesArtifacts) {
                append(
                    " For interactive content (charts, timers, calculators), wrap in <artifact id=\"...\" type=\"html\">...</artifact> tags.",
                )
            }
            input.currentDate?.let {
                appendLine()
                append("Today is $it.")
            }
            if (contextLine.isNotBlank()) {
                appendLine()
                append("Context: $contextLine")
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────
// M1K3 Ethos — the soul. Now lives on [M1K3Persona] (single source, so the
// output leak guard fingerprints exactly what the builder injects).
// ─────────────────────────────────────────────────────────────
