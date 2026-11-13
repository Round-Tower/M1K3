//
//  TranscriptSanitizerTests.swift
//  M1K3VoiceTests
//
//  Pins the final-utterance hygiene pass applied before a transcript reaches the
//  model: collapse pathological recognizer repetition, drop whole-utterance
//  silence-hallucinations ("Thank you" on a quiet mic), tidy whitespace. Returns
//  "" for an all-noise utterance so the caller's empty-guard parks the mic.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5.2, 2026-11-13 — the bare pronoun REPEATED ("you you") is a ghost and
//  drops; a single "you" is still kept (ghostPronounRepeated). Confidence 0.85.

import M1K3Voice
import Testing

struct TranscriptSanitizerTests {
    @Test("ordinary speech passes through untouched")
    func plainUntouched() {
        #expect(TranscriptSanitizer.clean("what's the weather in Dublin") == "what's the weather in Dublin")
    }

    @Test("trims and collapses runs of whitespace")
    func whitespace() {
        #expect(TranscriptSanitizer.clean("  hello   there  ") == "hello there")
    }

    @Test("collapses a pathological repeated-word loop, keeps natural doublings")
    func repetition() {
        // Whisper stutter: a long run of one word collapses to a single instance.
        #expect(TranscriptSanitizer.clean("the the the the weather") == "the weather")
        // A natural doubling is preserved (not a pathological loop).
        #expect(TranscriptSanitizer.clean("no no") == "no no")
        #expect(TranscriptSanitizer.clean("run run run") == "run") // 3+ collapses
    }

    @Test("collapses a heterogeneously-punctuated stutter loop")
    func repetitionMixedPunctuation() {
        // The comparison key is punctuation-stripped, so an inconsistent comma run
        // still collapses; the surviving token keeps its original punctuation.
        #expect(TranscriptSanitizer.clean("no, no no I meant yes") == "no, I meant yes")
    }

    @Test("drops a whole-utterance silence hallucination when confidence is absent")
    func hallucinationAbsentConfidence() {
        // WhisperKit reports no confidence (nil) — its silence ghosts must drop.
        #expect(TranscriptSanitizer.clean("Thank you.") == "")
        #expect(TranscriptSanitizer.clean("thanks for watching") == "")
    }

    @Test("a bare pronoun is NOT treated as a hallucination (plausible real turn)")
    func barePronounKept() {
        // "you" is a known whisper ghost but also a real command opener — kept.
        #expect(TranscriptSanitizer.clean("you") == "you")
    }

    @Test("the bare pronoun repeated is a silence ghost and drops; one alone is still kept")
    func ghostPronounRepeated() {
        // Found live 2026-11-13: two silent MCP listens both returned "you you".
        #expect(TranscriptSanitizer.clean("you you") == "")
        #expect(TranscriptSanitizer.clean("You. You.") == "")
        // Three or more must not collapse to a surviving single "you".
        #expect(TranscriptSanitizer.clean("you you you you") == "")
        #expect(TranscriptSanitizer.clean("you") == "you")
        // Only as the WHOLE utterance, and only when the recogniser isn't confident.
        #expect(TranscriptSanitizer.clean("you you go first") == "you you go first")
        #expect(TranscriptSanitizer.clean("you you", confidence: 0.9) == "you you")
        #expect(TranscriptSanitizer.clean("you you", dropPleasantries: false) == "you you")
        // Other natural doublings are untouched.
        #expect(TranscriptSanitizer.clean("no no") == "no no")
    }

    @Test("keeps a genuine pleasantry when the recognizer is confident")
    func hallucinationHighConfidenceKept() {
        // Apple Speech reports confidence — a real, confident "thank you" survives.
        #expect(TranscriptSanitizer.clean("thank you", confidence: 0.9) == "thank you")
    }

    @Test("drops a low-confidence pleasantry")
    func hallucinationLowConfidenceDropped() {
        #expect(TranscriptSanitizer.clean("thank you", confidence: 0.2) == "")
    }

    @Test("a pleasantry exactly at the confidence floor is kept (boundary is <, not <=)")
    func hallucinationAtFloorKept() {
        #expect(TranscriptSanitizer.clean("thank you", confidence: TranscriptSanitizer.confidenceFloor) == "thank you")
    }

    @Test("a multi-word silence hallucination drops on absent confidence")
    func multiWordHallucination() {
        #expect(TranscriptSanitizer.clean("thank you for watching") == "")
    }

    @Test("a hallucination phrase embedded in real speech is NOT dropped")
    func hallucinationSubstringKept() {
        let text = "thank you for checking the weather"
        #expect(TranscriptSanitizer.clean(text) == text)
    }

    @Test("dropPleasantries:false keeps pleasantries (call transcripts) but still tidies")
    func pleasantriesKeptForCalls() {
        // A call legitimately contains "thank you" — don't drop it...
        #expect(TranscriptSanitizer.clean("thank you", dropPleasantries: false) == "thank you")
        // ...but repetition collapse + whitespace still apply.
        #expect(TranscriptSanitizer.clean("yeah yeah yeah okay", dropPleasantries: false) == "yeah okay")
    }

    @Test("empty or whitespace-only sanitises to empty")
    func empty() {
        #expect(TranscriptSanitizer.clean("") == "")
        #expect(TranscriptSanitizer.clean("   ") == "")
    }
}
