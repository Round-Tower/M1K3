package app.m1k3.ai.domain.brainlink

import kotlin.test.Test
import kotlin.test.assertEquals

/**
 * The /v1/generate stream as the Mac writes it. The frames below are the bytes
 * BrainServeFrames printed on macOS 27 (2026-10-27) from
 * `macos/Sources/M1K3BrainServe/BrainServePolicies.swift`: a token is
 * `data: <JSONEncoder JSON>` and a blank line, done and error carry an event
 * line. Foundation's JSONEncoder escapes '/' as '\/' and control characters as
 * \u00XX and leaves other text raw, so those escapes are pinned here. Every
 * skip below matches the Mac's own SSEParser, run on the same bytes.
 *
 * Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.9 (frames read off the
 * Mac's encoder, skips off the Mac's parser).
 * Prior: none (new file).
 * Review: Kev + claude-opus-5.5, 2026-10-27 — the code-quality fold: a chunk
 * that completes one frame and ends inside the next keeps that tail (the
 * Mac's SSEParser fed the same three chunks emits the same events).
 * Confidence 0.85.
 */
class SseFrameParserTest {
    @Test
    fun `parses a real token event`() {
        assertEquals(listOf(SseEvent.Token("Hello, Kev")), feed("data: {\"token\":\"Hello, Kev\"}\n\n"))
    }

    @Test
    fun `foundation escapes survive`() {
        assertEquals(listOf(SseEvent.Token("a/b")), feed("data: {\"token\":\"a\\/b\"}\n\n"))
        assertEquals(
            listOf(SseEvent.Token("line one\nsaid \"hi\"\tend")),
            feed("data: {\"token\":\"line one\\nsaid \\\"hi\\\"\\tend\"}\n\n"),
        )
        assertEquals(listOf(SseEvent.Token("é 😀 \u0001")), feed("data: {\"token\":\"é 😀 \\u0001\"}\n\n"))
        assertEquals(listOf(SseEvent.Token("back\\slash")), feed("data: {\"token\":\"back\\\\slash\"}\n\n"))
        assertEquals(listOf(SseEvent.Token("😀")), feed("data: {\"token\":\"\\ud83d\\ude00\"}\n\n"))
    }

    @Test
    fun `parses done and error events`() {
        assertEquals(listOf(SseEvent.Done), feed("event: done\ndata: {}\n\n"))
        assertEquals(
            listOf(SseEvent.Error("brain fell over")),
            feed("event: error\ndata: {\"message\":\"brain fell over\"}\n\n"),
        )
    }

    @Test
    fun `an error without a readable message still ends the stream`() {
        for (frame in listOf("event: error\n\n", "event: error\ndata: {\"message\":2}\n\n", "event: error\ndata: nope\n\n")) {
            assertEquals(listOf(SseEvent.Error("stream error")), feed(frame), frame)
        }
        // done ignores its data, whatever it is.
        assertEquals(listOf(SseEvent.Done), feed("event: done\ndata: nope\n\n"))
    }

    @Test
    fun `byte by byte feed yields the same events`() {
        val wire = "data: {\"token\":\"alpha\"}\n\ndata: {\"token\":\"beta\"}\n\nevent: done\ndata: {}\n\n".encodeToByteArray()
        val parser = SseFrameParser()
        val events = wire.flatMap { byte -> parser.feed(byteArrayOf(byte)) }
        assertEquals(listOf(SseEvent.Token("alpha"), SseEvent.Token("beta"), SseEvent.Done), events)
    }

    @Test
    fun `a character split across chunks arrives whole`() {
        val wire = "data: {\"token\":\"😀\"}\n\n".encodeToByteArray()
        val cut = wire.indexOfFirst { it == 0xF0.toByte() } + 2 // inside the emoji's four UTF-8 bytes
        val parser = SseFrameParser()
        assertEquals(emptyList(), parser.feed(wire.copyOfRange(0, cut)))
        assertEquals(listOf(SseEvent.Token("😀")), parser.feed(wire.copyOfRange(cut, wire.size)))
    }

