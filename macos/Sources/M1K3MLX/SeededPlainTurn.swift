//
//  SeededPlainTurn.swift
//  M1K3MLX
//
//  Pure decision for a plain-chat turn on a seeded persona prefix — see
//  SeededPlainTurnTests for the bug it exists to close (the double-BOS render
//  that erased pocket's persona on every plain turn).
//
//  Deliberately narrower than CrossTurnCacheReuse: the only reuse worth having
//  is the whole seed — a partial match means the render and the seed disagree
//  about the persona, and appending to that cache would be positionally wrong
//  KV. Never trims. A seed is only as exact as its cache: reuse also requires
//  the caller to vouch (`seedTrimmed`) that the cache was trimmed back to its
//  ids — a seed that wrapped a sliding window was not, and falls back to a
//  full prefill (correct, unoptimised) instead of appending one position off.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-06, Confidence 0.9. Prior: Unknown
//  Review: claude-fable-5.1, 2026-09-06 — PR #240 review 1: the header claimed
//  every seed is stored trimmed to exactly its ids; renderPersonaPrefix only
//  guarantees that on a linear cache. `seedTrimmed` makes the caller state it
//  (fed by CrossTurnCacheReuse.cacheReusable, the tool path's gate) instead of
//  the seam leaning on the current model roster having no sliding windows.
//  Confidence now 0.9.
//

import Foundation

enum SeededPlainTurn {
    enum Plan: Equatable {
        /// The seed cache holds the first `prefixTokens` of the render; prefill
        /// only `full[prefixTokens...]` on top of it.
        case reuse(prefixTokens: Int)
        /// Prefill the whole render on a fresh cache (correct, unoptimised).
        case fresh
    }

    /// `seed`: the exact token ids the persona cache holds. `full`: the token
    /// ids of the whole `[system, user]` render for this turn.
    ///
    /// `seedTrimmed`: whether the seed cache really holds EXACTLY `seed.count`
    /// positions. `renderPersonaPrefix` prefills one throwaway token and trims
    /// it back off only on a linear cache — a persona that wrapped a sliding
    /// window keeps that extra position (trimming a wrapped RotatingKVCache
    /// underflows its rotation pointer), so its cache is one token longer than
    /// its ids say. Appending to it would be silently misaligned KV — the very
    /// class of bug this seam exists to close — so a non-trimmed seed is never
    /// reused. Pass `CrossTurnCacheReuse.cacheReusable(layersTrimmable:)`.
    static func plan(seed: [Int], full: [Int], seedTrimmed: Bool) -> Plan {
        guard seedTrimmed, !seed.isEmpty, full.count > seed.count, full.starts(with: seed) else {
            return .fresh
        }
        return .reuse(prefixTokens: seed.count)
    }
}
