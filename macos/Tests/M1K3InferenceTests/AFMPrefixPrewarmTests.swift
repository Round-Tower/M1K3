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
//

import Foundation
import M1K3Inference
import Testing

struct AFMPrefixPrewarmTests {
    private static func defaults(_ value: Any?) -> UserDefaults {
        let name = "AFMPrefixPrewarmTests.\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        store.removePersistentDomain(forName: name)
        if let value { store.set(value, forKey: AFMPrefixPrewarm.defaultsKey) }
        return store
    }

    @Test("on unless switched off — absent means on")
    func onByDefault() {
        #expect(AFMPrefixPrewarm.isEnabled(in: Self.defaults(nil)))
        #expect(AFMPrefixPrewarm.isEnabled(in: Self.defaults(true)))
        #expect(!AFMPrefixPrewarm.isEnabled(in: Self.defaults(false)))
    }

    @Test("a launch argument's string reads the way the words say (-afm.prefixPrewarm NO)")
    func argumentDomainStrings() {
        #expect(!AFMPrefixPrewarm.isEnabled(in: Self.defaults("NO")))
        #expect(!AFMPrefixPrewarm.isEnabled(in: Self.defaults("false")))
        #expect(!AFMPrefixPrewarm.isEnabled(in: Self.defaults("0")))
        #expect(AFMPrefixPrewarm.isEnabled(in: Self.defaults("YES")))
        #expect(AFMPrefixPrewarm.isEnabled(in: Self.defaults("1")))
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
