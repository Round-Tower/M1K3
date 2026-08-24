package app.m1k3.ai.domain.ai

/**
 * ChatMlPromptSplit — recovers the (systemInstruction, userContent) split out
 * of a ChatML-rendered prompt string.
 *
 * [ChatWithToolsUseCase] always hands engines ONE pre-rendered prompt string
 * (built by `UnifiedPromptBuilder` from `DefaultChatFormatter` +
 * [app.m1k3.ai.domain.chat.format.ChatFormat.ChatML] — the format
 * [LlmModel.Qwen35_0B8] carries, which is what backs the Mini tier). Engines
 * that only understand model-native chat templates (llama.cpp) consume that
 * string as-is. An engine like ML Kit GenAI's Gemini Nano has its OWN
 * system-instruction slot (`SystemInstruction` in the request) and does not
 * understand `<|im_start|>`/`<|im_end|>` tokens as anything but literal text
 * it would try to imitate.
 *
 * This is the split, not a re-render: it recovers exactly the system and
 * user turns [DefaultChatFormatter.buildMultiTurnPrompt] already wrote, so
 * the persona/context ends up in the request EXACTLY ONCE — never re-added on
 * top of the incoming string (the Mac's `AppleFoundationModelsProvider` had
 * precisely that bug: persona sent once via prompt body, once via session
 * instructions).
 *
 * Deliberately tolerant: an unrecognised or marker-free string (a future
 * chatFormat swap on [LlmModel.Qwen35_0B8], a hand-built test fixture) falls
 * back to treating the WHOLE input as user content with no system
 * instruction — never throws, never drops content.
 */
object ChatMlPromptSplit {
    private const val SYSTEM_OPEN = "<|im_start|>system\n"
    private const val USER_OPEN = "<|im_start|>user\n"
    private const val ASSISTANT_OPEN = "<|im_start|>assistant"
    private const val CLOSE = "<|im_end|>"

    data class Split(
        val systemInstruction: String,
        val userContent: String,
    )

    fun split(rendered: String): Split {
        val systemBlocks = extractBlocks(rendered, SYSTEM_OPEN)
        val userBlocks = extractBlocks(rendered, USER_OPEN)

        if (systemBlocks.isEmpty() && userBlocks.isEmpty()) {
            // No ChatML markers at all — treat the whole string as user content.
            return Split(systemInstruction = "", userContent = rendered.trim())
        }

        return Split(
            systemInstruction = systemBlocks.joinToString("\n\n").trim(),
            userContent = userBlocks.joinToString("\n\n").ifBlank { rendered.substringBefore(ASSISTANT_OPEN) }.trim(),
        )
    }

    /** Every `<|im_start|>ROLE\n...<|im_end|>` span for the given open marker, content only. */
    private fun extractBlocks(
        text: String,
        openMarker: String,
    ): List<String> {
        val blocks = mutableListOf<String>()
        var searchFrom = 0
        while (true) {
            val openIndex = text.indexOf(openMarker, searchFrom)
            if (openIndex == -1) break
            val contentStart = openIndex + openMarker.length
            val closeIndex = text.indexOf(CLOSE, contentStart)
            if (closeIndex == -1) {
                // Unterminated block (shouldn't happen from our own formatter) — take the rest.
                blocks.add(text.substring(contentStart).trim())
                break
            }
            blocks.add(text.substring(contentStart, closeIndex).trim())
            searchFrom = closeIndex + CLOSE.length
        }
        return blocks
    }
}
