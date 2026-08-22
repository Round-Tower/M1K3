package app.m1k3.ai.domain.ai

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * [SystemBrainResolver] exists because of a Pixel 9a ANR (2026-08-22): the
 * probe was run under `runBlocking` on the main thread inside a Koin `single`,
 * and ML Kit delivers `checkStatus()` via a main-looper callback — a deadlock.
 * The resolver must NEVER block: `current` answers immediately.
 */
class SystemBrainResolverTest {
    private class GatedProbe(
        val gate: CompletableDeferred<SystemBrainAvailability> = CompletableDeferred(),
        var calls: Int = 0,
    ) : SystemBrainProbe {
        override suspend fun availability(): SystemBrainAvailability {
            calls++
            return gate.await()
        }

        override fun download(): Flow<SystemBrainAvailability> = emptyFlow()
    }

    @Test
    fun `current is weights before the probe answers and never blocks`() =
        runTest {
            val probe = GatedProbe()
            val resolver = SystemBrainResolver(probe, LlmModel.Qwen35_0B8)
            resolver.start(this)
            assertEquals(MiniBrain.Weights(LlmModel.Qwen35_0B8), resolver.current)
            probe.gate.complete(SystemBrainAvailability.Available)
            assertEquals(MiniBrain.SystemModel, resolver.resolved())
            assertEquals(MiniBrain.SystemModel, resolver.current)
        }

    @Test
    fun `unavailable resolves to weights`() =
        runTest {
            val probe = GatedProbe(CompletableDeferred(SystemBrainAvailability.Unavailable("no aicore")))
            val resolver = SystemBrainResolver(probe, LlmModel.Qwen35_0B8)
            resolver.start(this)
            assertEquals(MiniBrain.Weights(LlmModel.Qwen35_0B8), resolver.resolved())
        }

    @Test
    fun `probe runs once per process`() =
        runTest {
            val probe = GatedProbe(CompletableDeferred(SystemBrainAvailability.Available))
            val resolver = SystemBrainResolver(probe, LlmModel.Qwen35_0B8)
            resolver.start(this)
            resolver.start(this)
            resolver.resolved()
            resolver.resolved()
            assertEquals(1, probe.calls)
        }

    @Test
    fun `a probe that throws resolves to weights`() =
        runTest {
            val probe =
                object : SystemBrainProbe {
                    override suspend fun availability(): SystemBrainAvailability = error("boom")

                    override fun download(): Flow<SystemBrainAvailability> = emptyFlow()
                }
            val resolver = SystemBrainResolver(probe, LlmModel.Qwen35_0B8)
            resolver.start(this)
            assertTrue(resolver.resolved() is MiniBrain.Weights)
        }
}
