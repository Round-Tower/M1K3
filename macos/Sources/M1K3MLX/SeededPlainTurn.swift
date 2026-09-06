//
//  SeededPlainTurn.swift
//  M1K3MLX
//
//  Pure decision for a plain-chat turn on a seeded persona prefix — see
//  SeededPlainTurnTests for the bug it exists to close (the double-BOS render
//  that erased pocket's persona on every plain turn).
//
//  Deliberately narrower than CrossTurnCacheReuse: a persona seed is stored
//  trimmed to EXACTLY its token ids, so the only reuse worth having is the whole
//  seed — a partial match means the render and the seed disagree about the
//  persona, and appending to that cache would be positionally wrong KV. Never
//  trims, so a seed that overran a sliding window (untrimmable) still works the
//  way it always did: append the suffix, no rotation-pointer surgery.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-06, Confidence 0.9. Prior: Unknown
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
    static func plan(seed: [Int], full: [Int]) -> Plan {
        guard !seed.isEmpty, full.count > seed.count, full.starts(with: seed) else {
            return .fresh
        }
        return .reuse(prefixTokens: seed.count)
    }
}
