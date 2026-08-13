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
}
