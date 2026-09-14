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
//  Review: Kev + claude-opus-5, 2026-09-14, Confidence 0.9 — `take(matching:accepting:)`:
//  a caller the value wasn't built for leaves it in the slot. Found live: Mini's
//  conversation titler ran between turn 1 and turn 2 and took the session prewarmed
//  for turn 2, so turn 2 always ran cold.
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

    @Test("a caller the value wasn't built for leaves it for the one it was")
    func declinedTakeLeavesTheValue() {
        let slot = PrewarmSlot<String>()
        slot.store("session for the chat turn", key: "persona")
        // The titler's prompt doesn't begin with the chat head — it passes.
        #expect(slot.take(matching: "persona", accepting: { _ in false }) == nil)
        #expect(slot.isArmed)
        // The chat turn it was built for still gets it, once.
        #expect(slot.take(matching: "persona", accepting: { _ in true }) == "session for the chat turn")
        #expect(!slot.isArmed)
    }

    @Test("a stale key still drops the value, whoever is asking")
    func staleKeyDropsEvenWhenDeclined() {
        let slot = PrewarmSlot<String>()
        slot.store("stale", key: "persona-v1")
        #expect(slot.take(matching: "persona-v2", accepting: { _ in false }) == nil)
        #expect(!slot.isArmed)
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
