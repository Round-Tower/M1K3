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
}
