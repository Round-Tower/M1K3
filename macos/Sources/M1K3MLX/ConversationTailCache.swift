//
//  ConversationTailCache.swift
//  M1K3MLX
//
//  The cross-TURN half of what PersonaPrefixCache does cross-LAUNCH: the last
//  turn's end-of-turn KV cache, retained so the next turn of the same
//  conversation seeds from it instead of from the bare persona.
//
//  Why this exists (measured 2026-08-13): three consecutive live turns each
//  reused exactly 1786 tokens — the persona, never more — because every
//  MLXToolTurnSession is seeded from the persona prefix alone, so the context
//  line, history replay and prior grounding re-prefill from scratch at a
//  measured 1.71 ms/token on Lil. The obvious fix (one session per
//  conversation, append-only transcript) was challenger-killed the same day:
//  gemma-4's sliding window vetoes reuse outright, and a live session's
//  transcript diverges from the displayed one on every tool-using turn. This
//  is the endorsed shape instead: change the SEED, not the session lifetime.
//
//  Fail-soft by arithmetic, which is why there is no conversation id in the
//  key: the tail's token ids always begin with the persona block (same key ⇒
//  same persona+tools render), so when the next render diverges early — a
//  conversation switch, a slid history window, an edited message — the
//  common-prefix computation in CrossTurnCacheReuse simply collapses reuse
//  back to persona-level and trims the copy. A miss is today's behaviour;
//  nothing corrupts. gemma-4 never stores a wrapped tail because the session
//  nils its cache when any layer stops being trimmable — the tier gate falls
//  out of the existing wrap check rather than a model-id list.
//
//  Ownership contract: `adopt` takes the LIVE arrays from a session that is
//  finishing (no copy — the session must not touch them again); `snapshot`
//  hands out deep copies, same as PersonaPrefixCache. Single slot on purpose:
//  one conversation is live at a time, and a second retained tail would double
//  the worst-case ~300 MiB of pinned Metal arrays.
//
//  Signed: Kev + claude-fable-5, 2026-08-13, Confidence 0.85 (store decisions
//  test-pinned; what the retained arrays buy on a real turn is verify-at-⌘R —
//  the `seed=conversation` reuse log line is the acceptance instrument).
//  Prior: Unknown.
//

import Foundation
import MLXLMCommon

/// Where a tool-turn session's KV seed came from — printed in the reuse log so
/// a working conversation tail is distinguishable from a warm persona prefix
/// (an instrument that can't tell those apart can't verify this feature).
enum PrefixSeedSource: String {
    case none, persona, conversation
}

final class ConversationTailCache: @unchecked Sendable {
    /// Retention ceiling in tokens. ~78 KB/token on Lil (36 layers × 8 KV
    /// heads × 128 head-dim × 2, kvBits 8) → 4000 ≈ 300 MiB pinned worst-case.
    /// `MLXMemoryBudget`'s limit is back-pressure, not a cap, and
    /// `clearCache()` cannot reclaim retained arrays — so this constant is the
    /// only thing bounding the slot. Raise it only with a measured RAM
    /// snapshot in hand (the PersonaPrefixCache rule).
    static let maxSeedTokens = 4000

    enum AdoptOutcome: Equatable {
        case stored
        /// Refused — and the PREVIOUS tail, if any, deliberately survives: an
        /// older self-consistent (cache, ids) pair is still a strict prefix of
        /// the growing conversation, so a smaller win beats no win.
        case overCap
    }

    private let lock = NSLock()
    private let cap: Int
    private var entry: (key: PersonaCacheKey, cache: [KVCache], tokenIDs: [Int])?

    init(cap: Int = ConversationTailCache.maxSeedTokens) {
        self.cap = cap
    }

    /// Take ownership of a finishing session's cache. The caller must not
    /// touch `cache` afterwards — these are the live arrays, not copies.
    @discardableResult
    func adopt(_ cache: [KVCache], tokenIDs: [Int], for key: PersonaCacheKey) -> AdoptOutcome {
        guard tokenIDs.count <= cap else { return .overCap }
        lock.lock()
        defer { lock.unlock() }
        entry = (key, cache, tokenIDs)
        return .stored
    }

    /// A deep, independently-mutable copy of the retained tail — nil on any
    /// key mismatch (persona edit, palette change, model swap: all fail soft
    /// to the persona-prefix fallback). Copy happens OUTSIDE the lock for the
    /// same two reasons as PersonaPrefixCache.snapshot: ARC keeps the source
    /// arrays alive through a concurrent adopt/invalidate, and retained
    /// arrays are never mutated after adopt (the session that owned them has
    /// finished).
    func snapshot(for requested: PersonaCacheKey) -> PersonaPrefixSnapshot? {
        lock.lock()
        let held: (cache: [KVCache], tokens: [Int])? = {
            guard let entry, entry.key == requested else { return nil }
            return (entry.cache, entry.tokenIDs)
        }()
        lock.unlock()
        guard let held else { return nil }
        return PersonaPrefixSnapshot(cache: held.cache.map { $0.copy() }, tokenIDs: held.tokens)
    }

    /// Drop the slot (brain swap / eager memory release).
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        entry = nil
    }
}
