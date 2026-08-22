package app.m1k3.ai.domain.ai

import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertIs

/**
 * [StubSystemBrainProbe] is the always-unavailable binding for platforms
 * without a system model (iOS/desktop today) and for tests that don't want
 * ML Kit specifics. It must always resolve to the Qwen-weights fallback via
 * [MiniBrainPolicy].
 */
class SystemBrainProbeTest {
    @Test
    fun `stub probe reports unavailable`() =
        runTest {
            assertIs<SystemBrainAvailability.Unavailable>(StubSystemBrainProbe.availability())
        }

    @Test
    fun `stub probe download emits a single unavailable terminal value`() =
        runTest {
            assertIs<SystemBrainAvailability.Unavailable>(StubSystemBrainProbe.download().first())
        }

    @Test
    fun `stub probe always resolves to weights fallback`() =
        runTest {
            val availability = StubSystemBrainProbe.availability()
            val brain = MiniBrainPolicy.resolve(availability)
            assertIs<MiniBrain.Weights>(brain)
        }
}
