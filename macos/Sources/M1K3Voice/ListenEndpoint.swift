//
//  ListenEndpoint.swift
//  M1K3Voice
//
//  When a one-shot listen (the MCP `listen` tool) is over, and what it heard.
//  The shell's watchdog ended a listen two seconds after ANY text appeared and
//  returned that text raw, so a recogniser ghost on a silent mic ("you you",
//  twice, live on 2026-11-13) both cut the listen short and came back as if the
//  user had said it.
//
//  Three readings of a transcript, when the recogniser gave no confidence
//  (WhisperKit) or a low one:
//   - a bare ghost word, once or repeated ("you", "you you"): nothing was said;
//   - a lone pleasantry ("thank you", "bye"): UNCONFIRMED. It is the other
//     classic silence ghost and also a perfectly good reply, and a listen has
//     no re-prompt, so it is neither dropped nor asserted: it comes back marked;
//   - anything else: speech.
//  Only speech ends the listen on a pause. The other two wait for the timeout,
//  because the user may not have spoken yet — the cost of a real lone "thanks"
//  is the wait, never the words.
//
//  Pure, so it is pinned here; the shell (MCPHostController.listenForTranscript)
//  only supplies the clock and the stream.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.8 (the policy is
//  pinned in ListenEndpointTests; that a real silent mic now returns nothing is
//  verify-by-launch). Prior: none (new file; the 2 s pause moved from the shell).
//  Open: the cause is upstream — WhisperKitProvider reads the stream's in-progress text, which
//  arrives before the engine's own no-speech verdict. This filters the symptom.
//

import Foundation

public enum ListenEndpoint {
    /// How long the transcript must stay unchanged, once there is speech, before
    /// the listen ends.
    public static let pause: TimeInterval = 2.0

    public enum Heard: Equatable, Sendable {
        case nothing
        /// Only a pleasantry, from a recogniser that could not vouch for it.
        case unconfirmed(String)
        case speech(String)
    }

    public static func heard(_ transcript: String, confidence: Float? = nil) -> Heard {
        // Pleasantries are judged HERE, not dropped by the sanitiser.
        let text = TranscriptSanitizer.clean(transcript, confidence: confidence, dropPleasantries: false)
        guard !text.isEmpty else { return .nothing }
        guard (confidence ?? 0) < TranscriptSanitizer.confidenceFloor else { return .speech(text) }
        if TranscriptSanitizer.isGhostWordOnly(transcript, minimumRepeats: 1) { return .nothing }
        if TranscriptSanitizer.isPleasantryOnly(text) { return .unconfirmed(text) }
        return .speech(text)
    }

    /// What the listen hands its caller: the words, an unconfirmed pleasantry
    /// marked as such, or "" for nothing.
    public static func report(_ transcript: String, confidence: Float? = nil) -> String {
        switch heard(transcript, confidence: confidence) {
        case .nothing: ""
        case let .speech(text): text
        case let .unconfirmed(text):
            "“\(text)” (unconfirmed: it is all that was heard, and this recogniser also produces it on a silent mic)"
        }
    }

    /// Whether to stop listening now: the timeout has passed, or real speech has
    /// been followed by `pause` seconds of no change.
    public static func shouldStop(
        waited: TimeInterval,
        timeout: TimeInterval,
        transcript: String,
        confidence: Float? = nil,
        quiet: TimeInterval
    ) -> Bool {
        if waited >= timeout { return true }
        guard quiet >= pause, case .speech = heard(transcript, confidence: confidence) else { return false }
        return true
    }
}
