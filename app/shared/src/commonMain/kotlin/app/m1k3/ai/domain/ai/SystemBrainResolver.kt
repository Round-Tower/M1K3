package app.m1k3.ai.domain.ai

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch

/**
 * SystemBrainResolver — resolves [MiniBrain] ONCE per process, off the caller's
 * thread, and never blocks.
 *
 * Why this exists: the first cut resolved the brain inside a Koin `single` with
 * `runBlocking { probe.availability() }`. On a Pixel 9a that deadlocked the main
 * thread into an ANR (2026-08-22) — ML Kit's `checkStatus()` answers through a
 * main-looper callback, which can't run while main is parked in `runBlocking`.
 *
 * Contract:
 * - [start] launches the probe on the given scope (the app passes an IO scope
 *   at launch). Idempotent.
 * - [current] answers immediately: the resolved brain, or [MiniBrain.Weights]
 *   while the probe is still out (or if [start] was never called). An engine
 *   built during that window runs our weights — honest, logged by the caller,
 *   corrected on the next launch. On a fresh install the weights download takes
 *   far longer than the probe, so in practice the probe wins.
 * - [resolved] suspends until the probe has answered; for callers already off
 *   the main thread.
 * - A probe that throws resolves to weights (failing safe is the whole point).
 *
 * Signed: Kev + claude-fable-5, 2026-08-22, Confidence 0.85 (the deadlock is
 * read off the device — ANR at engine-build time with an idle 6MB heap — not
 * proven with a main-thread stack, which needs root to read). Prior: Unknown.
 */
class SystemBrainResolver(
    private val probe: SystemBrainProbe,
    private val weights: LlmModel,
) {
    private val result = CompletableDeferred<MiniBrain>()
    private var started = false

    val current: MiniBrain
        get() = if (result.isCompleted) result.getCompleted() else MiniBrain.Weights(weights)

    fun start(scope: CoroutineScope) {
        if (started) return
        started = true
        scope.launch {
            val brain =
                try {
                    MiniBrainPolicy.resolve(probe.availability())
                } catch (e: Exception) {
                    MiniBrain.Weights(weights)
                }
            result.complete(brain)
        }
    }

    suspend fun resolved(): MiniBrain = result.await()
}
