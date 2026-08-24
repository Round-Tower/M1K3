package app.m1k3.ai.assistant.eval

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class EvalResultTest {
    private fun sampleReport() =
        EvalRunReport(
            run =
                EvalRunMeta(
                    model = EvalModelKey.MINI,
                    thinkingRequested = false,
                    thinkingEffective = false,
                    cpuVariantRequested = "libggml-cpu-android_armv9.0_1.so",
                    cpuVariantLoaded = "libggml-cpu-android_armv9.0_1.so",
                    timestampMs = 1_755_000_000_000L,
                ),
            results =
                listOf(
                    EvalResult(
                        fixtureId = "chat-hello",
                        kind = "open-chat",
                        passed = true,
                        answer = "Hey there!",
                        toolsCalled = emptyList(),
                        chars = 10,
                        tokens = 4,
                        generateMs = 812,
                        firstTokenMs = 210,
                    ),
                    EvalResult(
                        fixtureId = "small-talk-capabilities",
                        kind = "small-talk",
                        passed = false,
                        failedChecks = listOf("called tool(s) when none were expected: [get_battery_level]"),
                        answer = "Checking your battery...",
                        toolsCalled = listOf("get_battery_level"),
                        chars = 25,
                        tokens = 6,
                        generateMs = 1400,
                    ),
                ),
        )

    @Test
    fun `round-trips through JSON`() {
        val report = sampleReport()
        val json = report.toJson()
        val parsed = parseEvalRunReport(json)

        assertEquals(report, parsed)
    }

    @Test
    fun `JSON carries the broken-logits shape a tripwire can read`() {
        val json = sampleReport().toJson()
        assertTrue(json.contains("armv9.0_1"))
        assertTrue(json.contains("cpuVariantLoaded"))
    }

    @Test
    fun `an errored fixture is representable without a passed verdict`() {
        val result =
            EvalResult(
                fixtureId = "tool-datetime",
                kind = "tool-use",
                passed = false,
                answer = "",
                chars = 0,
                tokens = 0,
                generateMs = 5,
                error = "engine init failed: no model file",
            )
        val json =
            EvalRunReport(
                run = sampleReport().run,
                results = listOf(result),
            ).toJson()
        val parsed = parseEvalRunReport(json)

        assertEquals("engine init failed: no model file", parsed.results.single().error)
    }
}
