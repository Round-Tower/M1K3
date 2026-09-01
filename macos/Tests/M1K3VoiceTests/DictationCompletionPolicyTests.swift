//
//  DictationCompletionPolicyTests.swift
//  M1K3VoiceTests
//
//  Signed: Kev + claude-fable-5, 2026-09-01, Confidence 0.9 (pure contract,
//  no fakes needed). Prior: Unknown.
//

import M1K3Voice
import Testing

/// Pins `DictationCompletionPolicy.decide` — the decision issue #126 found
/// missing entirely: a dictation that finishes while a PREVIOUS turn is still
/// streaming used to fall straight into `ChatSession.send`'s silent
/// re-entrancy no-op, discarding the user's words without a trace. The three
/// branches here are exhaustive over the caller's own guard shape (empty text
/// / not ready / already responding), so there is no fourth silent-drop path
/// left uncovered.
struct DictationCompletionPolicyTests {
    @Test("an empty cleaned transcript always drops, regardless of readiness or responding state")
    func emptyTextDrops() {
        #expect(DictationCompletionPolicy.decide(cleanedText: "", isReady: true, isResponding: false) == .drop)
        #expect(DictationCompletionPolicy.decide(cleanedText: "", isReady: true, isResponding: true) == .drop)
        #expect(DictationCompletionPolicy.decide(cleanedText: "", isReady: false, isResponding: false) == .drop)
    }

    @Test("a non-empty transcript before the brain is ready still drops — unchanged pre-#126 behaviour")
    func notReadyDrops() {
        #expect(
            DictationCompletionPolicy.decide(cleanedText: "hello there", isReady: false, isResponding: false)
                == .drop
        )
        // Not-ready outranks responding — a cold-launch dictation never queues.
        #expect(
            DictationCompletionPolicy.decide(cleanedText: "hello there", isReady: false, isResponding: true)
                == .drop
        )
    }

    @Test("ready + idle sends immediately — today's fast path, unchanged")
    func readyAndIdleSendsNow() {
        #expect(
            DictationCompletionPolicy.decide(cleanedText: "what's the weather", isReady: true, isResponding: false)
                == .sendNow("what's the weather")
        )
    }

    @Test("ready + a turn already streaming queues instead of dropping — the #126 fix")
    func readyAndRespondingQueues() {
        #expect(
            DictationCompletionPolicy.decide(cleanedText: "and one more thing", isReady: true, isResponding: true)
                == .queueForLater("and one more thing")
        )
    }
}
