//
//  PersonaPrefixCache.swift
//  M1K3MLX
//
//  The enabler for richer prompting: M1K3's persona (and the tool specs —
//  Qwen renders TOOLS inside the SYSTEM block) is prefilled into a KV cache
//  ONCE per (model × tools × persona), and every turn starts from a deep COPY
//  of that prefix instead of re-prefilling it. A longer persona stops being a
//  per-turn TTFT tax — it costs once per launch.
//
//  The retained cache is never handed out: `snapshot` returns
//  `copy()`-deep copies (upstream KVCache.copy() materialises new arrays), so
//  turns mutate their own offsets independently. In-memory only — on-disk
//  persistence (savePromptCache) is a follow-up with model-versioning needs.
//
//  Signed: Kev + claude-fable-5, 2026-06-10, Confidence 0.8 (key/store logic
//  tested; the prefill render + trim normalisation is verify-at-⌘R like all
//  MLX generation). Prior: Unknown
//
//  Review: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.75 — capacity 2 → 3: the live keys have
//  been three since #116 (headless + interactive palettes, plus the plain no-tools prefix a
//  foreground synthesis fallback seeds from). Sized by arithmetic (~90 MB on Lil); RAM snapshot owed.
//  Desktop only after the #415 review — mobile keeps two under its jetsam ceiling.
//  Review: Kev + claude-opus-5-5, 2026-09-26 (2), Confidence 0.85 — the RAM snapshot is paid: measured
//  at launch on Lil (1,747 / 2,426 / 3,349-token prefixes, 3.17 GB RSS); the capacity comment carries it.
//  Review: Kev + claude-opus-5-5, 2026-10-07, Confidence 0.85 — a slot carries the prefix's
//  `LMOutput.State` beside its cache: Qwen3.5 on MLXVLM can't extend a seed without its rope delta.
//

import Foundation
import MLXLMCommon

/// Identity of one rendered system-block prefix.
struct PersonaCacheKey: Hashable {
    let modelID: String
    let toolsFingerprint: String
    let personaText: String

    init(modelID: String, toolNames: [String], personaText: String) {
        self.modelID = modelID
        toolsFingerprint = toolNames.sorted().joined(separator: ",")
        self.personaText = personaText
    }
}

/// One cached prefix + its token ids (for prefill-savings logging AND
/// cross-turn reuse: a seeded MLXToolTurnSession needs the exact token
/// sequence the cache holds to compute a valid common-prefix reuse).
struct PersonaPrefixSnapshot {
    let cache: [KVCache]
    let tokenIDs: [Int]
    /// Whether `cache` holds EXACTLY `tokenIDs.count` positions — the builder
    /// vouches for it (trimmed back on a linear cache, or prefilled without a
    /// sampled token). Appending to a non-exact seed is misaligned KV.
    let exact: Bool
    /// The model state the prefix's prefill handed back — MLXVLM's Qwen3.5 keeps
    /// its rope delta here and THROWS `missingState` continuing a warm cache
    /// without it (SeededPrefillProbe, 2026-10-07). Nil for families that carry
    /// none. An immutable value: shared across copies, never written into.
    var state: LMOutput.State?
    var tokenCount: Int {
        tokenIDs.count
    }
}

/// `@unchecked Sendable`: a single NSLock guards the slot; the retained
/// cache is only ever read to produce copies. NSLock, not Mutex, on purpose:
/// `KVCache` is non-Sendable, and extracting it from a `Mutex` trips region
/// isolation ("inout sending") — the same wall MLXToolTurnSession documents.
///
/// Invalidation is IMPLICIT: the key fingerprints (model × tools × persona
/// text), and the persona text embeds the user profile — a profile edit
/// changes the key, misses the slot, and the prefix rebuilds on next use.
/// `invalidate()` exists only to reclaim memory eagerly.
final class PersonaPrefixCache: @unchecked Sendable {
    /// One entry per rendered prefix. MRU-first.
    private struct Entry {
        let key: PersonaCacheKey
        let cache: [KVCache]
        let tokenIDs: [Int]
        let exact: Bool
        let state: LMOutput.State?
    }

