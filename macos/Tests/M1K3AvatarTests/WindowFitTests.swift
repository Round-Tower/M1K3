//
//  WindowFitTests.swift
//  M1K3AvatarTests
//
//  Red-first coverage for the shared visionOS camera-less window-fit math (#60's
//  pattern, promoted out of AvatarView.fit and reused by CompanionAvatarView.fit).
//
//  Signed: Kev + claude-fable-5, 2026-07-31, Confidence 0.85, Prior: Unknown

import M1K3Avatar
import Testing

struct WindowFitTests {
    @Test("scales content to fill the tighter of width/height, minus headroom")
    func scalesToTighterAxis() {
        // Content is 2x1 (wide); a square 10x10 window bounds means height is the
        // binding constraint: 10/1 = 10 vs 10/2 = 5 → width wins (5), not height.
        let scale = WindowFit.scale(
            contentWidth: 2, contentHeight: 1,
            boundsWidth: 10, boundsHeight: 10,
            headroom: 1.0
        )
        #expect(scale == 5)
    }

    @Test("applies headroom as a final multiplier")
    func appliesHeadroom() {
        let scale = WindowFit.scale(
            contentWidth: 1, contentHeight: 1,
            boundsWidth: 10, boundsHeight: 10,
            headroom: 0.9
        )
        #expect(scale == 9)
    }

    @Test("returns nil when content has no measurable extent")
    func nilOnZeroContent() {
        #expect(WindowFit.scale(contentWidth: 0, contentHeight: 1, boundsWidth: 10, boundsHeight: 10, headroom: 0.9) == nil)
        #expect(WindowFit.scale(contentWidth: 1, contentHeight: 0, boundsWidth: 10, boundsHeight: 10, headroom: 0.9) == nil)
    }

    @Test("returns nil when the resulting scale is non-finite or non-positive")
    func nilOnDegenerateBounds() {
        #expect(WindowFit.scale(contentWidth: 1, contentHeight: 1, boundsWidth: Float.nan, boundsHeight: 10, headroom: 0.9) == nil)
        #expect(WindowFit.scale(contentWidth: 1, contentHeight: 1, boundsWidth: 0, boundsHeight: 10, headroom: 0.9) == nil)
        #expect(WindowFit.scale(contentWidth: 1, contentHeight: 1, boundsWidth: -5, boundsHeight: 10, headroom: 0.9) == nil)
    }

    @Test("matches AvatarView's face-grid fit arithmetic exactly")
    func matchesFaceGridArithmetic() {
        // Regression pin for the exact call AvatarView.fit makes, so a future edit
        // to either side can't silently drift the two apart.
        let gridWidth: Float = (Float(13 - 1) * 0.1) + 0.068
        let gridHeight: Float = (Float(11 - 1) * 0.1) + 0.068
        let scale = WindowFit.scale(
            contentWidth: gridWidth, contentHeight: gridHeight,
            boundsWidth: 3.0, boundsHeight: 2.0,
            headroom: 0.9
        )
        let expected = min(3.0 / gridWidth, 2.0 / gridHeight) * 0.9
        #expect(scale == expected)
    }
}
