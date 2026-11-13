//
//  ListenEndpointTests.swift
//  M1K3VoiceTests
//
//  The one-shot listen's decisions, on literal transcripts: a silence ghost
//  neither ends the listen early nor comes back as speech, and a real lone
//  "thanks" is never reported as silence.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.85. Prior: none (new file).
//

import M1K3Voice
import Testing

struct ListenEndpointTests {
    @Test("real speech followed by the pause ends the listen")
    func speechThenPause() {
        #expect(ListenEndpoint.shouldStop(waited: 6, timeout: 30, transcript: "book the flights", quiet: 2.0))
        #expect(!ListenEndpoint.shouldStop(waited: 6, timeout: 30, transcript: "book the flights", quiet: 1.9))
    }

    @Test("a ghost or a lone pleasantry does not end the listen: the user may not have spoken yet")
    func ghostDoesNotEndpoint() {
        for ghost in ["you", "you you", "Thank you.", "thanks for watching", "  "] {
            #expect(!ListenEndpoint.shouldStop(waited: 6, timeout: 30, transcript: ghost, quiet: 20), "\(ghost)")
        }
    }

    @Test("the timeout always ends the listen, whatever was heard")
    func timeoutEnds() {
        #expect(ListenEndpoint.shouldStop(waited: 30, timeout: 30, transcript: "", quiet: 0))
        #expect(ListenEndpoint.shouldStop(waited: 31, timeout: 30, transcript: "you you", quiet: 0))
        #expect(ListenEndpoint.shouldStop(waited: 30, timeout: 30, transcript: "still talking", quiet: 0.1))
    }

    @Test("the bare ghost word, once or repeated, is nothing")
    func ghostWordIsNothing() {
        // Found live 2026-11-13: two silent listens both returned "you you".
        for ghost in ["you", "You.", "you you", "you you you you"] {
            #expect(ListenEndpoint.heard(ghost) == .nothing, "\(ghost)")
            #expect(ListenEndpoint.report(ghost).isEmpty, "\(ghost)")
        }
        #expect(ListenEndpoint.heard("you go first") == .speech("you go first"))
    }

    @Test("a lone pleasantry is never reported as silence: it comes back, marked unconfirmed")
    func pleasantryIsUnconfirmedNotLost() {
        #expect(ListenEndpoint.heard("Thanks.") == .unconfirmed("Thanks."))
        let report = ListenEndpoint.report("Thank you.")
        #expect(report.contains("Thank you."))
        #expect(report.contains("unconfirmed"))
        // In a sentence it is ordinary speech.
        #expect(ListenEndpoint.report("thank you for checking the weather") == "thank you for checking the weather")
    }

    @Test("a confident recogniser is believed, pleasantry and pronoun alike")
    func confidentRecogniserIsBelieved() {
        #expect(ListenEndpoint.heard("thank you", confidence: 0.9) == .speech("thank you"))
        #expect(ListenEndpoint.heard("you", confidence: 0.9) == .speech("you"))
        #expect(ListenEndpoint.shouldStop(
            waited: 6, timeout: 30, transcript: "thank you", confidence: 0.9, quiet: 2.5
        ))
    }

    @Test("speech is tidied on the way out")
    func speechIsTidied() {
        #expect(ListenEndpoint.report("  my name is   Kev ") == "my name is Kev")
        #expect(ListenEndpoint.report("the the the the weather") == "the weather")
    }
}
