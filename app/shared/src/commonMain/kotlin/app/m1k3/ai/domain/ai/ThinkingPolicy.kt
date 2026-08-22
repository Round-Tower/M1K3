package app.m1k3.ai.domain.ai

/**
 * ThinkingPolicy — which brains get to reason in <think> before answering.
 *
 * Only Big. On the Pixel 9a (2026-08-22) Mini (Qwen3.5-0.8B, thinking-by-
 * default) burned its whole 2048-token budget reasoning about the prompt's
 * own structure — 171s of silence, then an empty bubble. A 0.8B/2B brain
 * answers better fast than it reasons slow; Qwen's documented soft switch
 * (an empty <think></think> block pre-filled in the assistant turn) turns it
 * off without touching the weights. Revisit per model with the eval harness,
 * never by feel.
 *
 * Signed: Kev + claude-fable-5, 2026-08-22, Confidence 0.8 (the failure is
 * read off a device log; "better fast than slow" for Lil is a judgement
 * pending the on-device eval). Prior: Unknown.
 *
 * [override] is the eval harness's seam (`tools/eval/android`): the matrix
 * needs to force thinking on/off per cell regardless of tier, so the
 * per-model default below isn't the only word. Set before any
 * `ChatScreenViewModel`/`ChatWithToolsUseCase` is constructed — both read
 * [enabled] once, at construction/prime time, not on every turn. `null`
 * (the default) restores the per-model default.
 */
object ThinkingPolicy {
    var override: Boolean? = null

    fun enabled(model: LlmModel): Boolean = override ?: (model == LlmModel.Gemma4_E2B)
}
