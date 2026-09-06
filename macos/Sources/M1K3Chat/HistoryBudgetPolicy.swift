//
//  HistoryBudgetPolicy.swift
//  M1K3Chat
//
//  Brain-aware sizing for the conversation replay (the long-context work). The
//  per-message text replay (HistoryWindow) is correct-by-construction — nothing
//  to invalidate — but how WIDE it can safely go is a per-tier fact, not a knob:
//    • dense Qwen3 (lil) holds a ~32K window in an unbounded KVCacheSimple —
//      a wide replay costs memory, never truncates.
//    • gemma-4-12B (big) holds a HARD RotatingKVCache(maxSize: 8192) — a prompt
//      over the window silently rotates the persona/grounding HEAD out during
//      prefill, answering off-persona and ungrounded with NO error. So `big`
//      MUST be clamped below 8192 (with margin for the char≈token estimate).
//
//  This pure policy turns a tier + the fixed-prompt reserve into a
//  `HistoryWindow.Budget`. It keeps `perTurnChars ≤ totalChars` so the rendered
//  block is provably ≤ totalChars (the rotating-KV clamp invariant), and caps the
//  replay at a latency ceiling so re-prefill cost stays bounded (replay prefill
//  does not amortize — the honest tradeoff for skipping KV persistence).
//
//  The char≈token ratio is a heuristic (the safety net is the conservative ratio
//  + the rotating margin + the on-device SelfTest verify that gemma's head never
//  rotates). Tune `charsPerToken`/`defaultLatencyCeilingTokens` from the ttft-log
//  token counts — the named [SPIKE].
//
//  Signed: Kev + claude-opus-4-8, 2026-06-30, Confidence 0.8 (the gemma-8192
//  clamp invariant is TDD-pinned; the real-token guarantee for dense/URL text is
//  the verify-owed the margin hedges). Prior: the long-context design memo.
//  Review: Kev + claude-fable-5, 2026-07-02, Confidence 0.85 — added
//  rotatingGenerationTokenCap + generationTokenCap(for:): the budget above
//  bounds PREFILL only, so the live provider's DECODE must be capped to the
//  same figure the budget reserves (the uncapped 4096 default crossed gemma's
//  window mid-answer and silently rotated the persona head out — the #112
//  review blocker). perTurn/maxTurns now reference HistoryWindow's constants
//  (one home, no silent divergence). Review-debt paydown: #112-1, #112-3.
//  Review: Kev + claude-fable-5.1, 2026-09-06 — margin + generation cap key on `hasClampedContext` (Big AND pocket)
//  rather than the cache mechanism — pocket's 8k window is the 3.5 GB device's jetsam budget, and without the cap a
//  long chat plus a 4096-token decode could ask an unbounded KVCacheSimple for ~10k tokens (PR #234 review 4).
//  Confidence now 0.85.
//

import Foundation
import M1K3Inference

public enum HistoryBudgetPolicy {
    /// Chars-per-token estimate. Conservative for English PROSE (real ≈4 chars/
    /// token, so a char budget maps to FEWER tokens than the model counts — the
    /// safe direction). The RESIDUAL RISK is the other way: dense code/URL/CJK
    /// text tokenizes DENSER (≈3 / ≈1 chars/token), so the same chars cost MORE
    /// tokens than estimated — on a rotating tier that eats into the window. The
    /// `rotatingSafetyMarginTokens` buffer hedges the common (code) case; CJK and
    /// the hard guarantee need real token counting (the deferred provider seam /
    /// [SPIKE]). The on-device SelfTest fixture should include a code-paste turn.
    static let charsPerToken = 3.5
    /// Don't re-prefill the whole conversation every turn even when the model
    /// could hold it: cap the replay so TTFT stays bounded (replay prefill does
    /// not amortize). The wide-context tiers hit this before their real window.
    public static let defaultLatencyCeilingTokens = 8000
    /// Head-room subtracted on a rotating-KV tier to absorb the char≈token
    /// estimate error, so gemma's 8192 window isn't crossed in practice. 1024
    /// (≈3600 chars of buffer) covers a moderate code paste in the replay at the
    /// worst-case ≈3 chars/token; a CJK-heavy replay still needs real token
    /// counting (named residual — the gemma cliff is silent, so we over-reserve).
    static let rotatingSafetyMarginTokens = 1024
    /// Generation cap for the LIVE chat provider on a rotating-KV tier. The
    /// budget above only bounds PREFILL; gemma's 8192 window holds only if
    /// prefill + decode fit together, so the decode side must be capped to the
    /// same figure the budget reserves. An uncapped 4096 default crosses the
    /// window ~3K tokens into a routine long answer and silently rotates the
    /// persona/grounding head out. (The eval harness already ran at 2048; this
    /// aligns the live path with it.)
    public static let rotatingGenerationTokenCap = 2048

