package app.m1k3.ai.domain.chat

/**
 * Strip structural artifacts that leak into the final text when the native
 * chat parser (common_chat_parse) fails to extract a structured tool call,
 * and the raw model output reaches the UI unchanged.
 *
 * Context: Qwen3.5 on the native-chat path sometimes emits interleaved
 * `<think>` / `</think>` / `<tool_call>` tokens that common_chat_parse
 * reports as zero tool calls — our fallback force-executes KNOWLEDGE tools,
 * but the raw text still needs cleaning before it reaches the user.
 *
 * `StreamingThinkTagParser` handles well-formed streams; this helper handles
 * the orphan-tag and leftover-xml cases on the already-accumulated string.
 */
object LlmOutputSanitizer {
    // Tolerate tokenizer whitespace variants: `< think >`, `< / think >`, `< /think>`, etc.
    private val thinkBlock =
        Regex(
            """< *think *>.*?< */ *think *>""",
            setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
        )
    private val toolCallBlock =
        Regex(
            """< *tool_call *>.*?< */ *tool_call *>""",
            setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
        )

    // Qwen's bare tool-call shape when the `<tool_call>` envelope is absent:
    //   <function=web_search><parameter=query>value</parameter></function>
    private val functionBlock =
        Regex(
            """< *function *= *[^>]*>.*?< */ *function *>""",
            setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
        )
    private val parameterBlock =
        Regex(
            """< *parameter *= *[^>]*>.*?< */ *parameter *>""",
            setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL),
        )
    private val strayOpenThink =
        Regex("""< *think *>.*""", setOf(RegexOption.IGNORE_CASE, RegexOption.DOT_MATCHES_ALL))
    private val strayCloseThink = Regex("""< */ *think *>""", RegexOption.IGNORE_CASE)
    private val strayOpenToolCall = Regex("""< *tool_call *>""", RegexOption.IGNORE_CASE)
    private val strayCloseToolCall = Regex("""< */ *tool_call *>""", RegexOption.IGNORE_CASE)
    private val strayOpenFunction = Regex("""< *function *= *[^>]*>""", RegexOption.IGNORE_CASE)
    private val strayCloseFunction = Regex("""< */ *function *>""", RegexOption.IGNORE_CASE)
    private val strayOpenParameter = Regex("""< *parameter *= *[^>]*>""", RegexOption.IGNORE_CASE)
    private val strayCloseParameter = Regex("""< */ *parameter *>""", RegexOption.IGNORE_CASE)

    // ChatML template tokens that bleed through when common_chat_parse's PEG
    // anchor slips against the raw accumulated stream (seen on Qwen3.5 0.8B
    // native-chat path, Pixel 9a 2026-04-20). Role is restricted to the known
    // ChatML values so we don't eat real body text that happens to start with
    // lowercase letters after a bare <|im_start|>.
    private val chatMlStart =
        Regex(
            """<\|im_start\|>\s*(?:assistant|user|system|tool)?\s*\n?""",
            RegexOption.IGNORE_CASE,
        )
    private val chatMlEnd = Regex("""<\|im_end\|>""", RegexOption.IGNORE_CASE)

    private val blankRun = Regex("""\n{3,}""")

    fun strip(raw: String): String {
        if (raw.isEmpty()) return raw
        return raw
            // ChatML template tokens before structured-content regexes so a
            // stray <|im_start|>assistant\n doesn't shield a <think> block.
            .replace(chatMlStart, "")
            .replace(chatMlEnd, "")
            .replace(thinkBlock, "")
            .replace(toolCallBlock, "")
            // Qwen bare-function shape (no tool_call envelope): strip the
            // whole function block, then mop up any stray parameter blocks.
            .replace(functionBlock, "")
            .replace(parameterBlock, "")
            // Orphan closers first, then orphan openers swallow any trailing content.
            .replace(strayCloseThink, "")
            .replace(strayCloseToolCall, "")
            .replace(strayCloseFunction, "")
            .replace(strayCloseParameter, "")
            .replace(strayOpenToolCall, "")
            .replace(strayOpenFunction, "")
            .replace(strayOpenParameter, "")
            .replace(strayOpenThink, "")
            .replace(blankRun, "\n\n")
            .trimEnd()
    }
}
