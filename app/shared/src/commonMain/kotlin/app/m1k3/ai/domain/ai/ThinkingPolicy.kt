package app.m1k3.ai.domain.ai

/**
 * ThinkingPolicy — which brains get to reason in <think> before answering.
 *
 * None, by default. On the Pixel 9a (2026-08-22) Mini (Qwen3.5-0.8B) burned
 * its whole 2048-token budget reasoning about the prompt's own structure —
 * 171s of silence, then an empty bubble — and Lil (2B) did the same (a 180s,
 * empty answer on 2026-08-23). Big (Gemma 4 E2B) was the last tier left
 * thinking-on; the 2026-08-23 re-baseline settled it: thinking-ON scored
 * WORSE than off (14/24 vs 16/24), ran 4.3x slower (53.9s vs 12.6s median),
 * AND leaked its <|channel>thought reasoning into visible answers (the parser
 * has no Gemma channel arm). So on-device reasoning is off for every tier on
 * a phone; the model answers better fast than it reasons slow. Qwen's
 * documented soft switch (an empty <think></think> block pre-filled in the
 * assistant turn) turns it off without touching the weights. Revisit per
 * model with the eval harness, never by feel.
 *
 * Signed: Kev + claude-opus-4-8, 2026-08-23, Confidence 0.85 (each tier's
 * failure is read off a device eval — Mini/Lil the empty-answer burn, Big the
 * 14-vs-16 + 53.9s + channel-leak measurement; single-run, so the Big deltas
 * carry run noise, but the direction and the channel leak are unambiguous).
 * Prior: Kev + claude-fable-5 (2026-08-22).
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

    fun enabled(model: LlmModel): Boolean = override ?: DEFAULT_THINKING

    /**
     * No tier reasons on-device by default (2026-08-23). Left as a named
     * constant, not an inline `false`, so the next model measured to benefit
     * from thinking has one obvious place to re-open the question — per model,
     * with the eval harness.
     */
    private const val DEFAULT_THINKING = false
}
