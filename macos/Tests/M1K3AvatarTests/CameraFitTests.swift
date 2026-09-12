//
//  CameraFitTests.swift
//  M1K3AvatarTests
//
//  Pins `CameraFit.distance`: the perspective-camera distance that shows a
//  creature's whole posed silhouette in a view of any aspect. A perspective
//  field of view is VERTICAL, so a broadside fox in a square notch slot or a
//  portrait phone clipped horizontally at the old fixed distance — the fox's
//  head off the edge on both (Kev, 2026-09-12).
//
//  Signed: Kev + claude-fable-5.1, 2026-09-12, Confidence 0.85 (trig pinned by
//  hand-computed cases; the felt framing is verify-by-launch), Prior: Unknown
//

import Foundation
@testable import M1K3Avatar
import Testing

struct CameraFitTests {
    /// tan(30°) — the half-angle of the 60° default vertical field of view.
    private let tanHalf: Float = 0.577_350_3

    @Test("a square view fits the wider of width and height")
    func squareViewFitsTheLargerDimension() throws {
        // 1.7 wide × 0.9 tall fox, square view, 25% headroom: width rules.
        let d = try #require(CameraFit.distance(
            contentWidth: 1.7, contentHeight: 0.9, viewWidth: 72, viewHeight: 72,
            verticalFOVDegrees: 60, headroom: 1.25
        ))
        #expect(abs(d - (0.85 * 1.25) / tanHalf) < 0.001) // ≈ 1.840
    }

    @Test("a portrait view widens the distance so the creature's length fits the narrow side")
    func portraitViewFitsWidth() throws {
        let d = try #require(CameraFit.distance(
            contentWidth: 1.7, contentHeight: 0.9, viewWidth: 390, viewHeight: 844,
            verticalFOVDegrees: 60, headroom: 1.25
        ))
        // Horizontal half-tangent is tanHalf × aspect (0.462) → 1.0625 / 0.2668 ≈ 3.98.
        #expect(abs(d - (0.85 * 1.25) / (tanHalf * (390.0 / 844.0))) < 0.01)
        #expect(d > 3.9 && d < 4.05)
    }

    @Test("a wide view lets height rule")
    func wideViewFitsHeight() throws {
        let d = try #require(CameraFit.distance(
            contentWidth: 1.7, contentHeight: 1.7, viewWidth: 900, viewHeight: 300,
            verticalFOVDegrees: 60, headroom: 1.0
        ))
        #expect(abs(d - 0.85 / tanHalf) < 0.001) // ≈ 1.472 — width would need only 0.49
    }

    @Test("degenerate inputs refuse rather than place the camera at nonsense")
    func degenerateInputsRefuse() {
        #expect(CameraFit.distance(contentWidth: 0, contentHeight: 1, viewWidth: 10, viewHeight: 10, verticalFOVDegrees: 60, headroom: 1) == nil)
        #expect(CameraFit.distance(contentWidth: 1, contentHeight: 1, viewWidth: 0, viewHeight: 10, verticalFOVDegrees: 60, headroom: 1) == nil)
        #expect(CameraFit.distance(contentWidth: 1, contentHeight: 1, viewWidth: 10, viewHeight: 10, verticalFOVDegrees: 0, headroom: 1) == nil)
        #expect(CameraFit.distance(contentWidth: 1, contentHeight: 1, viewWidth: 10, viewHeight: 10, verticalFOVDegrees: 180, headroom: 1) == nil)
        #expect(CameraFit.distance(contentWidth: 1, contentHeight: 1, viewWidth: .nan, viewHeight: 10, verticalFOVDegrees: 60, headroom: 1) == nil)
    }
}
