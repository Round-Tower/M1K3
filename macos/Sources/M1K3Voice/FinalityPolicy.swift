//
//  FinalityPolicy.swift
//  M1K3Voice
//
//  Who owns the turn boundary: the consumer's endpointer, or the recognizer's
//  own voice-activity detector. The 2026-08-15 finding behind it: on Apple
//  Speech, `isFinal` ended the stream and the voice loop's stream-end handler
//  fired `.endpointed` unconditionally — so Apple's short, untunable internal
//  silence window owned the turn, and the entire cadence stack (silence / hold /
//  learned floor / "please") only mattered when it happened to beat Apple to the
//  decision. WhisperKit never had the problem: it finalizes only when WE stop
//  it. The two engines had structurally different endpoint authority and the
//  loop treated them identically.
//
//  `keepsListening` makes the authority explicit: recognizer finality becomes a
//  segment boundary (the transcriber restarts recognition under the same
//  session; the accumulator commits the finalized text and appends the new
//  tail) and only the consumer ends the listen. Chat dictation and the MCP
//  listen tool keep `endsListen` — their auto-submit-on-finality is a feature.
//
//  The restart is deliberately conditional on captured text: nothing can be
//  "cut off" if the user hasn't spoken, and ending a silent listen exactly as
//  today preserves the machine's empty-listen parking.
//
//  Signed: Kev + claude-fable-5, 2026-08-15, Confidence 0.85 (the policy is
//  pure and test-pinned; the transcriber's restart glue is verify-by-launch per
//  the file's own convention). Prior: recognizer-owned finality everywhere.
//

import Foundation

/// What a live-transcription session does when the recognizer declares finality
/// on its own (its internal VAD, not a consumer stop).
public enum FinalityPolicy: Sendable, Equatable {
    /// Recognizer finality ends the listen — today's dictation/MCP behaviour.
    case endsListen
    /// Recognizer finality is just a segment boundary: keep the mic and stream
    /// open, restart recognition, and let the consumer's endpointer end the turn.
    case keepsListening

    /// Whether a recognizer-initiated finality (or a no-speech error) should
    /// restart recognition instead of ending the listen.
    public func shouldRestart(hasCapturedText: Bool) -> Bool {
        self == .keepsListening && hasCapturedText
    }
}
