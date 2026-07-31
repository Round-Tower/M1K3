//
//  WindowFit.swift
//  M1K3Avatar
//
//  The pure camera-less window-fit maths visionOS avatar surfaces need: RealityKit
//  ignores in-scene cameras there (the wearer's eyes ARE the camera; content renders
//  at true world scale), so content is instead scaled to fill the window's own
//  scene-space bounds. Originated inline in AvatarView.fit (PR #60, the pixel-face
//  V0 black-avatar fix) and promoted here so CompanionAvatarView's 3D creatures can
//  share the exact same arithmetic rather than re-deriving it. No RealityKit import —
//  pure `Float` in, pure `Float?` out, so it's `swift test`-able without the metallib
//  wall.
//
//  Signed: Kev + claude-fable-5, 2026-07-31, Confidence 0.85 (arithmetic pinned by
//  a regression test against AvatarView's exact call shape), Prior: Unknown

public enum WindowFit {
    /// The scale factor that fits `contentWidth`×`contentHeight` (a content's own
    /// designed/measured size, in the same world units as the bounds) into
    /// `boundsWidth`×`boundsHeight` (the window's scene-space extents), keeping
    /// aspect ratio (the tighter of the two axes wins) and reserving `headroom`
    /// as a final multiplier (e.g. 0.9 keeps a 10% margin so the content never
    /// kisses the window edge).
    ///
    /// Returns `nil` when the content has no measurable extent, or when the
    /// bounds are degenerate (NaN/zero/negative) — the caller's job is to skip
    /// the fit that tick and try again next frame (a resize in progress, a
    /// content-not-loaded-yet state), never to apply a garbage scale.
    public static func scale(
        contentWidth: Float,
        contentHeight: Float,
        boundsWidth: Float,
        boundsHeight: Float,
        headroom: Float
    ) -> Float? {
        guard contentWidth > 0, contentHeight > 0 else { return nil }
        let fit = min(boundsWidth / contentWidth, boundsHeight / contentHeight) * headroom
        guard fit.isFinite, fit > 0 else { return nil }
        return fit
    }
}
