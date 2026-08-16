//
//  PrewarmSlotTests.swift
//  M1K3InferenceTests
//
//  The single-slot hand-off behind AFM prewarm: something expensive is built
//  ahead of need (a prewarmed LanguageModelSession), keyed by the exact
//  instructions that built it, and consumed AT MOST ONCE by the next turn —
//  a session whose instructions have since changed is worthless and must be
//  dropped, never served. Pure and generic so the policy is pinned without
//  touching FoundationModels.
//
//  Signed: Kev + claude-fable-5, 2026-08-16, Confidence 0.9 (pure, exhaustive;
//  the provider wiring is verify-by-launch via the `prewarmed=` log field).
//  Prior: Unknown.
//

import M1K3Inference
import Testing

struct PrewarmSlotTests {
    @Test("a stored value is taken exactly once when the key matches")
    func consumeOnce() {
        let slot = PrewarmSlot<String>()
        slot.store("session", key: "persona-v1")
        #expect(slot.isArmed)
        #expect(slot.take(matching: "persona-v1") == "session")
        // Consumed — a second take gets nothing.
        #expect(slot.take(matching: "persona-v1") == nil)
        #expect(!slot.isArmed)
    }

    @Test("a key mismatch drops the stale value instead of serving it")
    func mismatchDrops() {
        // The instructions changed since prewarm (the persona's about-user
        // block moved under it) — serving the old session would answer with a
        // stale persona. Drop it AND clear the slot: it can never match again.
        let slot = PrewarmSlot<String>()
        slot.store("stale", key: "persona-v1")
        #expect(slot.take(matching: "persona-v2") == nil)
        #expect(!slot.isArmed)
        #expect(slot.take(matching: "persona-v1") == nil)
    }

    @Test("an empty slot takes nothing")
    func emptyTake() {
        let slot = PrewarmSlot<String>()
        #expect(!slot.isArmed)
        #expect(slot.take(matching: "anything") == nil)
    }

    @Test("a re-store replaces the previous value, old key forgotten")
    func restoreReplaces() {
        let slot = PrewarmSlot<String>()
        slot.store("old", key: "k")
        slot.store("new", key: "k")
        #expect(slot.take(matching: "k") == "new")

        slot.store("v1", key: "a")
        slot.store("v2", key: "b")
        #expect(slot.take(matching: "a") == nil)
        #expect(!slot.isArmed)
    }
}
