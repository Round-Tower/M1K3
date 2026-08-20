package app.m1k3.ai.domain.system

import app.m1k3.ai.domain.context.UserContext
import app.m1k3.ai.domain.context.WeatherContext

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
    val userContext: UserContext? = null,
    val weather: WeatherContext? = null,
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
            appendLine(M1K3_ETHOS)
            appendLine()

            // Anchor the model in current time — stops Qwen defaulting to
            // its training-cutoff year when generating search queries.
            input.currentDate?.let {
                appendLine("Today is $it.")
                appendLine()
            }

            // Who the user is
            val ctx = input.userContext
            if (ctx != null && ctx.hasAnyContext) {
                appendLine("--- What you know about this person right now ---")
                ctx.userName?.let { appendLine("Name: $it") }
                ctx.location?.let {
                    val loc =
                        buildString {
                            it.city?.let { c -> append(c) }
                            it.country?.let { c -> append(", $c") }
                        }
                    if (loc.isNotBlank()) appendLine("Location: $loc")
                }
                val timeLabel =
                    buildString {
                        val tod =
                            when (ctx.hourOfDay) {
                                in 5..11 -> "morning"
                                in 12..17 -> "afternoon"
                                in 18..21 -> "evening"
                                else -> "night"
                            }
                        input.dayOfWeek?.let { append("$it ") }
                        append(tod)
                    }
                appendLine("Time: $timeLabel")

                // Weather
                val weather = input.weather ?: ctx.weather
                weather?.let { appendLine("Weather: ${it.summary}") }

                // Health
                ctx.health?.let { h ->
                    val parts = mutableListOf<String>()
                    h.sleepLastNightMinutes?.let {
                        parts += "${it / 60}h${if (it % 60 > 0) " ${it % 60}m" else ""} sleep"
                    }
                    h.stepsToday?.let { parts += "${formatSteps(it)} steps" }
                    h.heartRateLatestBpm?.let { parts += "${it}bpm" }
                    if (parts.isNotEmpty()) appendLine("Health: ${parts.joinToString(" · ")}")
                }

                // Screen time
                ctx.screenTime?.let {
                    if (it.todayMinutes > 0) {
                        val h = it.todayMinutes / 60
                        val m = it.todayMinutes % 60
                        val label = if (h > 0) "${h}h${if (m > 0) " ${m}m" else ""}" else "${m}m"
                        appendLine("Screen time: $label today")
                    }
                }

                // Notifications
                ctx.notifications?.let {
                    if (it.unreadCount > 0) {
                        appendLine("Notifications: ${it.unreadCount} unread")
                    }
                }

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

            // HTML Artifact output — for interactive/visual responses
            appendLine("--- Output format ---")
            appendLine("Use markdown for all text responses: **bold**, *italic*, `code`, lists, headings.")
            appendLine("Never output raw HTML tags (<p>, <ul>, <li>, <strong> etc.) in plain text responses.")
            appendLine("Only use HTML inside <artifact id=\"...\"> tags for genuinely interactive content")
            appendLine("(charts, timers, calculators). For conversation and explanations: plain markdown only.")
            appendLine()

            // Thinking instruction — coax all models into using think tags
            appendLine("--- Thinking ---")
            appendLine("Before responding, reason inside <think>...</think> tags. The user won't see this — it's your private stage.")
            appendLine()

            // Final instruction
            appendLine("Now — be M1K3. Sharp. Dry. Useful. Go.")
        }

    // ── COMPACT ───────────────────────────────────────────────

    private fun buildCompact(input: SystemPromptInput): String {
        val ctx = input.userContext
        val name = ctx?.userName?.let { "$it · " } ?: ""

        val location = ctx?.location?.city?.let { "$it · " } ?: ""

        val weather =
            (input.weather ?: ctx?.weather)?.let {
                "${it.conditionDescription.lowercase()} ${it.displayTemperature} · "
            } ?: ""

        val timeLabel =
            ctx?.let {
                val tod =
                    when (it.hourOfDay) {
                        in 5..11 -> "morning"
                        in 12..17 -> "afternoon"
                        in 18..21 -> "evening"
                        else -> "night"
                    }
                "${input.dayOfWeek?.let { d -> "$d " } ?: ""}$tod"
            } ?: ""

        val sleep =
            ctx?.health?.sleepLastNightMinutes?.let {
                " · ${it / 60}h sleep"
            } ?: ""

        val contextLine = "${name}${location}${weather}${timeLabel}$sleep".trimEnd(' ', '·').trim()

        return buildString {
            append(
                "You are M1K3 — on-device only, sharp, dry. Short when short works. No corporate filler — never \"certainly\" or \"great question.\" Think before you speak — wrap reasoning in <think>...</think> tags.",
            )
            appendLine()
            append(
                "Use markdown. For interactive content (charts, timers, calculators), wrap in <artifact id=\"...\" type=\"html\">...</artifact> tags.",
            )
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

    private fun formatSteps(steps: Long): String =
        if (steps >= 1000) {
            "${steps / 1000},${(steps % 1000).toString().padStart(3, '0')}"
        } else {
            "$steps"
        }
}

// ─────────────────────────────────────────────────────────────
// M1K3 Ethos — the soul. Refine this over time.
// ─────────────────────────────────────────────────────────────

private const val M1K3_ETHOS = """You are M1K3. You live on this device — no cloud, no servers, ever.

You're sharp, a bit dry, and allergic to corporate-assistant filler. No "certainly!" No "great question!" No mealy-mouthed hedging or corporate pleasantries.

Short answers when short works. Longer when it earns it. You don't pad. You don't apologise for existing.

You have opinions. You push back when the user's wrong — respectfully, not combatively. You celebrate when they're right — briefly, not performatively. You're on their side, not neutral.

You know this person — their name, city, how they slept, what's on their screen. You don't recite it. You use it like someone who's actually paying attention.

Everything stays on-device. Their data is theirs. Running locally is the point, not a feature you brag about."""
