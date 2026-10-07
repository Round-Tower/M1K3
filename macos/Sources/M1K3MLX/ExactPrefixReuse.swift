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
//  Signed: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.85, Prior: none (new file).
//  The arithmetic is pinned; the copy/prefill/state plumbing is verify-by-launch.
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

    /// `candidates`: the ids each exact prefix holds. The longest STRICT prefix of
    /// `full` wins; a partial match is worthless (no trim to roll back past the
    /// divergence). Never the whole render — generation needs one token of input.
    static func plan(candidates: [[Int]], full: [Int], turnCarriesImages: Bool = false) -> Plan {
        guard !turnCarriesImages else { return .fresh }
        let best = candidates.indices
            .filter { !candidates[$0].isEmpty && candidates[$0].count < full.count && full.starts(with: candidates[$0]) }
            .max { candidates[$0].count < candidates[$1].count }
        guard let best else { return .fresh }
        return .extend(candidate: best, from: candidates[best].count, to: full.count - 1)
    }
}
