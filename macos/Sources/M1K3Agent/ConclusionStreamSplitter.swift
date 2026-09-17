//
//  ConclusionStreamSplitter.swift
//  M1K3Agent
//
//  Buffers a streamed thought until the CONCLUSION: marker appears, then
//  passes everything after it through live — this is why the agent's final
//  answer streams token-by-token instead of arriving as one dump, without an
//  extra generation pass.
//
//  Handles both provider stream contracts (cumulative snapshots à la Apple
//  Foundation Models, and plain deltas) with the same normalise-to-delta rule
//  as ChatSession.fold, and a marker split across token boundaries.
//
//  Scaffolding guard: a model that writes "CONCLUSION: … ACTION: …" would
//  otherwise stream raw ReAct scaffolding to the user (seen live at ⌘R, the
//  Boston-weather bug). Emission is therefore cut at any ACTION: marker, with
//  a small holdback window so a marker split across chunks is still caught —
//  call `flush()` after the stream ends to release the held-back tail.
//
//  Signed: Kev + claude-fable-5, 2026-06-09, Confidence 0.9, Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-07-02 — snapshot-vs-delta normalisation
//  delegated to M1K3Inference.StreamFold (was one of three inlined copies).

import Foundation
import M1K3Inference

struct ConclusionStreamSplitter {
    /// The full thought accumulated so far (marker included).
    private(set) var thought = ""
    /// True once the CONCLUSION: marker has been seen.
    private(set) var isConclusion = false

    private var emittedAny = false
    /// True once an ACTION: marker stopped emission — skipping the ACTION
    /// line. Cleared when a newline after the ACTION line arrives, so
    /// post-ACTION prose resumes streaming (#329).
    private var skippingActionLine = false
    /// Tail kept back from emission so a split "ACTION:" can be caught.
    private var heldBack = ""

    private static let marker = "CONCLUSION:"
    private static let stopMarker = "ACTION:"
    /// One less than the stop marker's length — the longest prefix of it that
    /// could be dangling at the end of an emitted chunk.
    private static let guardWindow = stopMarker.count - 1

    /// Feed one raw stream chunk. Returns the text to emit live — empty while
    /// still buffering (no marker yet) or while text sits in the guard window.
    mutating func feed(_ chunk: String) -> String {
        // Normalise cumulative snapshots to deltas (StreamFold's shared rule).
        let delta = StreamFold.delta(current: thought, chunk: chunk)
        thought += delta

        if skippingActionLine {
            if let nl = delta.firstIndex(of: "\n") {
                let resumed = String(delta[delta.index(after: nl)...])
                skippingActionLine = false
                return resumed.isEmpty ? "" : emitGuarded(resumed)
            }
            return ""
        }
        if isConclusion {
            return emitGuarded(delta)
        }
        guard let markerRange = thought.range(of: Self.marker) else { return "" }
        isConclusion = true
        return emitGuarded(String(thought[markerRange.upperBound...]))
    }

    /// Release the guard window once the stream is over. Empty unless a
    /// conclusion was being emitted.
    mutating func flush() -> String {
        defer { heldBack = "" }
        guard isConclusion, !skippingActionLine else { return "" }
        return heldBack
    }

    /// Emit conclusion text: drop leading whitespace before the first real
    /// emission, cut at any ACTION: marker, and keep the last few characters
    /// back so a marker split across chunks is still caught.
    private mutating func emitGuarded(_ text: String) -> String {
        var working = heldBack + text
        heldBack = ""
        if !emittedAny {
            working = String(working.drop(while: \.isWhitespace))
            guard !working.isEmpty else { return "" }
        }
        if let stop = working.range(of: Self.stopMarker) {
            let kept = String(working[..<stop.lowerBound])
            let afterMarker = String(working[stop.upperBound...])
            if let nl = afterMarker.firstIndex(of: "\n") {
                let resumed = String(afterMarker[afterMarker.index(after: nl)...])
                if !resumed.isEmpty { heldBack = resumed }
            } else {
                skippingActionLine = true
            }
            return markEmitted(trimTrailingWhitespace(kept))
        }
        guard working.count > Self.guardWindow else {
            heldBack = working
            return ""
        }
        let cut = working.index(working.endIndex, offsetBy: -Self.guardWindow)
        heldBack = String(working[cut...])
        return markEmitted(String(working[..<cut]))
    }

    private mutating func markEmitted(_ text: String) -> String {
        if !text.isEmpty { emittedAny = true }
        return text
    }

    private func trimTrailingWhitespace(_ text: String) -> String {
        var trimmed = text
        while let last = trimmed.last, last.isWhitespace {
            trimmed.removeLast()
        }
        return trimmed
    }
}
