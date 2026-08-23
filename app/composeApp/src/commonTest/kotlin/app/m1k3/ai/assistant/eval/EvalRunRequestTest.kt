package app.m1k3.ai.assistant.eval

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertNull

class EvalRunRequestTest {
    @Test
    fun `an ordinary launch with no eval extras is a no-op`() {
        assertNull(EvalRunRequest.fromExtras(emptyMap()))
        assertNull(EvalRunRequest.fromExtras(mapOf("android.intent.extra.TEXT" to "hi")))
    }

    @Test
    fun `the androidMain caller's all-keys-null map is a no-op (launch-crash regression)`() {
        // EvalHarness.installFromIntent builds the map by associating EVERY
        // eval extra name with intent.getStringExtra(it), so on an ordinary
        // launch all the m1k3.eval.* KEYS are present with null values. The
        // no-op guard must key off null VALUES, not key presence — otherwise a
        // normal launcher tap throws "fixtures is required" in onCreate and the
        // app crashes on launch (2026-08-23).
        val normalLaunch =
            mapOf(
                "m1k3.eval.fixtures" to null,
                "m1k3.eval.out" to null,
                "m1k3.eval.model" to null,
                "m1k3.eval.cpu_variant" to null,
                "m1k3.eval.thinking" to null,
            )
        assertNull(EvalRunRequest.fromExtras(normalLaunch))
    }

    @Test
    fun `parses the minimal required extras`() {
        val request =
            EvalRunRequest.fromExtras(
                mapOf(
                    "m1k3.eval.fixtures" to "/data/local/tmp/fixtures.json",
                    "m1k3.eval.out" to "results.json",
                ),
            )

        assertEquals("/data/local/tmp/fixtures.json", request?.fixturesPath)
        assertEquals("results.json", request?.outPath)
        assertNull(request?.model)
        assertNull(request?.thinking)
        assertNull(request?.cpuVariant)
    }

    @Test
    fun `parses every override`() {
        val request =
            EvalRunRequest.fromExtras(
                mapOf(
                    "m1k3.eval.fixtures" to "fixtures.json",
                    "m1k3.eval.out" to "out.json",
                    "m1k3.eval.model" to EvalModelKey.MINI,
                    "m1k3.eval.thinking" to "true",
                    "m1k3.eval.cpu_variant" to "libggml-cpu-android_armv9.0_1.so",
                ),
            )

        assertEquals(EvalModelKey.MINI, request?.model)
        assertEquals(true, request?.thinking)
        assertEquals("libggml-cpu-android_armv9.0_1.so", request?.cpuVariant)
    }

    @Test
    fun `thinking parses false and is case-insensitive`() {
        val request =
            EvalRunRequest.fromExtras(
                mapOf(
                    "m1k3.eval.fixtures" to "f.json",
                    "m1k3.eval.out" to "o.json",
                    "m1k3.eval.thinking" to "FALSE",
                ),
            )
        assertEquals(false, request?.thinking)
    }

    @Test
    fun `an invalid thinking value fails loudly`() {
        assertFailsWith<IllegalStateException> {
            EvalRunRequest.fromExtras(
                mapOf(
                    "m1k3.eval.fixtures" to "f.json",
                    "m1k3.eval.out" to "o.json",
                    "m1k3.eval.thinking" to "maybe",
                ),
            )
        }
    }

    @Test
    fun `missing out with fixtures present fails loudly rather than silently no-op`() {
        assertFailsWith<IllegalArgumentException> {
            EvalRunRequest.fromExtras(mapOf("m1k3.eval.fixtures" to "f.json"))
        }
    }

    @Test
    fun `missing fixtures with out present fails loudly`() {
        assertFailsWith<IllegalArgumentException> {
            EvalRunRequest.fromExtras(mapOf("m1k3.eval.out" to "o.json"))
        }
    }

    @Test
    fun `an eval extra with no fixtures or out still fails loudly`() {
        assertFailsWith<IllegalArgumentException> {
            EvalRunRequest.fromExtras(mapOf("m1k3.eval.model" to EvalModelKey.LIL))
        }
    }
}
