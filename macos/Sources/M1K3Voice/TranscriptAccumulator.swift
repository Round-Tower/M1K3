//
//  TranscriptAccumulator.swift
//  M1K3Voice
//
//  Folds a stream of TranscriptSegments into the current dictation text. Both
//  recognisers (Apple Speech, WhisperKit) emit *cumulative* best-so-far text per
//  partial — so the working text is simply the latest non-empty segment, and a
//  final segment flags the utterance complete. Pure value type: the fold is the
//  one bit of dictation logic with real edge cases (empty partials, final), so
//  it's tested; the recognisers themselves are verify-by-launch.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-08-15 — commit-and-continue fold: finals
//  COMMIT their text, later partials replace only the live tail (mid-listen
//  recognizer restarts made "latest non-empty wins" destructive). Identical
//  output for finality-only-at-end listens, pinned by the original tests
//  passing untouched. Confidence 0.9.

import Foundation

/// Accumulates live partials into the text to show (and ultimately send).
///
/// COMMIT-AND-CONTINUE (2026-08-15): a final segment COMMITS its text; later
/// partials replace only the live tail beyond it. This is what makes mid-listen
/// recognizer restarts safe (FinalityPolicy.keepsListening): the restarted
/// recognition session's cumulative partials start FROM EMPTY, and under the
/// old "latest non-empty wins" fold they would silently replace everything
/// already finalized. For a listen that sees finality only at its end (chat
/// dictation, WhisperKit, MCP listen) the fold is byte-identical to before.
public struct TranscriptAccumulator: Sendable, Equatable {
    /// True once a final segment has been ingested (latched).
    public private(set) var isFinal: Bool = false
    /// The latest REPORTED confidence — nil only when no segment has ever
    /// carried one (WhisperKit, which reports none, so its silence-ghosts still
    /// drop at the sanitizer's gate). A nil-confidence segment does not erase an
    /// earlier real measurement: Apple's non-final partials carry nil (its 0.0
    /// there is meaningless), and a consumer-endpointed turn can legitimately
    /// end on such a tail — erasing the measurement there ghost-dropped a
    /// genuine trailing "thanks"/"bye" (review fold, #129).
    public private(set) var confidence: Float?
    /// Finalized text from completed recognition segments.
    private var committed: String = ""
    /// The current session's cumulative best-so-far (not yet finalized).
    private var live: String = ""

    public init() {}

    /// The best-so-far dictation text: everything finalized plus the live tail.
    public var text: String {
        if committed.isEmpty { return live }
        if live.isEmpty { return committed }
        return committed + " " + live
    }

    /// Fold one segment in. Cumulative recognisers replace the live tail;
    /// finals commit it; empty partials are ignored so a momentary blank
    /// doesn't wipe progress.
    public mutating func ingest(_ segment: TranscriptSegment) {
        if !segment.text.isEmpty {
            if segment.isFinal {
                committed = committed.isEmpty ? segment.text : committed + " " + segment.text
                live = ""
            } else {
                live = segment.text
            }
            if let reported = segment.confidence {
                confidence = reported
            }
        }
        if segment.isFinal { isFinal = true }
    }
}
