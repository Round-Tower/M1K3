//
//  BackdropInk.swift
//  M1K3Avatar
//
//  How much ink the avatar backdrop's overlays lay down, per appearance. The
//  CRT pass (scanlines + vignette) and the chat's reading scrim were tuned on a
//  dark window and are drawn in BLACK: on dark they read as texture, on light
//  they turned the whole window a striped mid-grey and the tray, the bubbles
//  and the companion all sank into it (Kev, 2026-10-01, with a screenshot).
//  Dark keeps its numbers exactly; light gets a whisper of the texture and a
//  scrim that lightens behind the text instead of darkening.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-01, Confidence 0.75 (the split is
//  pinned; the light numbers are first-judged by eye at launch, tune here).
//  Prior: none (new file; dark's values were CRTOverlay's and ReadingScrim's).
//  Review: Kev + claude-fable-5.1, 2026-10-09 — adds the thinking rain's ink (`rain`): voice
//  mode now sits on the window's own glass, so the pale phosphor tints that were tuned on a
//  near-black gradient need a stronger, darker ink on light. Dark is byte-identical
//  (0.5 cap, tints untouched). Confidence 0.7 (light numbers are first-judged, by eye at launch).
//

/// Plain numbers for the views to draw with; no SwiftUI here.
public struct BackdropInk: Equatable, Sendable {
    /// Each scanline's opacity (black ink).
    public let scanlineOpacity: Double
    /// The corner vignette's outer opacity (black ink).
    public let vignetteOpacity: Double
    /// True: the reading scrim darkens (black). False: it lightens (white).
    public let scrimIsDark: Bool
    /// The scrim's opacity at its four stops.
    public let scrim: Scrim
    /// The thinking rain's ink (voice mode's phosphor text).
    public let rain: Rain

    /// How the rain paints its source tints: the line's own opacity is scaled by
    /// `opacityScale`, and the tint is mixed toward black by `tintDarkening` (0 = as authored).
    public struct Rain: Equatable, Sendable {
        public let opacityScale: Double
        public let tintDarkening: Double

        public init(opacityScale: Double, tintDarkening: Double) {
            self.opacityScale = opacityScale
            self.tintDarkening = tintDarkening
        }
    }

    /// Opacity at the top, at 28 %, at 72 % and at the bottom of the window.
    public struct Scrim: Equatable, Sendable {
        public let top: Double
        public let upper: Double
        public let lower: Double
        public let bottom: Double

        public init(top: Double, upper: Double, lower: Double, bottom: Double) {
            self.top = top
            self.upper = upper
            self.lower = lower
            self.bottom = bottom
        }
    }

    public init(isDark: Bool) {
        if isDark {
            scanlineOpacity = 0.20
            vignetteOpacity = 0.38
            scrimIsDark = true
            scrim = Scrim(top: 0.18, upper: 0.04, lower: 0.04, bottom: 0.22)
            rain = Rain(opacityScale: 0.5, tintDarkening: 0)
        } else {
            scanlineOpacity = 0.06
            vignetteOpacity = 0.10
            scrimIsDark = false
            scrim = Scrim(top: 0.30, upper: 0.08, lower: 0.10, bottom: 0.45)
            rain = Rain(opacityScale: 0.8, tintDarkening: 0.6)
        }
    }
}
