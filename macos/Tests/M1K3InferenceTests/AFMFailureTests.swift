//
//  AFMFailureTests.swift
//  M1K3InferenceTests
//
//  Mini's failures were invisible. `AppleFoundationModelsProvider` carried no
//  Logger at all, and `generateStreaming` ends `catch { continuation.finish() }`
//  — so a context overflow, a guardrail refusal, a daemon fall-over and a model
//  that genuinely had nothing to say all presented identically: an empty
//  stream. On the DEFAULT brain.
//
//  That ambiguity is not academic. An empty thought makes the ReAct floor
//  append a format reminder and re-prompt (growing the context that just
//  overflowed), burn the iteration cap, then fall through to a plain
//  ChatPromptBuilder generation with no tools and no honesty scaffold — the
//  documented shape of the fabricated weather forecast in #102. Distinguishing
//  the causes is the difference between a diagnosis and a guess.
//
//  Classification is pure and lives here so the mapping is pinned; the logging
//  itself rides the OS adapter, which is verified by launch per that file's own
//  convention.
//
//  Signed: Kev + claude-opus-5, 2026-08-09, Confidence 0.85, Prior: Unknown
//  Context: macos/docs/NEXT_SESSION.md #102 / #111. The overflow string is
//  quoted VERBATIM from a live 2026-08-03 throw (see MiniPromptBudgetTests);
//  the guardrail and daemon markers come from SDK case names and the logged
//  2026-08-03 rate-collapse, so they are recognised but not verbatim-pinned.
//

@testable import M1K3Inference
import Testing

struct AFMFailureTests {
    @Test("the verbatim live overflow throw classifies as a context overflow")
    func verbatimOverflow() {
        // Exactly as the SDK produced it on 2026-08-03, interviewing Mini over MCP.
        let live = "Content contains 4486 tokens, which exceeds the maximum "
            + "allowed context size of 4096."
        #expect(AFMFailure.classify(live) == .contextOverflow)
    }

    @Test("the SDK's own case name classifies as a context overflow")
    func caseNameOverflow() {
        #expect(AFMFailure.classify("exceededContextWindowSize") == .contextOverflow)
    }

    @Test("a guardrail refusal is not mistaken for an overflow")
    func guardrail() {
        // These are opposite fixes: an overflow means shrink the prompt, a
        // guardrail means the content itself was refused. Conflating them would
        // send us shrinking a prompt that fits perfectly well.
        #expect(AFMFailure.classify("guardrailViolation") == .guardrailViolation)
        #expect(AFMFailure.classify("Safety guardrail was triggered") == .guardrailViolation)
    }

    @Test("the daemon rate-collapse is its own class, not a mystery")
    func daemonCollapse() {
        // Logged 2026-08-03: back-to-back AFM turns exhaust ModelManagerServices
        // and EVERY answer degrades to empty — which looks exactly like your
        // change breaking everything. Naming it in the log stops that panic.
        #expect(AFMFailure.classify("ModelManagerError 1013") == .daemonUnavailable)
        #expect(AFMFailure.classify("SensitiveContentAnalysisML Code=15") == .daemonUnavailable)
    }

    @Test("an unrecognised error is reported as unknown, never silently reclassified")
    func unknownStaysUnknown() {
        #expect(AFMFailure.classify("something new from a future SDK") == .unknown)
        #expect(AFMFailure.classify("") == .unknown)
    }

    @Test("classification is case-insensitive — error text casing is not a contract")
    func caseInsensitive() {
        #expect(AFMFailure.classify("EXCEEDS THE MAXIMUM ALLOWED CONTEXT SIZE") == .contextOverflow)
        #expect(AFMFailure.classify("GuardrailViolation") == .guardrailViolation)
    }

    @Test("every class has a distinct, machine-readable slug for counting")
    func distinctSlugs() {
        let slugs = AFMFailure.allCases.map(\.rawValue)
        #expect(Set(slugs).count == slugs.count)
        for slug in slugs {
            #expect(!slug.isEmpty)
        }
    }

    @Test("overflow wins over a generic marker when both could match")
    func overflowIsSpecific() {
        // A real throw often carries several phrases; the most actionable
        // classification must win rather than whichever check ran first.
        let mixed = "Generation failed: content exceeds the maximum allowed "
            + "context size of 4096 for this session"
        #expect(AFMFailure.classify(mixed) == .contextOverflow)
    }
}
