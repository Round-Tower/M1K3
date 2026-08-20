package app.m1k3.ai.domain.voice

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class PoliteEndpointTest {
    @Test
    fun `trailing please submits, punctuation peeled`() {
        assertTrue(PoliteEndpoint.isSubmit("what's the time please"))
        assertTrue(PoliteEndpoint.isSubmit("What's the time, Please?"))
        assertTrue(PoliteEndpoint.isSubmit("please"))
    }

    @Test
    fun `mid-sentence or partial-word please does not submit`() {
        assertFalse(PoliteEndpoint.isSubmit("please tell me the time"))
        assertFalse(PoliteEndpoint.isSubmit("I'm pleased"))
        assertFalse(PoliteEndpoint.isSubmit(""))
    }

    @Test
    fun `ui hint is the shared literal`() {
        assertEquals("End with “please” and M1K3 will take its turn", PoliteEndpoint.UI_HINT)
    }
}
