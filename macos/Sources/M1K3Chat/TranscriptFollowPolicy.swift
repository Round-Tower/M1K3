//
//  TranscriptFollowPolicy.swift
//  M1K3Chat
//
//  Whether the transcript keeps following a streaming turn (#552). The
//  reader's scroll is the only thing that releases the pin: content growth —
//  the reasoning disclosure expanding, a tall turn landing — must never
//  unpin a reader who hasn't moved, and scrolling back near the bottom (or a
//  new turn) takes the pin again. Pure, so the edge cases are pinned here;
//  ContentView feeds it the scroll geometry.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-10, Confidence 0.85, Prior: none
//  (new file; the first cut lived in ContentView and unpinned on growth — the
//  #554 pass caught it).

import Foundation

public struct TranscriptScrollSnapshot: Sendable, Equatable {
    public let offsetY: Double
    public let containerHeight: Double
    public let contentHeight: Double

    public init(offsetY: Double, containerHeight: Double, contentHeight: Double) {
        self.offsetY = offsetY
        self.containerHeight = containerHeight
        self.contentHeight = contentHeight
    }

    /// Within `tolerance` points of the bottom (short content always is).
    public func isNearBottom(tolerance: Double) -> Bool {
        offsetY + containerHeight >= contentHeight - tolerance
    }
}

public enum TranscriptFollowPolicy {
    /// Points from the bottom that still count as "at the bottom".
    public static let tolerance: Double = 48

    /// The next pinned state. A scroll UP (offset decreased by more than a
    /// point) releases the pin; being near the bottom takes it; anything else —
    /// including content growing under a still reader — leaves it alone.
    public static func next(
        pinned: Bool, previous: TranscriptScrollSnapshot?, current: TranscriptScrollSnapshot
    ) -> Bool {
        if let previous, current.offsetY < previous.offsetY - 1 { return false }
        if current.isNearBottom(tolerance: tolerance) { return true }
        return pinned
    }
}
