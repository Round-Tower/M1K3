//
//  DictationCompletionPolicy.swift
//  M1K3Voice
//
//  What to do with a FINISHED dictation, given the app's state at the moment
//  the recognizer settles (#126). Before this existed, `finishDictation` went
//  straight from "cleaned, non-empty, brain ready" to `send(cleaned)` — with no
//  term for a turn already streaming. `ChatSession.send` no-ops re-entrantly
//  (by design, so a double-tap can't double-fire a turn), so a dictation that
//  finished mid-answer was discarded with zero trace: the user spoke, and
//  nothing happened. This is the decision the caller was missing, pulled out
//  pure so the three outcomes — drop / queue / send — are pinned independent
//  of AppEnvironment, SwiftUI, or the recognizer.
//
//  Signed: Kev + claude-fable-5, 2026-09-01, Confidence 0.85 (pure decision
//  table, mirrors the caller's existing guard shape exactly — the caller side
//  wiring stays verify-by-launch per this repo's MLX/voice convention).
//  Prior: Unknown.
//

import Foundation

/// The three things a finished dictation can become. Never a fourth silent
/// drop path — every branch here is one the caller renders explicitly.
public enum DictationCompletionOutcome: Equatable, Sendable {
    /// Nothing worth acting on: an empty/hallucination-only transcript, or the
    /// brain isn't ready yet. Unchanged from the pre-#126 behaviour — a listen
    /// that finishes before first load was, and still is, dropped rather than
    /// queued (queuing a turn no brain can yet answer isn't kinder, just later).
    case drop
    /// A turn is already streaming — hand the words back to the caller to
    /// fold into the draft instead of throwing them away (the #126 fix).
    case queueForLater(String)
    /// Nothing is in flight — send immediately, today's fast path.
    case sendNow(String)
}

public enum DictationCompletionPolicy {
    /// - Parameters:
    ///   - cleanedText: the transcript AFTER `TranscriptSanitizer.clean` —
    ///     empty when the utterance was noise-only.
    ///   - isReady: whether the active brain can take a turn right now.
    ///   - isResponding: whether a previous turn is still streaming
    ///     (`ChatSession.isResponding`).
    public static func decide(
        cleanedText: String,
        isReady: Bool,
        isResponding: Bool
    ) -> DictationCompletionOutcome {
        guard isReady, !cleanedText.isEmpty else { return .drop }
        return isResponding ? .queueForLater(cleanedText) : .sendNow(cleanedText)
    }
}
