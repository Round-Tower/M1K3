//
//  CameraFit.swift
//  M1K3Avatar
//
//  The pure perspective-camera maths for the macOS/iOS creature surfaces: how
//  far back a camera with a VERTICAL field of view must sit to show a posed
//  silhouette whole in a view of a given aspect. The fixed z 2.4 that framed
//  the main Mac window clipped the fox's head in the 72px notch slot and on a
//  portrait phone — the horizontal view is only `tan(fov/2) × aspect` wide,
//  and a broadside creature is long. Companion to `WindowFit` (the visionOS
//  camera-less scale-fit); same rule — pure `Float` in, `Float?` out, no
//  RealityKit, `swift test`-able.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-12, Confidence 0.85 (the trig is
//  pinned; the felt framing per surface is verify-by-launch), Prior: Unknown
//

import Foundation

public enum CameraFit {
    /// The distance along the camera's axis at which `contentWidth` ×
    /// `contentHeight` (the creature's posed extents) fits a `viewWidth` ×
    /// `viewHeight` view under a camera with `verticalFOVDegrees`, with
    /// `headroom` as a multiplier on the content (1.25 = a quarter margin).
    /// nil for a non-measurable content, an unusable view, or a field of view
    /// outside (0, 180).
    public static func distance(
        contentWidth: Float,
        contentHeight: Float,
        viewWidth: Float,
        viewHeight: Float,
        verticalFOVDegrees: Float,
        headroom: Float
    ) -> Float? {
        guard contentWidth > 0, contentHeight > 0, headroom > 0 else { return nil }
        guard viewWidth.isFinite, viewHeight.isFinite, viewWidth > 0, viewHeight > 0 else { return nil }
        guard verticalFOVDegrees > 0, verticalFOVDegrees < 180 else { return nil }
        let tanHalf = tan(verticalFOVDegrees * .pi / 360)
        let aspect = viewWidth / viewHeight
        let forHeight = (contentHeight / 2 * headroom) / tanHalf
        let forWidth = (contentWidth / 2 * headroom) / (tanHalf * aspect)
        let distance = max(forHeight, forWidth)
        guard distance.isFinite, distance > 0 else { return nil }
        return distance
    }
}
