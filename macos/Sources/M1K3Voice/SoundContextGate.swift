//
//  SoundContextGate.swift
//  M1K3Voice
//
//  When a listen's room line reaches the brain: an alert (an alarm, the door,
//  a phone, a baby) every turn it's heard; anything else only when it changes, so
//  a song playing through a whole conversation is mentioned once, not every
//  turn (challenger, 2026-10-15). The clause is built from SoundContext's fixed
//  vocabulary only: nothing heard can put its own words into the prompt.
//
//  `clause(for:)` only looks; `commit(_:)` records what the brain was told, and
//  the shell calls it only once the turn is really sent. A turn dropped before
//  it reaches the brain (barge-in) mustn't use up a changed room.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-16, Confidence 0.75. Prior: Unknown.

import Foundation

public struct SoundContextGate: Sendable {
    private var last: String?

    public init() {}

    /// The clause for this turn, or nil when there's nothing new to say.
    public func clause(for context: SoundContext?) -> String? {
        guard let context, let line = context.contextLine else { return nil }
        guard context.hasAlert || line != last else { return nil }
        return """
        Sounds the microphone picked up while the user spoke (automatic labels, may be wrong; \
        bring them up only if they matter): \(line).
        """
    }

    /// The turn that heard `context` reached the brain.
    public mutating func commit(_ context: SoundContext?) {
        last = context?.contextLine
    }
}
