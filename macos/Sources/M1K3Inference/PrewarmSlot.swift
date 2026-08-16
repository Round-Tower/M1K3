//
//  PrewarmSlot.swift
//  M1K3Inference
//
//  Single-slot hand-off for something expensive built ahead of need — the
//  prewarmed AFM LanguageModelSession. Keyed by the EXACT instructions text
//  that built the value: a session whose instructions have since changed (the
//  persona's about-user block moved under it) would answer with a stale
//  persona, so a mismatched take drops the value rather than serving it, and
//  every take consumes — a session is single-use by construction.
//
//  Lock-guarded rather than an actor so `take` stays synchronous on the
//  generate hot path (an await here would add a suspension to every turn for
//  a lookup that is nanoseconds).
//
//  Signed: Kev + claude-fable-5, 2026-08-16, Confidence 0.9 (pure, pinned by
//  PrewarmSlotTests; the AFM wiring is verify-by-launch via the `prewarmed=`
//  log field). Prior: Unknown.
//

import Foundation

/// A one-value, consume-once box keyed by the string that built its content.
/// `@unchecked Sendable`: all state is guarded by the lock; `Value` crossing
/// domains is the caller's contract (LanguageModelSession is `@unchecked
/// Sendable` in the SDK, and a taken value has exactly one consumer).
public final class PrewarmSlot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (key: String, value: Value)?

    public init() {}

    /// Arm the slot, replacing whatever was there.
    public func store(_ value: Value, key: String) {
        lock.lock()
        defer { lock.unlock() }
        stored = (key, value)
    }

    /// Take the value if the key still matches. ALWAYS empties the slot — a
    /// matched value is consumed, a mismatched one is stale and dropped.
    public func take(matching key: String) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        guard let stored else { return nil }
        self.stored = nil
        return stored.key == key ? stored.value : nil
    }

    /// Whether a value is waiting (diagnostics/tests only — armed now can be
    /// gone by the time you act on it).
    public var isArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored != nil
    }
}
