package app.m1k3.ai.domain.avatar

import kotlin.test.Test
import kotlin.test.assertEquals

class Companion3DPolicyTest {
    private fun healthy() =
        Companion3DInputs(
            availableMemMb = 4096,
            isLowRamDevice = false,
            glesMajorVersion = 3,
            brainResident = true,
            userEnabled = true,
        )

    @Test
    fun `healthy device with resident brain shows 3D`() {
        assertEquals(Companion3DDecision.SHOW_3D, Companion3DPolicy.decide(healthy()))
    }

    @Test
    fun `user opt-out falls back to 2D`() {
        assertEquals(
            Companion3DDecision.FALLBACK_2D,
            Companion3DPolicy.decide(healthy().copy(userEnabled = false)),
        )
    }

    @Test
    fun `low-RAM device falls back to 2D`() {
        assertEquals(
            Companion3DDecision.FALLBACK_2D,
            Companion3DPolicy.decide(healthy().copy(isLowRamDevice = true)),
        )
    }

    @Test
    fun `GL ES below 3 falls back to 2D`() {
        assertEquals(
            Companion3DDecision.FALLBACK_2D,
            Companion3DPolicy.decide(healthy().copy(glesMajorVersion = 2)),
        )
    }

    @Test
    fun `brain not yet resident falls back to 2D (never GL during model load)`() {
        assertEquals(
            Companion3DDecision.FALLBACK_2D,
            Companion3DPolicy.decide(healthy().copy(brainResident = false)),
        )
    }

    @Test
    fun `insufficient free memory falls back to 2D`() {
        assertEquals(
            Companion3DDecision.FALLBACK_2D,
            Companion3DPolicy.decide(healthy().copy(availableMemMb = Companion3DPolicy.MIN_HEADROOM_MB - 1)),
        )
    }

    @Test
    fun `heavy resident brain (Big) falls back to 2D even with headroom`() {
        assertEquals(
            Companion3DDecision.FALLBACK_2D,
            Companion3DPolicy.decide(healthy().copy(residentBrainHeavy = true)),
        )
    }

    @Test
    fun `exactly the headroom floor shows 3D`() {
        assertEquals(
            Companion3DDecision.SHOW_3D,
            Companion3DPolicy.decide(healthy().copy(availableMemMb = Companion3DPolicy.MIN_HEADROOM_MB)),
        )
    }
}
