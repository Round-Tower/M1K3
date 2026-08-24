package app.m1k3.ai.domain.ai

import kotlin.test.AfterTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull

class NativeDiagnosticsTest {
    @AfterTest
    fun reset() {
        NativeDiagnostics.lastLoadedCpuVariant = null
    }

    @Test
    fun `defaults to null before any model loads`() {
        assertNull(NativeDiagnostics.lastLoadedCpuVariant)
    }

    @Test
    fun `is settable and readable`() {
        NativeDiagnostics.lastLoadedCpuVariant = "libggml-cpu-android_armv8.6_1.so"
        assertEquals("libggml-cpu-android_armv8.6_1.so", NativeDiagnostics.lastLoadedCpuVariant)
    }
}
