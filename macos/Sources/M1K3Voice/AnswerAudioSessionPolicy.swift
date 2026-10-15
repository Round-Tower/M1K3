//
//  AnswerAudioSessionPolicy.swift
//  M1K3Voice
//
//  Who lets go of the phone's ducking speech session: the `.playback` / `.spokenAudio` one that a readout, the
//  Settings sample and an auto-spoken answer play under. Letting go (with .notifyOthersOnDeactivation) is what brings
//  the user's music back up, so a release at the wrong moment is audible. Between two sentences of one answer the
//  music swells and the next sentence starts on a session that was just deactivated (fb845b90). A superseded answer's
//  late cleanup lands on its successor: the music comes up under the new answer, and Stop flips back to Send.
//
//  The iPhone shell asks these two questions (AppCore+Voice's onSpeakingEnded, AppCore+AutoSpeak's session end).
//  An auto-spoken answer takes the session at its FIRST SENTENCE, not at the send, so the music plays on through a
//  generation that can run for minutes.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-15, Confidence 0.85 (pure rules, truth tables in
//  AnswerAudioSessionPolicyTests; how it sounds is verify-by-ear on the phone). Prior: none (new file).
//

public enum AnswerAudioSessionPolicy {
    /// One utterance ended outside an answer's control: a readout, the sample, or one sentence of an auto-spoken
    /// answer. Release, unless voice mode owns the session (releasing it would kill the mic) or an auto-spoken
    /// answer holds it (it speaks one utterance per sentence and releases at its own end).
    public static func releaseWhenUtteranceEnds(voiceModeActive: Bool, answerHoldsSession: Bool) -> Bool {
        !voiceModeActive && !answerHoldsSession
    }

    /// An auto-spoken answer ended: finished, failed, stopped or superseded. Release only when it is still the
    /// current answer (a successor owns the audio from there), it took the session (at its first sentence; a
    /// refused send never did), and voice mode hasn't taken over.
    public static func releaseWhenAnswerEnds(isCurrent: Bool, holdsSession: Bool, voiceModeActive: Bool) -> Bool {
        isCurrent && holdsSession && !voiceModeActive
    }
}
