//
//  SpeakQueuePolicy.swift
//  M1K3Voice
//
//  The pure decision behind visitor speech queuing (#283): a second MCP
//  client's `speak` while one utterance is already in flight must QUEUE
//  behind it instead of cutting it. EffectfulSpeechProvider's newer-wins
//  RenderEntry contract stays correct for the voice loop's barge-in and for
//  M1K3's own answers — only the MCP visitor path threads through this
//  policy (see VisitorSpeechQueue). Bounded so a forgotten or looping client
//  can't pile up an unbounded backlog of speech.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-11, Confidence 0.85 (pure decision
//  table, fully tested; the actor that applies it is verify-by-launch for the
//  two-live-client race). Prior: Unknown.
//

import Foundation

/// What an incoming visitor `speak` call should do, given what's already
/// queued for M1K3's one voice.
public enum SpeakQueueDecision: Equatable, Sendable {
    /// Nothing of ours is in flight — play immediately.
    case playNow
    /// Something is already speaking/queued: this call takes the given
    /// 1-based position in the wait line (1 = next up after the current
    /// utterance).
    case enqueue(position: Int)
    /// The queue is already at capacity — refuse rather than grow unbounded.
    case refuse(queued: Int)
}

public enum SpeakQueuePolicy {
    /// How many visitor utterances may wait behind the one in flight before a
    /// new `speak` call is refused outright.
    public static let defaultCap = 3

    /// `isSpeaking` — is M1K3's voice already committed to an utterance (ours
    /// or otherwise)? `queued` — how many visitor requests are ALREADY
    /// waiting (never counts whatever is currently playing).
    public static func decide(isSpeaking: Bool, queued: Int, cap: Int = defaultCap) -> SpeakQueueDecision {
        guard isSpeaking else { return .playNow }
        guard queued < cap else { return .refuse(queued: queued) }
        return .enqueue(position: queued + 1)
    }
}
