package app.m1k3.ai.domain.chat

import kotlin.time.Clock

/**
 * Stateful streaming parser that separates <think>...</think> blocks
 * from visible text in a token stream.
 *
 * Handles edge cases:
 * - Qwen3.5's "< think>" tokenization (space before tag name)
 * - Tags split across token boundaries
 * - Case-insensitive matching
 * - Native-chat path: template ends with `<|im_start|>assistant\n<think>\n`
 *   so the stream begins *inside* a think block without the parser ever
 *   seeing the opening tag. Pass `startInThinking = true` in that case.
 *
 * Pure Kotlin, no platform dependencies — lives in domain layer.
 *
 * @see <a href="https://murphysig.dev">MurphySig</a>
 * Confidence: HIGH — extracted from battle-tested ChatWithToolsUseCase parser
 */
class StreamingThinkTagParser(
    startInThinking: Boolean = false,
) {
    private val visible = StringBuilder()
    private val thinking = StringBuilder()
    private val pending = StringBuilder() // buffered text that might be part of a tag

    var isThinking: Boolean = startInThinking
        private set

    var thinkingStartMs: Long =
        if (startInThinking) Clock.System.now().toEpochMilliseconds() else 0L
        private set

    var thinkingDurationMs: Long = 0L
        private set

    val visibleText: String get() = visible.toString()

    val thinkingContent: String?
        get() = thinking.toString().ifEmpty { null }

    companion object {
        private val THINK_OPEN = Regex("< *think *>", RegexOption.IGNORE_CASE)
        private val THINK_CLOSE = Regex("</ *think *>", RegexOption.IGNORE_CASE)
    }

    /**
     * Feed a token into the parser. Call this for each token from the LLM stream.
     */
    fun feed(token: String) {
        if (token.isEmpty()) return

        // Append to the appropriate buffer, then scan for tag transitions
        if (isThinking) {
            pending.append(token)
            processThinkingBuffer()
        } else {
            pending.append(token)
            processVisibleBuffer()
        }
    }

    /**
     * While in visible mode, scan for <think> opening tag.
     */
    private fun processVisibleBuffer() {
        val text = pending.toString()
        val match = THINK_OPEN.find(text)

        if (match != null) {
            // Everything before the tag is visible text
            visible.append(text.substring(0, match.range.first))
            isThinking = true
            thinkingStartMs = Clock.System.now().toEpochMilliseconds()
            // Everything after the tag goes to thinking buffer
            val afterTag = text.substring(match.range.last + 1)
            pending.clear()
            if (afterTag.isNotEmpty()) {
                pending.append(afterTag)
                processThinkingBuffer()
            }
        } else if (text.contains('<')) {
            // Might be a partial tag — flush everything before the '<' and keep the rest buffered
            val ltIndex = text.lastIndexOf('<')
            visible.append(text.substring(0, ltIndex))
            pending.clear()
            pending.append(text.substring(ltIndex))
        } else {
            // No tag or partial tag — flush everything
            visible.append(text)
            pending.clear()
        }
    }

    /**
     * While in thinking mode, scan for </think> closing tag.
     */
    private fun processThinkingBuffer() {
        val text = pending.toString()
        val match = THINK_CLOSE.find(text)

        if (match != null) {
            // Everything before the closing tag is thinking content
            thinking.append(text.substring(0, match.range.first))
            isThinking = false
            thinkingDurationMs = Clock.System.now().toEpochMilliseconds() - thinkingStartMs
            // Everything after goes back to visible
            val afterTag = text.substring(match.range.last + 1)
            pending.clear()
            if (afterTag.isNotEmpty()) {
                pending.append(afterTag)
                processVisibleBuffer()
            }
        } else if (text.contains('<')) {
            // Might be partial closing tag — flush safe content, buffer the rest
            val ltIndex = text.lastIndexOf('<')
            thinking.append(text.substring(0, ltIndex))
            pending.clear()
            pending.append(text.substring(ltIndex))
        } else {
            // No tag — flush to thinking
            thinking.append(text)
            pending.clear()
        }
    }

    /**
     * Finalize parsing after generation completes.
     *
     * Handles unclosed <think> tags: if the model opened <think> but never
     * closed it, ALL output is stuck in thinkingContent with visibleText empty.
     * This forces the thinking content to become visible text so the user
     * always sees a response.
     *
     * Also flushes any pending buffer and calculates thinking duration.
     */
    fun finalize() {
        // Flush any remaining pending buffer
        if (pending.isNotEmpty()) {
            if (isThinking) {
                thinking.append(pending)
            } else {
                visible.append(pending)
            }
            pending.clear()
        }

        // If still in thinking mode (unclosed tag), move thinking → visible
        // The model generated thinking but never emitted </think>
        if (isThinking && visible.isEmpty() && thinking.isNotEmpty()) {
            visible.append(thinking)
            thinking.clear()
            isThinking = false
            if (thinkingStartMs > 0L && thinkingDurationMs == 0L) {
                thinkingDurationMs = Clock.System.now().toEpochMilliseconds() - thinkingStartMs
            }
        } else if (isThinking && thinkingStartMs > 0L && thinkingDurationMs == 0L) {
            // Closed thinking duration even if visible text exists
            thinkingDurationMs = Clock.System.now().toEpochMilliseconds() - thinkingStartMs
        }
    }

    /**
     * Reset all state for reuse.
     */
    fun reset() {
        visible.clear()
        thinking.clear()
        pending.clear()
        isThinking = false
        thinkingStartMs = 0L
        thinkingDurationMs = 0L
    }
}
