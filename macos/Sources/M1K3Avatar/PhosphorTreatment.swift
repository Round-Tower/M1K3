//
//  PhosphorTreatment.swift
//  M1K3Avatar
//
//  The pure, reactive look of the companion's phosphor skin — colour + fresnel
//  power that the RealityKit surface shader (M1K3App/Phosphor.metal) reads via a
//  material custom_parameter. Mirrors GlyphTreatment / ChatBackdropTreatment: the
//  avatar responds to M1K3's state (calm green at rest, brighter while speaking,
//  cooler blue while it thinks) without the view owning any of that logic.
//
//  Value-only + packed into a SIMD4 so the render glue is a one-liner and the
//  decision is unit-tested off-device (the shader itself is verify-at-⌘R).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.9 (per-activity mapping
//  + packing pinned by tests; the on-screen glow is verify-at-⌘R). Prior: Unknown.
//  Review: Kev + claude-opus-5.5, 2026-10-11 — adds the seasonal wardrobe (`phosphorTreatment(season:)`,
//  Halloween pumpkin/ember/violet); a nil season is byte-identical. Confidence 0.85 (glow is verify-by-launch).
//

import simd

/// Colour + fresnel power for the phosphor surface shader. RGB is the emissive
/// phosphor tint; `fresnelPower` controls how tightly the glow hugs the edges
/// (higher = thinner rim).
public struct PhosphorTreatment: Equatable, Sendable {
    public var red: Float
    public var green: Float
    public var blue: Float
    public var fresnelPower: Float

    public init(red: Float, green: Float, blue: Float, fresnelPower: Float) {
        self.red = red
        self.green = green
        self.blue = blue
        self.fresnelPower = fresnelPower
    }

    /// Packed for the CustomMaterial `custom.value` (xyz = colour, w = power) — the
    /// exact layout `Phosphor.metal` reads from `custom_parameter()`.
    public var customValue: SIMD4<Float> {
        SIMD4(red, green, blue, fresnelPower)
    }

    /// Resting green-white — the CRT phosphor default.
    public static let calm = PhosphorTreatment(red: 0.45, green: 1.0, blue: 0.72, fresnelPower: 3.0)
    /// Brighter, tighter rim while speaking — the creature "lights up".
    public static let speaking = PhosphorTreatment(red: 0.60, green: 1.0, blue: 0.85, fresnelPower: 2.2)
    /// Cooler blue, softer rim while thinking/working — calmer, recedes a touch.
    public static let thinking = PhosphorTreatment(red: 0.40, green: 0.70, blue: 1.0, fresnelPower: 3.4)
    /// Attentive teal while listening.
    public static let listening = PhosphorTreatment(red: 0.50, green: 1.0, blue: 0.80, fresnelPower: 2.6)
}

public extension AvatarActivity {
    /// The phosphor look for each state — the reactive map the companion wears.
    var phosphorTreatment: PhosphorTreatment {
        switch self {
        case .idle, .error: .calm
        case .listening: .listening
        case .thinking, .generating: .thinking
        case .speaking: .speaking
        }
    }

    /// The phosphor look in `season`'s wardrobe; nil is today's exact `phosphorTreatment`.
    func phosphorTreatment(season: SeasonalLook?) -> PhosphorTreatment {
        guard let season else { return phosphorTreatment }
        return switch (season, self) {
        case (.halloween, .idle), (.halloween, .error): .halloweenCalm
        case (.halloween, .listening): .halloweenListening
        case (.halloween, .thinking), (.halloween, .generating): .halloweenThinking
        case (.halloween, .speaking): .halloweenSpeaking
        }
    }
}

public extension PhosphorTreatment {
    /// PUMPKIN #FF8A1F — the resting phosphor.
    static let halloweenCalm = PhosphorTreatment(red: 1.0, green: 0.541, blue: 0.122, fresnelPower: 3.0)
    /// EMBER #FFB347 — bright, tighter rim while speaking.
    static let halloweenSpeaking = PhosphorTreatment(red: 1.0, green: 0.702, blue: 0.278, fresnelPower: 2.2)
    /// VIOLET #9B5CFF — thinking.
    static let halloweenThinking = PhosphorTreatment(red: 0.608, green: 0.361, blue: 1.0, fresnelPower: 3.4)
    /// A warm amber between pumpkin and ember — listening.
    static let halloweenListening = PhosphorTreatment(red: 1.0, green: 0.62, blue: 0.20, fresnelPower: 2.6)
}
