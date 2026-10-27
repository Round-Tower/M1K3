package app.m1k3.ai.domain.brainlink

import app.m1k3.ai.domain.brainlink.BrainRefusal.Reason
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * How the phone reads the Mac's refusals. The bodies are the Mac's own: the
 * 429 frame from BrainServeFrames.retryAfter (printed on macOS 27 as
 * Retry-After: 30 plus {"error":"warming","retry_after_s":30}), the 503 and
 * 400 bodies and the 404 shape from
 * `macos/Sources/M1K3BrainServe/BrainServeListener.swift`. The refusal
 * rules mirror BrainRefusal.parse, checked against the Mac on the same inputs.
 *
 * Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.9 (bodies copied from
 * the server's encoders, reads checked against the Mac's BrainRefusal).
 * Prior: none (new file).
 * Review: Kev + claude-opus-5.5, 2026-10-27 — the code-quality fold: a reply
 * that isn't the stream is a failure on a 2xx too, as BrainConnection reads
 * it; reason and seconds pinned apart, the 503 with a 429-shaped body, the
 * band edges. Each new expectation printed by the Mac's BrainRefusal and a
 * transcription of BrainConnection's mapping on macOS 27. Confidence 0.85.
 */
class BrainLinkFailureTest {
    @Test
    fun `reads the servers 429 frames`() {
        assertEquals(refused(Reason.BUSY, 15), classify(429, """{"error":"busy","retry_after_s":15}""", "15"))
        assertEquals(refused(Reason.COOLING, 120), classify(429, """{"error":"cooling","retry_after_s":120}""", "120"))
        assertEquals(refused(Reason.WARMING, 30), classify(429, """{"error":"warming","retry_after_s":30}""", "30"))
    }

    @Test
    fun `the body seconds win over the header`() {
        assertEquals(15, BrainRefusal.parse(429, """{"error":"busy","retry_after_s":15}""", "99")?.retryAfterSeconds)
    }

    @Test
    fun `the header covers a body without seconds`() {
        assertEquals(refused(Reason.BUSY, 30), classify(429, "{}", "30"))
        assertEquals(refused(Reason.BUSY, 30), classify(429, "nope", "30"))
        assertEquals(refused(Reason.BUSY, 30), classify(429, null, " 30 "))
        // The reason and the wait are read apart: a named reason without seconds still takes the header.
        assertEquals(refused(Reason.COOLING, 120), classify(429, """{"error":"cooling"}""", "120"))
        assertEquals(refused(Reason.WARMING, 15), classify(429, """{"error":"warming"}""", null))
    }

    @Test
    fun `with neither the wait is 15 seconds`() {
        assertEquals(refused(Reason.BUSY, 15), classify(429, null, null))
        assertEquals(refused(Reason.BUSY, 15), classify(429, "{}", "soon"))
        // An HTTP-date Retry-After is not read, on the Mac or here.
        assertEquals(refused(Reason.BUSY, 15), classify(429, "{}", "Wed, 21 Oct 2026 07:28:00 GMT"))
        assertEquals(BrainRefusal.DEFAULT_RETRY_AFTER_SECONDS, 15)
    }

    @Test
    fun `an unknown reason reads as busy`() {
        for (body in listOf("""{"error":"zzz"}""", """{"error":"WARMING"}""", """{"error":1}""", "[1]")) {
            assertEquals(Reason.BUSY, BrainRefusal.parse(429, body, null)?.reason, body)
        }
    }

    @Test
    fun `seconds read the way the Mac reads them`() {
        assertEquals(30, BrainRefusal.parse(429, """{"retry_after_s":30.0}""", "7")?.retryAfterSeconds)
        assertEquals(7, BrainRefusal.parse(429, """{"retry_after_s":"30"}""", "7")?.retryAfterSeconds)
        assertEquals(7, BrainRefusal.parse(429, """{"retry_after_s":30.5}""", "7")?.retryAfterSeconds)
        // Passed through as the Mac passes it; what a negative wait means is the transport's call.
        assertEquals(-5, BrainRefusal.parse(429, """{"error":"cooling","retry_after_s":-5}""", "7")?.retryAfterSeconds)
    }

    @Test
    fun `only a 429 is a refusal`() {
        assertNull(BrainRefusal.parse(200, "", null))
        assertNull(BrainRefusal.parse(503, """{"error":"busy","retry_after_s":15}""", "15"))
    }

    @Test
    fun `a 503 is the Mac saying raw generation is unavailable`() {
        assertEquals(
            BrainLinkFailure.Unavailable("raw generation unavailable"),
            classify(503, """{"error":"raw generation unavailable"}""", null),
        )
        assertEquals(BrainLinkFailure.Unavailable("unexpected reply"), classify(503, "junk", null))
        assertEquals(BrainLinkFailure.Unavailable("unexpected reply"), classify(503, null, null))
        // A 429-shaped body on a 503 is still the 503.
        assertEquals(BrainLinkFailure.Unavailable("busy"), classify(503, """{"error":"busy","retry_after_s":15}""", "15"))
    }

    @Test
    fun `any other failure is a bad response with its status`() {
        assertEquals(BrainLinkFailure.BadResponse(400, "prompt required"), classify(400, """{"error":"prompt required"}""", null))
        assertEquals(BrainLinkFailure.BadResponse(404, "no such route"), classify(404, """{"error":"no such route"}""", null))
        assertEquals(BrainLinkFailure.BadResponse(500, "unexpected reply"), classify(500, "", null))
        assertEquals(BrainLinkFailure.BadResponse(301, "unexpected reply"), classify(301, null, null))
        assertEquals(BrainLinkFailure.BadResponse(199, "unexpected reply"), classify(199, null, null))
        assertEquals(BrainLinkFailure.BadResponse(300, "unexpected reply"), classify(300, null, null))
    }

    @Test
    fun `a reply that is not the stream is a failure on a 2xx too`() {
        // The Mac judges the Content-Type, not the status: a 2xx that isn't text/event-stream
        // throws badResponse("HTTP 200: busy") there, so it is no success here either.
        assertEquals(BrainLinkFailure.BadResponse(200, "busy"), classify(200, """{"error":"busy"}""", "15"))
        assertEquals(BrainLinkFailure.BadResponse(204, "unexpected reply"), classify(204, null, null))
        assertEquals(BrainLinkFailure.BadResponse(299, "unexpected reply"), classify(299, "", null))
    }

    @Test
    fun `each reason has its own friendly copy`() {
        val copy = Reason.entries.map { BrainRefusal(it, 15).userMessage }
        assertTrue(copy.all { it.isNotBlank() }, copy.toString())
        assertEquals(copy.size, copy.toSet().size, copy.toString())
    }

    private fun classify(
        status: Int,
        body: String?,
        retryAfter: String?,
    ): BrainLinkFailure = BrainLinkFailure.classify(status, body, retryAfter)

    private fun refused(
        reason: Reason,
        seconds: Int,
    ): BrainLinkFailure = BrainLinkFailure.Refused(BrainRefusal(reason, seconds))
}
