package app.m1k3.ai.domain.avatar

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class CrtTreatmentTest {
    @Test
    fun `active tube runs hotter than resting`() {
        val resting = CrtTreatment.forActivity(isActive = false, intensity = 0.5f)
        val active = CrtTreatment.forActivity(isActive = true, intensity = 0.7f)
        assertTrue(active.phosphorGlow > resting.phosphorGlow, "active should glow more")
        assertTrue(active.flickerHz > resting.flickerHz, "active should hum faster")
        assertTrue(active.aberration > resting.aberration, "active should fringe more")
    }

    @Test
    fun `intensity scales active glow monotonically`() {
        val low = CrtTreatment.forActivity(isActive = true, intensity = 0f)
        val high = CrtTreatment.forActivity(isActive = true, intensity = 1f)
        assertTrue(high.phosphorGlow > low.phosphorGlow)
    }

    @Test
    fun `intensity is clamped so out-of-range never overshoots`() {
        val over = CrtTreatment.forActivity(isActive = true, intensity = 5f)
        val at1 = CrtTreatment.forActivity(isActive = true, intensity = 1f)
        assertEquals(at1.phosphorGlow, over.phosphorGlow)
    }

    @Test
    fun `all fields stay in sane ranges`() {
        for (active in listOf(true, false)) {
            for (i in listOf(0f, 0.5f, 1f)) {
                val t = CrtTreatment.forActivity(active, i)
                assertTrue(t.phosphorGlow in 0f..1f)
                assertTrue(t.scanlineStrength in 0f..1f)
                assertTrue(t.aberration in 0f..1f)
                assertTrue(t.flickerHz > 0f)
            }
        }
    }
}
