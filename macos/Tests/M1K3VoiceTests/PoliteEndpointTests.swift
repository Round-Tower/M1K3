//
//  PoliteEndpointTests.swift
//  M1K3VoiceTests
//
//  "Please" is the spoken submit button (Kev, 2026-08-13): a turn that ENDS on
//  it endpoints on the short polite window instead of the conversational
//  silence/hold/learned-cadence waits. Pure trailing-word check — pinned here so
//  nobody widens it into substring matching ("pleased to meet you" must never
//  submit) or forgets that a mid-sentence "please" is not a submit.
//
//  Signed: Kev + claude-fable-5, 2026-08-13, Confidence 0.9. Prior: Unknown.
//  Review: claude-opus-5-5, 2026-11-19 — localisation: the catalogued hint's English bytes and the English
//  `submitWord` are pinned.
//  Review: claude-opus-5-5, 2026-11-19 — review fold: the submit word is per-locale (`localizedSubmitWord`, "please"
//  in English); the hint teaches it and `isSubmit` matches it as well as the English word.
//  Review: claude-opus-5-5, 2026-11-20 — comment only: the recogniser is pinned to English in wave one
//  (`SpeechLocalePolicy`), so the hint's word is "please" in every language for now.

@testable import M1K3Voice
import Testing

struct PoliteEndpointTests {
    @Test("a turn ending in please is a submit")
    func trailingPleaseSubmits() {
        #expect(PoliteEndpoint.isSubmit("tell me a story please"))
        #expect(PoliteEndpoint.isSubmit("what's the weather like please"))
    }

    @Test("case and trailing punctuation don't matter — recognizers vary")
    func caseAndPunctuationTolerated() {
        #expect(PoliteEndpoint.isSubmit("Tell me a story Please"))
        #expect(PoliteEndpoint.isSubmit("tell me a story please."))
        #expect(PoliteEndpoint.isSubmit("tell me a story PLEASE!"))
        #expect(PoliteEndpoint.isSubmit("tell me a story, please"))
    }

    @Test("a mid-sentence please is not a submit")
    func midSentencePleaseDoesNotSubmit() {
        #expect(!PoliteEndpoint.isSubmit("please tell me a story"))
        #expect(!PoliteEndpoint.isSubmit("can you please look this up for me"))
    }

    @Test("words containing please don't submit — whole word only")
    func containingWordsDoNotSubmit() {
        #expect(!PoliteEndpoint.isSubmit("I was very pleased"))
        #expect(!PoliteEndpoint.isSubmit("displease"))
    }

    @Test("bare please submits — politeness to the machine deserves a reply")
    func barePleaseSubmits() {
        #expect(PoliteEndpoint.isSubmit("please"))
        #expect(PoliteEndpoint.isSubmit("  Please. "))
    }

    @Test("empty and whitespace never submit")
    func emptyNeverSubmits() {
        #expect(!PoliteEndpoint.isSubmit(""))
        #expect(!PoliteEndpoint.isSubmit("   "))
    }

    @Test("the UI hint names the submit word it teaches")
    func uiHintNamesTheWord() {
        // Both shells render this one constant; if the submit word ever
        // changes, the hint must move with it or the UI teaches a lie.
        #expect(PoliteEndpoint.uiHint.lowercased().contains("please"))
    }

    @Test("the catalogued hint keeps its English bytes, and the submit word stays English")
    func uiHintEnglishBytesFrozen() {
        #expect(PoliteEndpoint.submitWord == "please")
        #expect(PoliteEndpoint.uiHint == "End with “please” and M1K3 will take its turn")
        #expect(PoliteEndpoint.localizedSubmitWord == "please")
    }

    @Test("the hint teaches the word the listener matches, in the app's language")
    func hintTeachesTheMatchedWord() {
        // The hint and the match both read `localizedSubmitWord` ("please" everywhere while the recogniser is
        // pinned to English, `SpeechLocalePolicy`); the English word always submits too.
        #expect(PoliteEndpoint.uiHint.contains("“\(PoliteEndpoint.localizedSubmitWord)”"))
        #expect(PoliteEndpoint.isSubmit("tell me a story \(PoliteEndpoint.localizedSubmitWord)"))
        #expect(PoliteEndpoint.isSubmit("tell me a story \(PoliteEndpoint.submitWord)"))
    }
}
