//
//  SpokenNameTests.swift
//  M1K3VoiceTests
//
//  M1K3 is leetspeak for MIKE, and every TTS engine we have gets it wrong: the
//  Kokoro path spells it out character by character (and silently drops the "M",
//  which is what Kev heard), while AVSpeech reads it as an alphanumeric jumble. A
//  companion that can't say its own name is a bad first impression, and the fix
//  belongs at the TEXT level so it lands on every engine and both platforms at
//  once — not in one engine's dictionary.
//
//  Deliberately narrow: only M1K3's own name, only as a whole word. Speech polish
//  is applied to every spoken answer, so anything looser here would start rewriting
//  the user's content.
//
//  Signed: Kev + claude-opus-5, 2026-08-11, Confidence 0.85 (pure and red-first;
//  that "Mike" is the intended pronunciation is a brand reading — M1K3 → MIKE
//  with 1→I, 3→E — and Kev's own report called the missing sound "the very first
//  letter in Mike". One line to revert if he wants it spelled out). Prior: Unknown.
//

import M1K3Voice
import Testing

struct SpokenNameTests {
    @Test("M1K3 is spoken as its name, not spelled out")
    func nameIsSpoken() {
        #expect(SpeechTextPolish.polish("I'm M1K3.") == "I'm Mike.")
        #expect(SpeechTextPolish.polish("m1k3 here") == "Mike here")
        #expect(SpeechTextPolish.polish("M1K3's memory") == "Mike's memory")
    }

    @Test("only the whole word — never a fragment of something longer")
    func wholeWordOnly() {
        // A model id, a path, or a bundle id must survive untouched: "app.m1k3"
        // read aloud as "app.Mike" would be wrong, and worse, unpredictable.
        #expect(SpeechTextPolish.polish("app.m1k3 is the bundle id")
            .contains("app.m1k3"))
        #expect(SpeechTextPolish.polish("M1K3Voice") == "M1K3Voice")
        #expect(SpeechTextPolish.polish("xM1K3x") == "xM1K3x")
    }

    @Test("the rest of the sentence is untouched")
    func leavesEverythingElse() {
        #expect(SpeechTextPolish.polish("MCP and MLX are fine") == "MCP and MLX are fine")
    }

    // MARK: - The introduction (Kev, 2026-09-24)

    @Test("the introduction says the letters, then the nickname")
    func introductionSpellsTheName() {
        // "Hi, I'm M1K3 — but my friends call me Mike!" reached Kokoro raw, and its
        // house lexicon (rightly, everywhere else) said "Mike": "Hi, I'm Mike — but
        // my friends call me Mike!" The one line that introduces the brand says it.
        #expect(SpokenName.introduction == "Hi, I'm em one kay three — but my friends call me Mike!")
    }

    @Test("the introduction never hands an engine the raw name")
    func introductionHasNoRawName() {
        // Raw "M1K3" is Mike on Kokoro and an alphanumeric jumble on AVSpeech —
        // neither is the letters. Words are the only form every engine agrees on.
        #expect(!SpokenName.introduction.localizedCaseInsensitiveContains("m1k3"))
    }

    @Test("polish keeps the letters — only the raw name becomes Mike")
    func polishKeepsTheLetters() {
        // Future-proofing: speakSample() hands the line to the engine directly
        // today, but a later route through speak() (polish) must not undo it.
        #expect(SpeechTextPolish.polish(SpokenName.introduction).contains(SpokenName.spelled))
        #expect(SpeechTextPolish.polish("I'm M1K3.") == "I'm \(SpokenName.everyday).")
    }
}
