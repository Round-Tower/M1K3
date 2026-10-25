//
//  SpokenAnswerEnd.swift
//  M1K3Voice
//
//  Where a streamed answer stops being spoken: the follow-ups trailer or the sources
//  block, whichever comes first. SpeechTextPolish already strips a trailing "Web
//  sources:" block, but only from a WHOLE answer; voice mode speaks sentence by sentence,
//  so the block arrived a line at a time and each URL line was read aloud (Kev,
//  2026-10-25: "it's still reading its web sources verbatim"). The follow-ups finder is
//  passed in: FollowUpSplit lives in M1K3Inference, which this module can't import.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-25, Confidence 0.8 (pinned against the
//  appended provenance block and model-written lists; a header the model invents in
//  another shape still speaks). Prior: none (new file).
//

import Foundation

public enum SpokenAnswerEnd {
    /// The earliest point speech should stop, or nil to speak it all.
    public static func start(in text: String, followUps: (String) -> String.Index?) -> String.Index? {
        [followUps(text), sourcesHeader(in: text)].compactMap(\.self).min()
    }

    /// A sources header on its own line after the answer: "Web sources:" (the appended
    /// provenance), "Wikipedia sources:", or a model's "Sources:" / "**Source:**",
    /// optionally followed by a bracketed list on the same line. Never the first line,
    /// and never with prose after the colon, so "It has many water sources: rivers…"
    /// still speaks.
    public static func sourcesHeader(in text: String) -> String.Index? {
        text.firstMatch(
            of: /(?im)\n[ \t]*(?:\*\*)?(?:web |wikipedia )?sources?(?:\*\*)?[ \t]*:(?:\*\*)?[ \t]*(?:\[[^\n]*)?$/
        )?.range.lowerBound
    }
}
