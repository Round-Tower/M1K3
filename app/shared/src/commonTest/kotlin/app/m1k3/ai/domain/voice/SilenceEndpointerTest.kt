package app.m1k3.ai.domain.voice

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

/**
 * Ports the Mac's SilenceEndpointerTests contract: identical partials don't reset
 * the clock, complete thoughts end on [EndpointCadence.silenceMs], dangling ones
 * wait [EndpointCadence.holdMs], "please" is the spoken submit button, maxWait is
 * the anti-hang backstop, and the learned cadence survives reset().
 */
class SilenceEndpointerTest {
    private val cadence = EndpointCadence.CONVERSATIONAL

    @Test
    fun `empty partial never endpoints`() {
        val e = SilenceEndpointer(cadence)
        e.ingest("", at = 0)
        assertNull(e.decision(at = 60_000))
    }

    @Test
    fun `complete thought ends after silence threshold`() {
        val e = SilenceEndpointer(cadence)
        e.ingest("what time is it", at = 0)
        assertNull(e.decision(at = cadence.silenceMs - 1))
        val d = e.decision(at = cadence.silenceMs)
        assertEquals(EndpointReason.COMPLETE_THOUGHT, d?.reason)
        assertEquals(cadence.silenceMs, d?.requiredMs)
    }

    @Test
    fun `identical re-emissions do not reset the clock`() {
        val e = SilenceEndpointer(cadence)
        e.ingest("what time is it", at = 0)
        e.ingest("what time is it", at = 1_000)
        e.ingest("what time is it", at = 2_000)
        assertEquals(EndpointReason.COMPLETE_THOUGHT, e.decision(at = cadence.silenceMs)?.reason)
    }

    @Test
    fun `mid-thought partial waits the longer hold`() {
        val e = SilenceEndpointer(cadence)
        e.ingest("tell me about the", at = 0)
        assertNull(e.decision(at = cadence.silenceMs))
        val d = e.decision(at = cadence.holdMs)
        assertEquals(EndpointReason.MID_THOUGHT_HOLD, d?.reason)
    }

    @Test
    fun `please is the spoken submit button and skips the hold`() {
        val e = SilenceEndpointer(cadence)
        e.ingest("tell me about the weather please", at = 0)
        assertNull(e.decision(at = cadence.politeMs - 1))
        val d = e.decision(at = cadence.politeMs)
        assertEquals(EndpointReason.POLITE_WORD, d?.reason)
        assertEquals(cadence.politeMs, d?.requiredMs)
    }

    @Test
    fun `maxWait ends a partial that keeps changing once it finally goes quiet`() {
        val e = SilenceEndpointer(cadence)
        var t = 0L
        while (t < cadence.maxWaitMs) {
            e.ingest("still talking $t and", at = t)
            t += 1_000
        }
        // still advancing: not cut
        assertNull(e.decision(at = t))
        val d = e.decision(at = t + cadence.silenceMs)
        assertEquals(EndpointReason.MAX_WAIT, d?.reason)
    }

    @Test
    fun `learned pause raises later waits and survives reset`() {
        val e = SilenceEndpointer(cadence)
        e.ingest("so the thing is", at = 0)
        // Speaker recovers after a 4s gap — longer than silence — that's their rhythm.
        e.ingest("so the thing is I need help.", at = 4_000)
        assertEquals(4_000, e.observedPauseMs)
        // Complete thought now needs learned + margin, not bare silence.
        assertNull(e.decision(at = 4_000 + cadence.silenceMs))
        assertTrue(e.decision(at = 4_000 + 4_000 + cadence.cadenceMarginMs) != null)
        e.reset()
        assertEquals(4_000, e.observedPauseMs)
    }

    @Test
    fun `learned pause is clamped at the ceiling`() {
        val e = SilenceEndpointer(cadence)
        e.ingest("hmm", at = 0)
        e.ingest("hmm right.", at = 60_000)
        assertEquals(cadence.cadenceCeilingMs, e.observedPauseMs)
    }

    @Test
    fun `shouldEndpoint is exactly decision not null`() {
        val e = SilenceEndpointer(cadence)
        e.ingest("done.", at = 0)
        assertFalse(e.shouldEndpoint(at = 10))
        assertTrue(e.shouldEndpoint(at = cadence.silenceMs))
    }

    @Test
    fun `hold shorter than silence is rejected`() {
        kotlin.test.assertFailsWith<IllegalArgumentException> {
            EndpointCadence(silenceMs = 2_000, holdMs = 1_000)
        }
    }
}
