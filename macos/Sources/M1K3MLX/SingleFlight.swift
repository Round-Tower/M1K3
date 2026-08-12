//
//  SingleFlight.swift
//  M1K3MLX
//
//  Coalesce concurrent work on the same key so it runs once.
//
//  Measured on the live app, 2026-08-09. The persona prefix cache was doing
//  its job and the prefix was still being rebuilt three times in 26 seconds —
//  same key, same cache instance, logged and confirmed. The misses were not
//  evictions, they were a RACE: several callers ask for the prefix at once,
//  all miss because nobody has stored yet, then serialise on the
//  ModelContainer actor and each pays a full ~13-second prefill. The last one
//  to finish wins a slot nobody else needed by then.
//
//  A bigger cache cannot fix this — every entrant missed before the first
//  store existed. Capacity is about what survives; this is about what starts.
//
//  Not `M1K3Inference.SingleFlightLoader` (used by this same provider for the
//  model load) and not an extension of it, though they rhyme. That one is
//  single-key and permanently caches its successful value — which is right for
//  a model you load once, and wrong here: a coalescer that also cached would
//  hold prefixes the two-slot LRU had deliberately evicted, and the two would
//  disagree about what's live. Caching is `PersonaPrefixCache`'s job. This type
//  only decides what STARTS.
//
//  Signed: Kev + claude-opus-5, 2026-08-09, Confidence 0.9 (the stampede was
//  read off the unified log with a key fingerprint added to prove same-key,
//  same-instance, rather than inferred; the coalescer itself is pinned by a
//  concurrency test that fails without it). Prior: Unknown
//

import Foundation

/// Runs at most one operation per key at a time; concurrent callers for the
/// same key await the SAME operation instead of starting their own.
actor SingleFlight<Key: Hashable & Sendable, Value: Sendable> {
    private var inFlight: [Key: Task<Value, Error>] = [:]

    /// Await the in-flight operation for `key`, or start it.
    ///
    /// A failure is NOT cached: the entry is cleared when the task completes
    /// either way, so the next caller retries rather than inheriting a stale
    /// error for the life of the process.
    func run(_ key: Key, _ body: @Sendable @escaping () async throws -> Value) async throws -> Value {
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task { try await body() }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// True while `key` has work in flight — for tests and diagnostics.
    var busyKeys: Set<Key> {
        Set(inFlight.keys)
    }
}
