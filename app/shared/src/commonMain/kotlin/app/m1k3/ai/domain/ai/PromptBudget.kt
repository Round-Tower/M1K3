package app.m1k3.ai.domain.ai

/**
 * PromptBudget — keeps a rendered prompt body under a target token budget.
 *
 * Domain service — pure Kotlin, no platform dependencies.
 *
 * ML Kit GenAI's Prompt API caps input around ~4000 tokens; M1K3 targets a
 * conservative ~3500 to leave headroom for the system instruction and the
 * model's own reply. There's no on-device tokenizer available to this layer
 * (unlike llama.cpp, which owns its own), so this is a character-count
 * ESTIMATE, not an exact count — deliberately conservative
 * ([DEFAULT_CHARS_PER_TOKEN] undershoots, the same call the Mac's AFM
 * provider makes at ~4.4 chars/token).
 *
 * Trims from the FRONT (oldest content) and keeps the tail — the immediate
 * user question is assumed to live at the end of whatever's passed in, which
 * is how [ChatMlPromptSplit] and `UnifiedPromptBuilder` both lay things out
 * (context first, question last). Never truncates mid-line where a line
 * break is available nearby, so a truncated block doesn't open on a
 * half-sentence.
 */
object PromptBudget {
    /** Conservative estimate; real Gemini Nano tokenization runs denser than this on English prose. */
    const val DEFAULT_CHARS_PER_TOKEN: Double = 3.5

    /**
     * Trim [text] so it fits within [maxTokens] (estimated). Returns [text]
     * unchanged if it already fits. A budget of 0 or fewer tokens returns an
     * empty string rather than throwing — callers with no budget left get
     * nothing, not a crash.
     */
    fun trimToBudget(
        text: String,
        maxTokens: Int,
        charsPerToken: Double = DEFAULT_CHARS_PER_TOKEN,
    ): String {
        if (maxTokens <= 0) return ""
        val maxChars = (maxTokens * charsPerToken).toInt()
        if (text.length <= maxChars) return text

        val trimmedTail = text.takeLast(maxChars)
        // Prefer to start on a fresh line rather than mid-sentence, if a
        // break exists reasonably early in the cut (first quarter) — else
        // keep the raw tail so we don't throw away most of the budget
        // hunting for a break that isn't there.
        val firstBreak = trimmedTail.indexOf('\n')
        return if (firstBreak in 0 until (trimmedTail.length / 4)) {
            trimmedTail.substring(firstBreak + 1)
        } else {
            trimmedTail
        }
    }

    /** Estimated token count for [text], for budget bookkeeping (e.g. "how much is left for the user turn"). */
    fun estimateTokens(
        text: String,
        charsPerToken: Double = DEFAULT_CHARS_PER_TOKEN,
    ): Int = (text.length / charsPerToken).toInt()
}
