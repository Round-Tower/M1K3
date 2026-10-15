//
//  AnswerAudioSessionPolicyTests.swift
//  M1K3VoiceTests
//
//  Who lets go of the phone's ducking speech session, as truth tables. The iPhone shell (AppCore+Voice's
//  onSpeakingEnded and AppCore+AutoSpeak's session end) asks these; IOSAutoSpeakWiringScanTests pins that it does.
//  How the music sounds coming back is verify-by-ear on the phone.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-15, Confidence 0.85 (pure rules; the review of the merged branch found the
//  races they close by reading the shell). Prior: none (new file).
//

import M1K3Voice
import Testing

struct AnswerAudioSessionPolicyTests {
    @Test("an utterance's end releases the session, unless voice mode has it or an auto-spoken answer holds it")
    func utteranceEnd() {
        // A readout or the Settings sample ending: the music comes back up.
        #expect(AnswerAudioSessionPolicy.releaseWhenUtteranceEnds(voiceModeActive: false, answerHoldsSession: false))
        // One sentence of an auto-spoken answer: the next sentence follows; the answer releases at its own end.
        #expect(!AnswerAudioSessionPolicy.releaseWhenUtteranceEnds(voiceModeActive: false, answerHoldsSession: true))
        // Voice mode's echo-cancelled session: releasing it would kill the mic.
        #expect(!AnswerAudioSessionPolicy.releaseWhenUtteranceEnds(voiceModeActive: true, answerHoldsSession: false))
        #expect(!AnswerAudioSessionPolicy.releaseWhenUtteranceEnds(voiceModeActive: true, answerHoldsSession: true))
    }

    @Test("an answer's end releases only when it is still the current answer, took the session, and voice mode didn't")
    func answerEnd() {
        for isCurrent in [false, true] {
            for holds in [false, true] {
                for voice in [false, true] {
                    let release = AnswerAudioSessionPolicy.releaseWhenAnswerEnds(
                        isCurrent: isCurrent, holdsSession: holds, voiceModeActive: voice
                    )
                    // Only one row releases: a superseded answer's late end belongs to its successor, an answer
                    // that never spoke holds nothing, and voice mode keeps the session it took.
                    let row: Comment = "current \(isCurrent) holds \(holds) voice \(voice)"
                    #expect(release == (isCurrent && holds && !voice), row)
                }
            }
        }
    }
}
