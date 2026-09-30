//
//  StreamedAnswerFolderTests.swift
//  M1K3VoiceTests
//
//  Pins the fold-forward guard that used to live inline in the Mac shell's
//  voice adapter (2026-07-25 review finding): fold ONLY prefix-extending
//  updates of the streamed answer. A FOLLOWUPS split or polish rewrite SHRINKS
//  the message text; feeding that to the sentence folder trips its divergence
//  reset and re-speaks the whole answer. Extracted so chat auto-speak and the
//  voice loop share one tested implementation instead of two drifting copies.
//
//  Signed: Kev + claude-fable-5, 2026-08-13, Confidence 0.9. Prior: the inline
//  foldForward in AppEnvironment+VoiceMode.swift (Kev + claude-opus-5).

import M1K3Voice
import Testing

struct StreamedAnswerFolderTests {
    @Test("forward growth folds completed sentences exactly once")
    func forwardGrowthFolds() {
        var folder = StreamedAnswerFolder()
        // A terminal "." is only a sentence once content FOLLOWS it (the
        // underlying folder's "3." of "3.14" guard) — flush() takes the tail.
        #expect(folder.ingest("Hello there.") == [])
        #expect(folder.ingest("Hello there. How are") == ["Hello there."])
        #expect(folder.ingest("Hello there. How are you? So") == ["How are you?"])
        #expect(folder.emittedAny)
    }

    @Test("a non-prefix update is skipped — never re-speak the answer")
    func nonPrefixUpdateSkipped() {
        var folder = StreamedAnswerFolder()
        #expect(folder.ingest("First sentence. Second") == ["First sentence."])
        // Polish rewrite shrinks the text (FOLLOWUPS strip): not a prefix
        // extension → ignored entirely, no divergence reset, no re-speak.
        #expect(folder.ingest("First sentence.") == [])
        // Growth from the ORIGINAL streamed text resumes normally.
        #expect(folder.ingest("First sentence. Second half done. And") == ["Second half done."])
    }

    @Test("flush yields the unterminated tail")
    func flushYieldsTail() {
        var folder = StreamedAnswerFolder()
        _ = folder.ingest("Done. And a trailing thought")
        #expect(folder.flush() == "And a trailing thought")
    }

    @Test("nothing streamed → nothing emitted, flush empty")
    func emptyStream() {
        var folder = StreamedAnswerFolder()
        #expect(!folder.emittedAny)
        #expect(folder.flush() == nil)
    }

    @Test("the stop marker ends folding — follow-ups are never spoken")
    func stopMarkerHonoured() {
        var folder = StreamedAnswerFolder(stopMarker: "FOLLOWUPS:")
        let chunks = folder.ingest("The answer. FOLLOWUPS: 1. never spoken?")
        #expect(chunks == ["The answer."])
        #expect(folder.flush() == nil)
    }

    // MARK: - The leak guard, live (2026-09-30)

    // Speech folds sentences out of the stream BEFORE ChatSession's end-of-turn
    // PersonaLeakGuard runs, so a leaked prompt used to be read aloud, then
    // replaced on screen. The folder now asks the guard about the whole stream
    // so far at every ingest, and the first leaking snapshot swallows the turn.
    private static let secret = "The villain never explains the plan twice, and never to the hero."
    private static func guardedFolder() -> StreamedAnswerFolder {
        StreamedAnswerFolder(leakGuard: .init(leaks: { $0.contains(secret) }, refusal: "I don't share my wiring."))
    }

    @Test("a sentence that leaks is never spoken; the refusal is spoken once instead")
    func leakedSentenceIsSwallowed() {
        var folder = Self.guardedFolder()
        #expect(folder.ingest("Sure. Here it is:") == ["Sure."]) // clean so far: spoken
        #expect(folder.ingest("Sure. Here it is: " + Self.secret + " And") == ["I don't share my wiring."])
        #expect(folder.tripped)
        #expect(folder.emittedAny)
    }

    @Test("once tripped, nothing later is spoken — not more sentences, not the tail")
    func trippedFolderStaysSilent() {
        var folder = Self.guardedFolder()
        _ = folder.ingest(Self.secret + " And then")
        #expect(folder.ingest(Self.secret + " And then some more. Really.") == [])
        #expect(folder.flush() == nil)
    }

    @Test("the check runs on the stream so far, so a leak still in the unterminated tail is caught before its sentence ends")
    func leakInTheTailIsCaughtEarly() {
        var folder = Self.guardedFolder()
        // The secret is complete but its sentence isn't: nothing before it may be spoken from here on.
        let spoken = folder.ingest("Fine. " + Self.secret)
        #expect(spoken == ["I don't share my wiring."]) // not "Fine."
    }

    @Test("sentences already spoken before a later leak stay spoken; the leak itself is not")
    func earlierSentencesStandOnly() {
        var folder = Self.guardedFolder()
        #expect(folder.ingest("First thought. Second") == ["First thought."])
        #expect(folder.ingest("First thought. Second thought. " + Self.secret) == ["I don't share my wiring."])
    }

    @Test("the on-screen swap to the refusal after a trip is a non-prefix update: skipped, so the refusal is spoken once")
    func onScreenSwapAfterTripIsSilent() {
        var folder = Self.guardedFolder()
        #expect(folder.ingest("Fine. " + Self.secret) == ["I don't share my wiring."])
        #expect(folder.ingest("I don't share my wiring.") == []) // ChatSession replaced the text
        #expect(folder.flush() == nil)
    }

    @Test("an unchanged snapshot never re-runs the guard (the pollers re-ingest identical text every tick)")
    func unchangedSnapshotSkipsTheGuard() {
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        var folder = StreamedAnswerFolder(leakGuard: .init(leaks: { _ in counter.calls += 1; return false }, refusal: "no"))
        _ = folder.ingest("Hello there. How")
        _ = folder.ingest("Hello there. How")
        _ = folder.ingest("Hello there. How")
        #expect(counter.calls == 1)
    }

    @Test("a clean stream with a guard behaves exactly as before")
    func cleanStreamUnchanged() {
        var folder = Self.guardedFolder()
        #expect(folder.ingest("Hello there. How are") == ["Hello there."])
        #expect(!folder.tripped)
        #expect(folder.flush() == "How are")
    }
}