    /// Apple Foundation Models (mini) has its own ~4K window, and its real
    /// effective budget is unmeasured (the [SPIKE]). So mini gets a fixed
    /// CONSERVATIVE replay — wider per-turn than the legacy 6×400 (less answer
    /// mangling) but well under the window — NOT the wide MLX default and NOT
    /// the tier policy (whose MLX-sized reserves would zero it out).
    ///
    /// ⚠️ This comment used to add "and fails LOUDLY on overflow". It does NOT,
    /// and that belief has now caused two bugs. AFM throws on overflow from
    /// `generate`, but `generateStreaming` — the live chat path — could only
    /// end the stream, so an overflow arrived as an ordinary empty answer. The
    /// same belief exempted Mini from `GroundingBudget` entirely until #101.
    /// As of 2026-08-09 the throw is at least CLASSIFIED and logged
    /// (`AFMFailure`), but it is still not loud to the caller. Size for Mini as
    /// if a miss is silent, because it is.
    public static let conservativeMiniBudget = HistoryWindow.Budget(
        totalChars: 3000, perTurnChars: 750, maxTurns: 8
    )

    /// Replay chars surrendered per attached image: an image's vision soft
    /// tokens ride the SAME window as everything else, and the only tier
    /// that sees images (Big) is the one whose rotating cache overflows
    /// SILENTLY. ~265 prompt tokens/image measured on gemma-4-12B
    /// (GemmaVisionSpike, 2026-07-14); 300 tokens × charsPerToken is the
    /// conservative reserve. Review fold, PR #62.
    public static let imageReserveCharsPerImage = Int(300 * charsPerToken)

    /// The replay budget for a tier, reserving room for the fixed prompt (persona
    /// + tools + grounding + goal, in `reservedTokens`) and the generation
    /// headroom (`generationTokens`). On a rotating-KV tier the result is
    /// hard-clamped with margin so the TOTAL prompt provably stays under the
    /// window. The latency ceiling caps the replay on the wide tiers.
    public static func budget(
        for tier: BrainTier,
        reservedTokens: Int,
        generationTokens: Int,
        latencyCeilingTokens: Int = defaultLatencyCeilingTokens
    ) -> HistoryWindow.Budget {
        let margin = tier.hasClampedContext ? rotatingSafetyMarginTokens : 0
        let contextTokens = max(
            0, tier.approximateContextTokens - reservedTokens - generationTokens - margin
        )
        let historyTokens = min(contextTokens, max(0, latencyCeilingTokens))
        let totalChars = Int(Double(historyTokens) * charsPerToken)
        // Per-turn fidelity cap and turn ceiling are HistoryWindow's own
        // constants — one home, so tuning the window can't strand the policy.
        let perTurnChars = min(HistoryWindow.maxCharsPerTurn, totalChars)
        return HistoryWindow.Budget(
            totalChars: totalChars, perTurnChars: perTurnChars, maxTurns: HistoryWindow.maxTurns
        )
    }

    /// Tier-optional variant that OWNS the mini/unknown guard: nil (an unknown
    /// persisted brain string) and .mini both get the fixed conservative replay
    /// — AFM manages its own ~4K window and the MLX-sized reserves would zero
    /// it out — everything else delegates to `budget(for:reservedTokens:...)`.
    /// Composition roots call this one-liner instead of re-implementing the
    /// guard (112 review nit: brain routing belongs in the package, not app glue).
    public static func budget(
        for tier: BrainTier?,
        reservedTokens: Int,
        generationTokens: Int,
        latencyCeilingTokens: Int = defaultLatencyCeilingTokens
    ) -> HistoryWindow.Budget {
        guard let tier, tier != .mini else { return conservativeMiniBudget }
        return budget(
            for: tier,
            reservedTokens: reservedTokens,
            generationTokens: generationTokens,
            latencyCeilingTokens: latencyCeilingTokens
        )
    }

    /// The `maxTokens` the app should construct the MLX provider with for
    /// `tier` — capped on a rotating-KV tier (see `rotatingGenerationTokenCap`),
    /// the provider's default elsewhere.
    public static func generationTokenCap(for tier: BrainTier, defaultCap: Int = 4096) -> Int {
        tier.hasClampedContext ? min(rotatingGenerationTokenCap, defaultCap) : defaultCap
    }
}
