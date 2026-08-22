package app.m1k3.ai.domain.ai

import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class CpuVariantOverrideTest {
    @AfterTest
    fun resetOverride() {
        CpuVariantOverride.preferred = null
    }

    @Test
    fun `defaults to null — production never overrides`() {
        assertNull(CpuVariantOverride.preferred)
    }

    @Test
    fun `is settable and readable`() {
        CpuVariantOverride.preferred = "libggml-cpu-android_armv9.0_1.so"
        assertEquals("libggml-cpu-android_armv9.0_1.so", CpuVariantOverride.preferred)
    }
}