    /// THREE, one per prefix the provider renders in normal use: the headless
    /// tool palette (MCP / Shortcuts), the interactive one, and the plain
    /// no-tools prefix `generate`/`generateStreaming` seed from — which a
    /// foreground tool turn's synthesis fallback builds. A single slot made two
    /// of them evict each other on every alternation — measured live on
    /// 2026-08-09 as a 16-19 SECOND re-prefill on the next chat turn, with
    /// decode healthy at 30 tok/s the whole time. Two slots held until #116
    /// (2026-08-12) warmed a second palette and quietly made the live keys
    /// three.
    ///
    /// Kept deliberately small: each entry retains Metal-backed KV arrays for
    /// a ~2-3k-token prefix across every layer, and `MLXMemoryBudget`'s ceiling
    /// is back-pressure, not a cap (the 2026-07-14 lesson). Measured on Lil at
    /// launch, 2026-09-26 (M1 Max, #415): plain 1,747 / headless 2,426 /
    /// interactive 3,349 tokens — at ~78 KB/token (36 layers × 8 KV heads × 128
    /// dims, 8-bit KV) the third slot is ~136 MB, all three ~590 MB, and the
    /// process sat at 3.17 GB RSS with Lil resident. Big stores none (its
    /// persona overruns the 1024-token sliding window, see renderPersonaPrefix).
    ///
    /// DESKTOP only (#415 review): iOS/visionOS live under a jetsam limit where
    /// the failure is a kill, not a slowdown, so mobile keeps the two slots it
    /// had until an on-device RAM snapshot says a third fits.
    static func capacity(for profile: MLXMemoryBudget.DeviceProfile) -> Int {
        profile == .desktop ? 3 : 2
    }

    /// This build's platform capacity — the same `#if` split MLXMemoryBudget.settle uses.
    static var defaultCapacity: Int {
        #if os(iOS) || os(visionOS)
            capacity(for: .mobile)
        #else
            capacity(for: .desktop)
        #endif
    }

    private let lock = NSLock()
    private let capacity: Int
    private var entries: [Entry] = []

    init(capacity: Int = PersonaPrefixCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    /// A deep, independently-mutable copy of the cached prefix — or nil when
    /// no entry matches the requested render.
    func snapshot(for requested: PersonaCacheKey) -> PersonaPrefixSnapshot? {
        // Grab the refs under the lock, copy OUTSIDE it: KVCache.copy()
        // materialises new Metal-backed arrays per layer (a pure read of the
        // source), and holding the lock for that would block store/invalidate
        // (brain-switch path) for the whole copy. Lock-free safety rests on
        // TWO guarantees: ARC — `held` keeps the snapshotted arrays alive even
        // if a concurrent store/invalidate drops the entry mid-copy — and
        // immutability: retained arrays are never mutated after store.
        lock.lock()
        let held: Entry? = {
            guard let index = entries.firstIndex(where: { $0.key == requested }) else { return nil }
            // A HIT is a use: move to front so the eviction candidate is always
            // the genuinely coldest entry, not merely the oldest stored.
            let entry = entries.remove(at: index)
            entries.insert(entry, at: 0)
            return entry
        }()
        lock.unlock()
        guard let held else { return nil }
        return PersonaPrefixSnapshot(
            cache: held.cache.map { $0.copy() }, tokenIDs: held.tokenIDs, exact: held.exact, state: held.state
        )
    }

    /// Whether a prefix for `requested` is held — WITHOUT copying it.
    ///
    /// For the caller that only needs to know whether someone else's build has
    /// already landed (the coalescer's re-check). `snapshot(for:)` would answer
    /// the same question by deep-copying every layer's KV arrays and discarding
    /// them, which is the exact waste this cache exists to avoid.
    ///
    /// Deliberately NOT a use: a peek must not move the entry to front, or a
    /// caller that merely asked would outrank one that actually generated, and
    /// the eviction candidate would stop being the coldest entry.
    func contains(_ requested: PersonaCacheKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.contains { $0.key == requested }
    }

    /// `exact` defaults to false — the safe direction: a seed nobody vouched for
    /// is never appended to, only re-prefilled.
    func store(
        _ cache: [KVCache],
        tokenIDs: [Int],
        exact: Bool = false,
        state: LMOutput.State? = nil,
        for newKey: PersonaCacheKey
    ) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.key == newKey }
        entries.insert(Entry(key: newKey, cache: cache, tokenIDs: tokenIDs, exact: exact, state: state), at: 0)
        // Dropping the Entry releases its KVCache refs — the Metal arrays go
        // with them once no in-flight snapshot still holds a copy.
        if entries.count > capacity { entries.removeLast(entries.count - capacity) }
    }

    /// Drop every slot (persona text changed — e.g. a profile update — or the
    /// caller wants the memory back).
    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
    }
}
