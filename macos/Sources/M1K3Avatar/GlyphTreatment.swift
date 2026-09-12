//
//  GlyphTreatment.swift
//  M1K3Avatar
//
//  How the menu-bar glyph should reflect what M1K3 is doing: a calm "M" when
//  idle, a pulsing dot while it thinks, a red dot while recording, a soft glow
//  while speaking. This is the PURE decision (unit-tested); the menu-bar label
//  view applies it. Recording is a separate signal from avatar activity (it's
//  `env.isRecording`), so it's passed in and takes precedence — a red "I'm
//  capturing audio" dot must never be masked by whatever the avatar is doing.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-16, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-12 — `breathes`: the glyph itself animates while a
//  model loads (launch snag list). Loading is its own signal, like recording. Confidence now 0.85.

/// A semantic styling for the status-bar glyph's overlay indicator. Colour is a
/// name (not a SwiftUI Color) so this type stays dependency-free and testable.
public struct GlyphTreatment: Equatable, Sendable {
    public enum Dot: Equatable, Sendable {
        /// No overlay — the bare glyph.
        case none
        /// An attention dot that animates (thinking / generating).
        case pulsing
        /// A solid "recording" dot.
        case recording
        /// A soft glow around the glyph (speaking).
        case glow
    }

    public var dot: Dot
    /// Semantic colour name the view maps to a Color ("accent" | "red" | nil).
    public var dotColorName: String?
    /// Whether the view should animate the indicator (best-effort in the menu bar).
    public var pulses: Bool
    /// Whether the GLYPH itself breathes — a model (brain, voice, recogniser) is
    /// loading. Independent of the dot: loading is a machine state, the dot is
    /// what M1K3 is doing, and both can be true at once.
    public var breathes: Bool

    public init(dot: Dot, dotColorName: String?, pulses: Bool, breathes: Bool = false) {
        self.dot = dot
        self.dotColorName = dotColorName
        self.pulses = pulses
        self.breathes = breathes
    }

    public static let calm = GlyphTreatment(dot: .none, dotColorName: nil, pulses: false)
}

public extension AvatarActivity {
    /// The glyph styling for this activity. `isRecording` (a separate signal from
    /// `env.isRecording`) wins over everything else — capture status is the most
    /// important thing to surface.
    /// `isLoading` (a brain / voice / recogniser model warming) makes the glyph
    /// itself breathe on top of whatever dot the activity earns.
    func glyphTreatment(isRecording: Bool = false, isLoading: Bool = false) -> GlyphTreatment {
        var treatment = baseGlyphTreatment(isRecording: isRecording)
        treatment.breathes = isLoading
        return treatment
    }

    private func baseGlyphTreatment(isRecording: Bool) -> GlyphTreatment {
        if isRecording {
            return GlyphTreatment(dot: .recording, dotColorName: "red", pulses: true)
        }
        switch self {
        case .idle:
            return .calm
        case .thinking, .generating:
            return GlyphTreatment(dot: .pulsing, dotColorName: "accent", pulses: true)
        case .listening:
            // Mic open but not (yet) the call recorder — an attentive accent dot.
            return GlyphTreatment(dot: .pulsing, dotColorName: "accent", pulses: true)
        case .speaking:
            return GlyphTreatment(dot: .glow, dotColorName: "accent", pulses: false)
        case .error:
            return GlyphTreatment(dot: .recording, dotColorName: "red", pulses: false)
        }
    }
}
