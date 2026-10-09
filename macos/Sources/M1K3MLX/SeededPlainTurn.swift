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
//  Review: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.8 — `seedBuild(freshLayersTrimmable:)`:
//  a cache with any untrimmable layer is seeded by a sample-free prefill, so pocket's seed is exact
//  and `plan` can reuse it (the caller now passes the builder's `exact`, not layer trimmability).
//
//  Review: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.85 — `quantizesKV` is gone: a quantizing
//  hybrid (Qwen3.5, kvBits 8 + MambaCache) takes the exact prefill too. Its premise — an unquantized
//  seed is wrong where the turn quantizes — was false by reading (the plan applies after prepare and
//  legacy kvBits validates a mixed cache); the challenger's read, 2026-10-07.

import Foundation

enum SeededPlainTurn {
    enum Plan: Equatable {
        /// The seed cache holds the first `prefixTokens` of the render; prefill
        /// only `full[prefixTokens...]` on top of it.
        case reuse(prefixTokens: Int)
        /// Prefill the whole render on a fresh cache (correct, unoptimised).
        case fresh
    }

    /// How to build a persona seed on a FRESH cache.
    enum SeedBuild: Equatable {
        /// Run a 1-token generation over the prefix, then trim the sampled
        /// position back off. Kept for linear caches because it runs upstream's
        /// own TokenIterator — including its KV-cache plan (Lil's 8-bit
        /// quantization at quantizedKVStart 0), so the seed is stored in the
        /// form the turn's decode will use.
        case sampleAndTrim
        /// Forward-only prefill that never samples, so the cache holds exactly
        /// the prefix and nothing needs trimming. The only exact build for a
        /// recurrent layer (LFM2's and Qwen3.5's MambaCache are never trimmable).
        /// It runs NO KVCachePlan, so a quantizing family's seed is stored
        /// full-precision — and that is fine: the turn's TokenIterator applies
        /// its plan after `prepare` (legacy kvBits resolves `.allowPartial`, so
        /// a mixed cache validates), and the suffix attending a full-precision
        /// prefix is exactly what the 2026-10-07 seeded-prefill probe measured.
        case exactPrefill
    }

    /// `freshLayersTrimmable`: `isTrimmable` of each layer of a fresh
    /// `newCache` — false only on recurrent/state caches, which can never be
    /// trimmed back after a sampled token.
    static func seedBuild(freshLayersTrimmable: [Bool]) -> SeedBuild {
        !freshLayersTrimmable.isEmpty && freshLayersTrimmable.allSatisfy { $0 } ? .sampleAndTrim : .exactPrefill
    }

    /// `seed`: the exact token ids the persona cache holds. `full`: the token
    /// ids of the whole `[system, user]` render for this turn.
    ///
    /// `seedTrimmed`: whether the seed cache really holds EXACTLY `seed.count`
    /// positions — the seed's `exact`, vouched by its builder: trimmed back on a
    /// linear cache, or prefilled without a sampled token (`SeedBuild`). A
    /// persona that wrapped a sliding window keeps its sampled position
    /// (trimming a wrapped RotatingKVCache underflows its rotation pointer), so
    /// its cache is one token longer than its ids say. Appending to it would be
    /// silently misaligned KV — the very class of bug this seam exists to close
    /// — so a non-exact seed is never reused.
    static func plan(seed: [Int], full: [Int], seedTrimmed: Bool) -> Plan {
        guard seedTrimmed, !seed.isEmpty, full.count > seed.count, full.starts(with: seed) else {
            return .fresh
        }
        return .reuse(prefixTokens: seed.count)
    }
}
