//
//  AFMPrefixPrewarmTests.swift
//  M1K3InferenceTests
//
//  Mini's prompt-prefix prewarm (2026-09-14): the switch that turns it off (one
//  reader, argument-domain strings included — the #324 lesson) and the
//  per-turn classification the `afm turn` log line carries, so a live trace
//  says whether the warmed prefix was the one the turn actually sent.
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

    @Test("a turn is cold, warm on instructions only, or warm on a prefix it did or didn't send")
    func classification() {
        #expect(AFMPrefixPrewarm.Warmth.of(prewarmed: false, prefix: "HEAD", prompt: "HEAD tail") == .cold)
        #expect(AFMPrefixPrewarm.Warmth.of(prewarmed: true, prefix: nil, prompt: "HEAD tail") == .instructions)
        #expect(AFMPrefixPrewarm.Warmth.of(prewarmed: true, prefix: "HEAD", prompt: "HEAD tail") == .prefixHit)
        #expect(AFMPrefixPrewarm.Warmth.of(prewarmed: true, prefix: "HEAD", prompt: "OTHER tail") == .prefixMiss)
        #expect(AFMPrefixPrewarm.Warmth.of(prewarmed: true, prefix: "", prompt: "tail") == .instructions)
    }

    @Test("the log words are stable — traces are grepped for them")
    func logWords() {
        #expect(AFMPrefixPrewarm.Warmth.cold.rawValue == "cold")
        #expect(AFMPrefixPrewarm.Warmth.instructions.rawValue == "instructions")
        #expect(AFMPrefixPrewarm.Warmth.prefixHit.rawValue == "prefix-hit")
        #expect(AFMPrefixPrewarm.Warmth.prefixMiss.rawValue == "prefix-miss")
    }
}
