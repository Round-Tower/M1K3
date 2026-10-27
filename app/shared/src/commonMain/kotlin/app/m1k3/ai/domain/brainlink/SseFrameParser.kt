package app.m1k3.ai.domain.brainlink

/** One event off the Mac's /v1/generate stream. */
sealed interface SseEvent {
    /** One piece of generated text, already JSON-unescaped. */
    data class Token(
        val text: String,
    ) : SseEvent

    /** The Mac finished the turn cleanly. */
    data object Done : SseEvent

    /** The Mac ended the turn with an error; "stream error" when it named none. */
    data class Error(
        val message: String,
    ) : SseEvent
}

/**
 * Incremental parser for the server-sent events the Mac writes on
 * POST /v1/generate. Feed it chunks as they arrive off the socket; it returns
 * the events each chunk completes and buffers the rest. The Kotlin twin of
 * SSEParser in `macos/Sources/M1K3BrainLink/BrainLinkWire.swift`, reading the
 * frames `macos/Sources/M1K3BrainServe/BrainServePolicies.swift` writes.
 *
 * Bytes, not text: a frame is cut at a blank line (two LFs) before it is
 * decoded, so a character whose UTF-8 bytes straddle two chunks arrives whole.
 * Unknown event kinds and unreadable payloads are skipped rather than fatal,
 * which keeps the stream forward compatible. Not thread safe: one parser per
 * stream, fed from one reader.
 *
 * Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.9 (frames and skips
 * pinned against the Mac's own encoder and parser on macOS 27).
 * Prior: none (new file). Lineage: SSEParser (Kev + claude-fable-5, 2026-08-24).
 */
class SseFrameParser {
    private var buffer = ByteArray(0)

    fun feed(chunk: ByteArray): List<SseEvent> {
        buffer += chunk
        val events = mutableListOf<SseEvent>()
        var frameStart = 0
        var index = 0
        while (index + 1 < buffer.size) {
            if (buffer[index] == LF && buffer[index + 1] == LF) {
                parseFrame(frameStart, index)?.let(events::add)
                frameStart = index + 2
                index = frameStart
            } else {
                index += 1
            }
        }
        if (frameStart > 0) buffer = buffer.copyOfRange(frameStart, buffer.size)
        return events
    }

    private fun parseFrame(
        start: Int,
        end: Int,
    ): SseEvent? {
        val text = runCatching { buffer.decodeToString(start, end, throwOnInvalidSequence = true) }.getOrNull() ?: return null
        var eventName = "message"
        var data: String? = null
        for (line in text.split('\n')) {
            when {
                line.startsWith(EVENT) -> eventName = line.removePrefix(EVENT).trimSwiftWhitespaces()
                line.startsWith(DATA) -> data = line.removePrefix(DATA).trimSwiftWhitespaces()
            }
        }
        return when (eventName) {
            "message" -> parseJsonObject(data)?.stringOrNull("token")?.let { SseEvent.Token(it) }
            "done" -> SseEvent.Done
            "error" -> SseEvent.Error(parseJsonObject(data)?.stringOrNull("message") ?: "stream error")
            else -> null
        }
    }

    private companion object {
        const val LF: Byte = 0x0A
        const val EVENT = "event:"
        const val DATA = "data:"
    }
}
