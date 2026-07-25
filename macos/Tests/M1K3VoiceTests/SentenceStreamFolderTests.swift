//
//  SentenceStreamFolderTests.swift
//  M1K3VoiceTests
//
//  The folder behind voice mode's sentence-streamed speech: it watches a
//  CUMULATIVE streaming text (the transcript message grows as tokens land) and
//  emits complete sentences exactly once, so TTS can start on the first
//  sentence instead of waiting ~25s for the whole answer (Kev's 07-25 "voice
//  takes ages" report — the loop previously spoke only on answerReady).
//
//  Signed: Kev + claude-fable-5, 2026-07-25, Confidence 0.9, Prior: Unknown
//

import M1K3Voice
import Testing

struct SentenceStreamFolderTests {
    // MARK: - Basic sentence emission

    @Test("a terminator followed by whitespace emits the sentence once")
    func emitsCompleteSentence() {
        var folder = SentenceStreamFolder()
        #expect(folder.ingest("Hello there. And") == ["Hello there."])
        // Re-ingesting the grown cumulative text must not re-emit.
        #expect(folder.ingest("Hello there. And now more") == [])
    }

    @Test("a trailing terminator with nothing after it is NOT emitted mid-stream")
    func trailingTerminatorHeldForMoreTokens() {
        var folder = SentenceStreamFolder()
        // "3." could be "3.14" once the next token lands — hold it.
        #expect(folder.ingest("It costs 3.") == [])
        #expect(folder.ingest("It costs 3.14 in total. So") == ["It costs 3.14 in total."])
    }

    @Test("multiple sentences arriving in one tick all emit, in order")
    func multipleSentencesOneTick() {
        var folder = SentenceStreamFolder()
        #expect(folder.ingest("One. Two! Three? Four") == ["One.", "Two!", "Three?"])
    }

    @Test("question and exclamation terminate too")
    func questionExclamation() {
        var folder = SentenceStreamFolder()
        #expect(folder.ingest("Really?! Yes. And") == ["Really?!", "Yes."])
    }

    // MARK: - Flush

    @Test("flush emits the unterminated remainder exactly once")
    func flushEmitsTail() {
        var folder = SentenceStreamFolder()
        _ = folder.ingest("Done. And one more thing")
        #expect(folder.flush() == "And one more thing")
        #expect(folder.flush() == nil)
    }

    @Test("flush after everything emitted returns nil")
    func flushEmptyTail() {
        var folder = SentenceStreamFolder()
        _ = folder.ingest("All said. ")
        #expect(folder.flush() == nil)
    }

    // MARK: - Paragraph breaks

    @Test("a blank-line paragraph break is a boundary even without a terminator")
    func paragraphBreakEmits() {
        var folder = SentenceStreamFolder()
        #expect(folder.ingest("The Aesthetic Suite\n\nFirst up") == ["The Aesthetic Suite"])
    }

    // MARK: - List numbering must not be spoken alone

    @Test("a digits-only fragment is held and folded into the next sentence")
    func digitsOnlyHeld() {
        var folder = SentenceStreamFolder()
        // "1." alone must not be spoken as a sentence.
        #expect(folder.ingest("1. Do the thing. 2. ") == ["1. Do the thing."])
    }

    // MARK: - Code fences stay whole

    @Test("a fenced code block is held until the closing fence")
    func fenceHeldWhole() {
        var folder = SentenceStreamFolder()
        #expect(folder.ingest("Try this:\n```swift\nlet x = 1. Done?\n") == ["Try this:"])
        let after = folder.ingest("Try this:\n```swift\nlet x = 1. Done?\n```\nThat works. And")
        #expect(after.count == 2)
        #expect(after[1] == "That works.")
        #expect(after[0].hasPrefix("```swift"))
    }

    // MARK: - Stop marker (the FOLLOWUPS trailer must never be spoken)

    @Test("everything from the stop marker on is dropped, before and after")
    func stopMarkerDropsTrailer() {
        var folder = SentenceStreamFolder(stopMarker: "FOLLOWUPS:")
        #expect(folder.ingest("The answer. FOLLOWUPS: [\"a?\"") == ["The answer."])
        #expect(folder.ingest("The answer. FOLLOWUPS: [\"a?\", \"b?\"]") == [])
        #expect(folder.flush() == nil)
    }

    @Test("a stop marker at the very start silences everything")
    func stopMarkerAtStart() {
        var folder = SentenceStreamFolder(stopMarker: "FOLLOWUPS:")
        #expect(folder.ingest("FOLLOWUPS: [\"a?\"]").isEmpty)
        #expect(folder.flush() == nil)
    }

    // MARK: - Shrinking / divergent input (defensive)

    @Test("cumulative text that shrinks or diverges resets cleanly instead of crashing")
    func divergentInputTolerated() {
        var folder = SentenceStreamFolder()
        _ = folder.ingest("A long first answer. With more")
        // A new (shorter, different) text — e.g. the observed message was
        // replaced. Never emit garbage offsets; treat as a fresh stream.
        let out = folder.ingest("Different.")
        #expect(out.isEmpty || out == ["Different."])
    }
}
