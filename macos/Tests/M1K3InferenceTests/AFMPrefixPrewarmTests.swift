//
//  AFMPrefixPrewarmTests.swift
//  M1K3InferenceTests
//
//  Mini's prompt-prefix prewarm (2026-09-14): the switch that turns it off (one
//  reader, argument-domain strings included — the #324 lesson), which calls a
//  prefix-warm session may serve, and the per-turn classification the `afm turn`
//  log line carries.
//
//  Signed: Kev + claude-opus-5, 2026-09-14, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-09-27 — `foreignInstructionsSkipTheSlot` (PR #424 review).
//  Review: Kev + claude-opus-5-5, 2026-10-19 — each domain is removed when its read returns (house `defer`): they
//  were cleared before use and never after, ~1,225 plists left.
//

import Foundation
import M1K3Inference
import Testing

struct AFMPrefixPrewarmTests {
    /// PR #424 review: the titler moved to neutral instructions on the chat's own AFM
    /// instance, and PrewarmSlot drops a slot whose key doesn't match — so a title
    /// written after a turn evicted the next turn's prewarm (the 16-19 s cold start).
    /// A call on foreign instructions never touches the slot; MLX's persona cache has
    /// the same rule (`InferenceIntent.instructions == nil`).
    @Test("only the standing persona consults the prewarm slot; a foreign-instructions call leaves it armed")
    func foreignInstructionsSkipTheSlot() {
        #expect(AFMPrefixPrewarm.consultsSlot(override: nil, standing: "persona"))
        #expect(AFMPrefixPrewarm.consultsSlot(override: "persona", standing: "persona"))
        #expect(!AFMPrefixPrewarm.consultsSlot(override: "You write short titles…", standing: "persona"))
    }

    /// `isEnabled` over a private domain holding `value`, removed when it returns (the house `defer`; it was cleared
    /// before use and never after).
    private static func enabled(_ value: Any?) -> Bool {
        let name = "AFMPrefixPrewarmTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer { store.removePersistentDomain(forName: name) }
        if let value { store.set(value, forKey: AFMPrefixPrewarm.defaultsKey) }
        return AFMPrefixPrewarm.isEnabled(in: store)
    }

    @Test("on unless switched off — absent means on")
    func onByDefault() {
        #expect(Self.enabled(nil))
        #expect(Self.enabled(true))
        #expect(!Self.enabled(false))
    }

    @Test("a launch argument's string reads the way the words say (-afm.prefixPrewarm NO)")
    func argumentDomainStrings() {
        #expect(!Self.enabled("NO"))
        #expect(!Self.enabled("false"))
        #expect(!Self.enabled("0"))
        #expect(Self.enabled("YES"))
        #expect(Self.enabled("1"))
    }

    @Test("a prefix-warm session serves only a prompt that begins with its prefix")
    func acceptance() {
        #expect(AFMPrefixPrewarm.accepts(prefix: "HEAD", prompt: "HEAD tail"))
        #expect(!AFMPrefixPrewarm.accepts(prefix: "HEAD", prompt: "Title this chat: HEAD"))
        // Warm on the instructions alone: any call may have it, as before.
        #expect(AFMPrefixPrewarm.accepts(prefix: nil, prompt: "anything"))
    }

    @Test("a taken session is warm on its prefix or on the instructions alone")
    func takenWarmth() {
        #expect(AFMPrefixPrewarm.Warmth.taken(prefix: "HEAD") == .prefixHit)
        #expect(AFMPrefixPrewarm.Warmth.taken(prefix: nil) == .instructions)
    }

    @Test("the log words are stable — traces are grepped for them")
    func logWords() {
        #expect(AFMPrefixPrewarm.Warmth.cold.rawValue == "cold")
        #expect(AFMPrefixPrewarm.Warmth.instructions.rawValue == "instructions")
        #expect(AFMPrefixPrewarm.Warmth.prefixHit.rawValue == "prefix-hit")
        #expect(AFMPrefixPrewarm.Warmth.held.rawValue == "held")
    }
}
