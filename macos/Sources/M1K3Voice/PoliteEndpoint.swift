//
//  PoliteEndpoint.swift
//  M1K3Voice
//
//  "Please" is the spoken submit button (Kev, 2026-08-13): instead of an
//  "over and out" protocol, ending your turn on the word please tells M1K3
//  you're done, and the endpointer takes its turn on the short polite window
//  rather than the conversational silence/hold/learned-cadence waits.
//
//  An ACCELERATOR, never a requirement — silence endpointing works exactly as
//  before when the word is absent (the 2026-07-29 hot-word verdict, now
//  Kev-requested). Whole-word, trailing-position only: a mid-sentence please
//  ("please tell me…") is ordinary politeness, and "pleased" must never submit.
//  The deliberate edge: "can you please" <pause> submits — that is the contract
//  the UI teaches ("M1K3 will take its turn after you say please"), so the
//  behaviour follows the promise, not a guess about intent.
//
//  Signed: Kev + claude-fable-5, 2026-08-13, Confidence 0.85 (pure and pinned;
//  the felt beat of the 1s polite window is Kev's to settle). Prior: Unknown.

import Foundation

/// Pure trailing-word check: does this live partial end on the submit word?
public enum PoliteEndpoint {
    /// The one hint both shells show while listening — shared for the same
    /// anti-drift reason as `EndpointCadence`: the Mac and iOS copies of a
    /// user-facing literal agree until someone edits one of them.
    public static let uiHint = "End with “please” and M1K3 will take its turn"

    public static func isSubmit(_ text: String) -> Bool {
        let lastWord = text
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .last
            .map { $0.lowercased().trimmingCharacters(in: edgeTrim) } ?? ""
        return lastWord == "please"
    }

    /// Punctuation peeled off the final word ("please." / "please!" / ", please").
    private static let edgeTrim = CharacterSet.letters.inverted
}
