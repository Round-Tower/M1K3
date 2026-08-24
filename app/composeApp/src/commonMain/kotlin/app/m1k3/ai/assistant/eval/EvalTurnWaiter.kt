package app.m1k3.ai.assistant.eval

import app.m1k3.ai.assistant.chat.GenerationState
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull

/**
 * waitForTurnCompletion — the exact fix for a real bug found live on-device
 * running the very first Android eval matrix (2026-08-22): `EvalRunner`
 * called `viewModel.sendMessage()` then immediately did
 * `states.first { it is Complete || it is Failed }`. `sendMessage()`
 * dispatches on `viewModelScope` — it does NOT update `generationState`
 * synchronously — so `Flow.first{}` (which checks the CURRENT value before
 * waiting for a new emission) matched the PREVIOUS fixture's still-terminal
 * `Complete`/`Failed` state before the new turn had even started. Every
 * fixture after the first silently re-scored fixture #1's exact answer,
 * token count, and timing — 18 of 22 fixtures failed for reasons that had
 * nothing to do with the model.
 *
 * Fix: confirm the turn actually LEFT the terminal state (reached
 * `Thinking`/`Streaming`) before waiting for it to reach a terminal state
 * again. This also covers the very first fixture correctly — starting from
 * `Idle`, which isn't terminal either, so the same two-phase wait applies
 * unconditionally rather than needing a special case.
 *
 * Pure over an injected [Flow] so the race itself is unit-testable without a
 * real [app.m1k3.ai.assistant.chat.ChatScreenViewModel] — `EvalRunner`
 * (androidMain) is the only real caller, feeding `viewModel.uiState`
 * (mapped to its `generationState` field).
 *
 * @return the terminal [GenerationState] ([GenerationState.Complete] or
 *   [GenerationState.Failed]), or null if the turn never started or never
 *   finished within its respective timeout.
 */
suspend fun waitForTurnCompletion(
    states: Flow<GenerationState>,
    turnStartTimeoutMs: Long,
    fixtureTimeoutMs: Long,
    onStreaming: () -> Unit = {},
): GenerationState? {
    val started =
        withTimeoutOrNull(turnStartTimeoutMs) {
            states.first { it is GenerationState.Thinking || it is GenerationState.Streaming }
        }
    if (started == null) return null

    return withTimeoutOrNull(fixtureTimeoutMs) {
        states.first { state ->
            if (state is GenerationState.Streaming) onStreaming()
            state is GenerationState.Complete || state is GenerationState.Failed
        }
    }
}