    @Test
    fun `several frames in one chunk all arrive`() {
        // A stray extra newline opens the next frame with a blank line, which is harmless.
        assertEquals(
            listOf(SseEvent.Token("a"), SseEvent.Token("b"), SseEvent.Done),
            feed("data: {\"token\":\"a\"}\n\n\ndata: {\"token\":\"b\"}\n\nevent: done\ndata: {}\n\n"),
        )
    }

    @Test
    fun `a partial frame waits for the rest`() {
        val parser = SseFrameParser()
        assertEquals(emptyList(), parser.feed("data: {\"token\":\"wa".encodeToByteArray()))
        assertEquals(emptyList(), parser.feed("it\"}\n".encodeToByteArray()))
        assertEquals(listOf(SseEvent.Token("wait")), parser.feed("\n".encodeToByteArray()))
    }

    @Test
    fun `unknown kinds and junk are skipped not fatal`() {
        val parser = SseFrameParser()
        assertEquals(emptyList(), parser.feed("event: heartbeat\ndata: {}\n\n".encodeToByteArray()))
        assertEquals(listOf(SseEvent.Done), parser.feed("event: done\ndata: {}\n\n".encodeToByteArray()))
        for (frame in listOf(
            "data: not json\n\n",
            "data: {\"other\":1}\n\n",
            "data: {\"token\":1}\n\n",
            "data: {\"token\":null}\n\n",
            "data: {\"token\":\"t\"} x\n\n",
            "data: [1]\n\n",
            "event: DONE\ndata: {}\n\n",
            "\n\n",
        )) {
            assertEquals(emptyList(), feed(frame), frame)
        }
    }

    @Test
    fun `bytes that are not UTF-8 skip the frame`() {
        val parser = SseFrameParser()
        assertEquals(emptyList(), parser.feed("data: ".encodeToByteArray() + byteArrayOf(0xFF.toByte()) + "\n\n".encodeToByteArray()))
        assertEquals(listOf(SseEvent.Token("next")), parser.feed("data: {\"token\":\"next\"}\n\n".encodeToByteArray()))
    }

    @Test
    fun `fields read the way the Mac reads them`() {
        // No space after the colon, tabs and no-break spaces trimmed, last data line wins,
        // comment lines ignored, and an explicit message event is a token.
        assertEquals(listOf(SseEvent.Token("x")), feed("data:{\"token\":\"x\"}\n\n"))
        assertEquals(listOf(SseEvent.Done), feed("event:\tdone\t\ndata: {}\n\n"))
        assertEquals(listOf(SseEvent.Done), feed("event:\u00A0done\u00A0\ndata: {}\n\n"))
        assertEquals(listOf(SseEvent.Token("b")), feed("data: {\"token\":\"a\"}\ndata: {\"token\":\"b\"}\n\n"))
        assertEquals(listOf(SseEvent.Token("k")), feed(": keepalive\ndata: {\"token\":\"k\"}\n\n"))
        assertEquals(listOf(SseEvent.Token("m")), feed("event: message\ndata: {\"token\":\"m\"}\n\n"))
    }

    @Test
    fun `a CRLF stream stays buffered as it does on the Mac`() {
        // The Mac frames with bare LF; its parser never splits a CRLF stream either.
        assertEquals(emptyList(), feed("event: done\r\ndata: {}\r\n\r\n"))
    }

    @Test
    fun `a chunk that ends inside the next frame keeps that tail`() {
        // A socket read rarely ends on a frame boundary.
        val parser = SseFrameParser()
        assertEquals(listOf(SseEvent.Token("a")), parser.feed("data: {\"token\":\"a\"}\n\ndata: {\"tok".encodeToByteArray()))
        // The done frame is still open, and the buffer now ends on a lone LF.
        assertEquals(listOf(SseEvent.Token("b")), parser.feed("en\":\"b\"}\n\nevent: done\ndata: {}\n".encodeToByteArray()))
        assertEquals(listOf(SseEvent.Done), parser.feed("\n".encodeToByteArray()))
    }

    private fun feed(wire: String): List<SseEvent> = SseFrameParser().feed(wire.encodeToByteArray())
}
