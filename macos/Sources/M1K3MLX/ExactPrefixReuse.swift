//
//  ExactPrefixReuse.swift
//  M1K3MLX
//
//  Pure decision for prefix reuse on a cache that can NEVER be trimmed — see
//  ExactPrefixReuseTests for the worked cases.
//
//  CrossTurnCacheReuse rolls a live cache forward by trimming each turn's sampled
//  tail back off. A recurrent layer (Qwen3.5's MambaCache) can't be trimmed, so
//  once a turn samples into it the cache is spent. What survives is an EXACT
//  prefix: a cache prefilled without sampling, holding exactly its ids, plus the
//  model state that belongs with it (MLXVLM's Qwen3.5 throws `missingState`
//  without its rope deltas — measured, SeededPrefillProbe 2026-10-07). Each send
//  extends a copy of the best such prefix up to the render's LAST token, keeps
//  that as the next checkpoint, and generates from the one token left. Only the
//  rolling checkpoint keeps per-step cost flat; the persona alone would re-prefill
//  the whole transcript every step (the challenger's catch, 2026-10-07).
//
//  Honest limit: per-step cost is flat EXCEPT on image turns. A turn carrying
//  images always prefills fresh (the pixels ride beside the ids, so no checkpoint
//  is a prefix of it) and the session keeps only the pristine seed afterwards, so
//  the step after an image send re-prefills the whole transcript from the persona.
//  Re-seeding after a fresh/image send is the open #509 follow-up. RAM is the
//  other cost: each checkpoint is a full-precision copy of the transcript's cache,
//  so the per-step snapshot (`stepSnapshotLabel`) is what says "flat" holds.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.85, Prior: none (new file).
//  The arithmetic is pinned; the copy/prefill/state plumbing is verify-by-launch.
//  Review: Kev + claude-fable-5.1, 2026-10-09 — the header says where "flat per step" stops (image
//  turns); `stepSnapshotLabel` names the per-step memory snapshot MLXToolTurnSession now logs in
//  checkpoint mode (#509 follow-up: peak RSS per step). The curve itself is verify-by-launch.
//

import Foundation

enum ExactPrefixReuse {
    enum Plan: Equatable {
        /// Copy candidate `candidate` (which holds `full[..<from]`), prefill
        /// `full[from..<to]` into the copy without sampling — that copy is the next
        /// checkpoint — then generate from `full[to...]`, the single last token.
        case extend(candidate: Int, from: Int, to: Int)
        /// Prefill the whole render on a fresh cache (correct, unoptimised).
        case fresh
    }

    /// Whether a session keeps checkpoints instead of rolling its live cache: the
    /// seed is exact AND some layer can't be trimmed. Trimmable caches keep the
    /// live-cache path; a seed nobody vouched exact holds a sampled position.
    static func usesCheckpoints(seedExact: Bool, seedLayersTrimmable: [Bool]) -> Bool {
        seedExact && seedLayersTrimmable.contains(false)
    }

    /// The label for the per-step memory snapshot MLXToolTurnSession logs after
    /// each checkpoint-mode send (`MLXMemoryBudget.logSnapshot`): the 1-based
    /// step and the reuse it got, so a transcript's RAM reads as a curve in the
    /// unified log — the number that says whether "flat per step" holds, since
    /// every checkpoint is a full-precision copy of the transcript's cache.
    static func stepSnapshotLabel(step: Int, reused: Int, total: Int) -> String {
        "toolTurnSession checkpoint step \(step) (reused \(reused)/\(total))"
    }

    /// `candidates`: the ids each exact prefix holds. The longest STRICT prefix of
    /// `full` wins; a partial match is worthless (no trim to roll back past the
    /// divergence). Never the whole render — generation needs one token of input.
    static func plan(candidates: [[Int]], full: [Int], turnCarriesImages: Bool = false) -> Plan {
        guard !turnCarriesImages else { return .fresh }
        let usable = { (ids: [Int]) in !ids.isEmpty && ids.count < full.count && full.starts(with: ids) }
        let best = candidates.indices
            .filter { usable(candidates[$0]) }
            .max { candidates[$0].count < candidates[$1].count }
        guard let best else { return .fresh }
        return .extend(candidate: best, from: candidates[best].count, to: full.count - 1)
    }
}
