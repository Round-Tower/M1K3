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
//  Review: Kev + claude-fable-5.1, 2026-10-25 — the slot learns EXACT checkpoints. The live-path tail
//  above was dead on every shipping tier: Lil's recurrent layers and Big's wrapped window put the tool
//  turn in checkpoint mode, where no live cache survives to adopt, so reuse sat flat at the persona and
//  every message re-prefilled the conversation (chat-curves 10-25: Lil 2–3 s, Big 6–12 s a message).
//  `adoptCheckpoint` stores a cache prefilled WITHOUT sampling at the cut `ExactPrefixReuse.tailCut`
//  names, with the model state that belongs to it, vouched `exact`; `recordRender` keeps the previous
//  first render the next turn cuts against. Capped by MEASURED bytes (`maxCheckpointBytes`), since
//  tokens mislead across tiers: Lil (Qwen3.5-4B: 8 full-attention layers × 4 KV heads × 256 × 2 × fp16)
//  holds ~32 KB/token plus a constant recurrent state; Big (gemma-4-12B) carries a ~335 MiB constant
//  sliding-window state plus ~16 KB/token in its global layers. 512 MiB admits both on a desktop.
//  Confidence 0.8 (store decisions pinned; the per-message win and the RAM are the chat-curve's).
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
    /// The exact-checkpoint path's bound is MEASURED bytes (`innerState().nbytes` of the cut cache),
    /// not tokens: see the 2026-10-25 review above for the per-tier arithmetic. 512 MiB.
    static let maxCheckpointBytes = 512 << 20
    /// The checkpoint path's token belt — bytes bind first; this only bounds the ids array and a
    /// tier whose per-token cost is far below the arithmetic above.
    static let maxCheckpointTokens = 8000

    enum AdoptOutcome: Equatable {
        case stored
        /// Refused — and the PREVIOUS tail, if any, deliberately survives: an
        /// older self-consistent (cache, ids) pair is still a strict prefix of
        /// the growing conversation, so a smaller win beats no win.
        case overCap
        /// Refused on measured bytes (checkpoint path); the previous tail survives the same way.
        case overBytes
    }

    fileprivate struct Entry {
        let key: PersonaCacheKey
        let cache: [KVCache]
        let tokenIDs: [Int]
        /// Vouched exact (prefilled without a sampled token) — the checkpoint path's tails only.
        let exact: Bool
        let state: LMOutput.State?
    }

    private let lock = NSLock()
    private let cap: Int
    private let checkpointCap: Int
    private let byteCap: Int
    private var entry: Entry?
    /// The previous turn's first render, per key — what the next turn's first send cuts against.
    private var render: (key: PersonaCacheKey, ids: [Int])?

    init(
        cap: Int = ConversationTailCache.maxSeedTokens,
        checkpointCap: Int = ConversationTailCache.maxCheckpointTokens,
        byteCap: Int = ConversationTailCache.maxCheckpointBytes
    ) {
        self.cap = cap
        self.checkpointCap = checkpointCap
        self.byteCap = byteCap
    }

    /// Take ownership of a finishing session's cache. The caller must not
    /// touch `cache` afterwards — these are the live arrays, not copies.
    @discardableResult
    func adopt(_ cache: [KVCache], tokenIDs: [Int], for key: PersonaCacheKey) -> AdoptOutcome {
        guard tokenIDs.count <= cap else { return .overCap }
        lock.lock()
        defer { lock.unlock() }
        entry = Entry(key: key, cache: cache, tokenIDs: tokenIDs, exact: false, state: nil)
        return .stored
    }

    /// Take ownership of an exact checkpoint: a cache holding exactly `tokenIDs`, prefilled without
    /// sampling, with the state its prefill handed back. `bytes` is the caller's measurement of the
    /// arrays it hands over (`innerState().nbytes`); over `byteCap` the previous tail survives, same
    /// as the token cap. `cache` is an autoclosure evaluated only once the caps pass, so the caller's
    /// copy of a refused checkpoint is never made. The caller must not touch the arrays afterwards.
    @discardableResult
    func adoptCheckpoint(
        _ cache: @autoclosure () -> [KVCache], tokenIDs: [Int], state: LMOutput.State?, bytes: Int,
        for key: PersonaCacheKey
    ) -> AdoptOutcome {
        guard tokenIDs.count <= checkpointCap else { return .overCap }
        guard bytes <= byteCap else { return .overBytes }
        let arrays = cache()
        lock.lock()
        defer { lock.unlock() }
        entry = Entry(key: key, cache: arrays, tokenIDs: tokenIDs, exact: true, state: state)
        return .stored
    }

    /// Remember this turn's first render under `key`; the next turn's first send cuts its tail at the
    /// common prefix of the two (`ExactPrefixReuse.tailCut`). Ids only — cheap to keep.
    func recordRender(_ ids: [Int], for key: PersonaCacheKey) {
        lock.lock()
        defer { lock.unlock() }
        render = (key, ids)
    }

    /// The render `recordRender` kept for `key`, nil for any other key.
    func previousRender(for key: PersonaCacheKey) -> [Int]? {
        lock.lock()
        defer { lock.unlock() }
        guard let render, render.key == key else { return nil }
        return render.ids
    }

    /// A deep, independently-mutable copy of the retained LIVE-PATH tail — nil on any
    /// key mismatch (persona edit, palette change, model swap: all fail soft
    /// to the persona-prefix fallback), and nil for an exact checkpoint (those go
    /// out through `exactTail`, which copies only on use). Copy happens OUTSIDE the lock for the
    /// same two reasons as PersonaPrefixCache.snapshot: ARC keeps the source
    /// arrays alive through a concurrent adopt/invalidate, and retained
    /// arrays are never mutated after adopt (the session that owned them has
    /// finished).
    func snapshot(for requested: PersonaCacheKey) -> PersonaPrefixSnapshot? {
        guard let held = entry(for: requested), !held.exact else { return nil }
        // Not vouched exact: a finished session's cache is only ever consumed by
        // the tool path, which gates reuse on its own trim check (it trims back
        // to the common prefix), never by the append-only seeded plain turn.
        return PersonaPrefixSnapshot(cache: held.cache.map { $0.copy() }, tokenIDs: held.tokenIDs, exact: false)
    }

    /// A handle on the retained exact checkpoint, NOT a copy: the ids and state are what the next
    /// turn's ledger plans with; `copyCache()` is paid only if the plan picks it (a tail of up to
    /// `maxCheckpointBytes`, copied every turn whether used or not, was the review's catch on 10-25).
    /// ARC keeps the source arrays alive past a concurrent adopt or invalidate, and they are never
    /// mutated after adopt, so the copy is sound whenever it is taken.
    struct ExactTail {
        let tokenIDs: [Int]
        let state: LMOutput.State?
        private let source: [KVCache]

        fileprivate init(_ entry: Entry) {
            tokenIDs = entry.tokenIDs
            state = entry.state
            source = entry.cache
        }

        /// A deep, independently-mutable copy of the checkpoint's cache.
        func copyCache() -> [KVCache] {
            source.map { $0.copy() }
        }
    }

    /// The exact checkpoint retained for `key`, nil for a live-path tail or any other key.
    func exactTail(for requested: PersonaCacheKey) -> ExactTail? {
        guard let held = entry(for: requested), held.exact else { return nil }
        return ExactTail(held)
    }

    private func entry(for requested: PersonaCacheKey) -> Entry? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, entry.key == requested else { return nil }
        return entry
    }

    /// Drop the slot and the recorded render (brain swap / eager memory release).
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        entry = nil
        render = nil
    }
}
