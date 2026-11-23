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
//  Review: Kev + claude-sonnet-5.5, 2026-10-22 — Flight Club palette (ice / beacon amber / instrument cyan / pale
//  gold). Resting is ICE, not cyan: a cyan rest reads as the default thinking blue. Confidence 0.8 (colours are
//  verify-by-launch; hue and rim power separate the four states, but ice white and pale gold are close in luminance,
//  so for colour-blind viewers the rim power and the clips carry part of the difference).
//
//  Review: Kev + claude-opus-5-5, 2026-10-22 — Kev gave creative control: the ice-white rest read as "a teal Fox",
//  not flight, on the Simulator. Night-flight lighting instead: taxiway blue rest, strobe white thinking (tightest rim),
//  beacon amber speaking, nav green listening. Tests pin the values and keep the rest well apart from the default
//  thinking blue. Confidence 0.75 (looked at on the Simulator; device Airplane Mode still owed).
//  Review: Kev + claude-opus-5-5, 2026-11-23 — the seasonal calendar's palettes: Christmas (candy red / gold / frost /
//  pine), Ramadan + Eid (lantern gold / warm white / moonlit indigo / tile turquoise, one palette), Nowruz (blossom /
//  sun / sky / sabzeh green), St Patrick's (shamrock / gold / white / tricolour orange). Every state of every look
//  clears the site Fox's 0.45 luminance floor and has four distinct states (SeasonalCalendarTests). Confidence 0.7
//  (hues chosen on paper, not yet looked at; verify-by-launch with `-seasonalLook <look>`).

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
        case (.flightClub, .idle), (.flightClub, .error): .flightCalm
        case (.flightClub, .listening): .flightListening
        case (.flightClub, .thinking), (.flightClub, .generating): .flightThinking
        case (.flightClub, .speaking): .flightSpeaking
        case (.christmas, .idle), (.christmas, .error): .christmasCalm
        case (.christmas, .listening): .christmasListening
        case (.christmas, .thinking), (.christmas, .generating): .christmasThinking
        case (.christmas, .speaking): .christmasSpeaking
        case (.ramadan, .idle), (.ramadan, .error), (.eid, .idle), (.eid, .error): .lanternCalm
        case (.ramadan, .listening), (.eid, .listening): .lanternListening
        case (.ramadan, .thinking), (.ramadan, .generating), (.eid, .thinking), (.eid, .generating): .lanternThinking
        case (.ramadan, .speaking), (.eid, .speaking): .lanternSpeaking
        case (.nowruz, .idle), (.nowruz, .error): .nowruzCalm
        case (.nowruz, .listening): .nowruzListening
        case (.nowruz, .thinking), (.nowruz, .generating): .nowruzThinking
        case (.nowruz, .speaking): .nowruzSpeaking
        case (.stPatricks, .idle), (.stPatricks, .error): .shamrockCalm
        case (.stPatricks, .listening): .shamrockListening
        case (.stPatricks, .thinking), (.stPatricks, .generating): .shamrockThinking
        case (.stPatricks, .speaking): .shamrockSpeaking
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

public extension PhosphorTreatment {
    // Offline AI Flight Club: night-flight lighting, so every state reads as "flight". Like Halloween's
    // violet, the season re-teaches the states: here BLUE is rest (runway blue, deeper and less green
    // than the default thinking #66B3FF) and thinking is the white strobe, so blue never means two things.

    /// RUNWAY BLUE #4A86FF — the resting phosphor: edge lights seen from the window at night, bright
    /// enough to read as a lattice line on the site Fox's black body (SiteFoxPaint's luminance floor).
    static let flightCalm = PhosphorTreatment(red: 0.290, green: 0.525, blue: 1.0, fresnelPower: 3.0)
    /// BEACON AMBER #FFB000 — bright, tighter rim while speaking, like a runway beacon.
    static let flightSpeaking = PhosphorTreatment(red: 1.0, green: 0.690, blue: 0.0, fresnelPower: 2.2)
    /// STROBE WHITE #F4F8FF — thinking: the tightest, brightest rim, like the wingtip strobe.
    static let flightThinking = PhosphorTreatment(red: 0.957, green: 0.973, blue: 1.0, fresnelPower: 4.0)
    /// NAV GREEN #39FF7A — listening, the starboard navigation light.
    static let flightListening = PhosphorTreatment(red: 0.224, green: 1.0, blue: 0.478, fresnelPower: 2.6)
}

public extension PhosphorTreatment {
    // Christmas / New Year: candy-cane red at rest (a deep holly red falls under the lattice floor), gold
    // speaking, frost thinking (the tightest rim, like Flight Club's strobe), pine listening.

    /// CANDY RED #FF5C66 — the resting phosphor.
    static let christmasCalm = PhosphorTreatment(red: 1.0, green: 0.361, blue: 0.40, fresnelPower: 3.0)
    /// TINSEL GOLD #FFD15C — speaking.
    static let christmasSpeaking = PhosphorTreatment(red: 1.0, green: 0.820, blue: 0.361, fresnelPower: 2.2)
    /// FROST #DEEBFF — thinking.
    static let christmasThinking = PhosphorTreatment(red: 0.871, green: 0.922, blue: 1.0, fresnelPower: 4.0)
    /// PINE #1FB05A — listening.
    static let christmasListening = PhosphorTreatment(red: 0.122, green: 0.690, blue: 0.353, fresnelPower: 2.6)
}

public extension PhosphorTreatment {
    // Ramadan and Eid share one palette: lantern light at rest, no costume.

    /// LANTERN GOLD #FFC247 — the resting phosphor.
    static let lanternCalm = PhosphorTreatment(red: 1.0, green: 0.761, blue: 0.278, fresnelPower: 3.0)
    /// WARM WHITE #FFF1D6 — speaking.
    static let lanternSpeaking = PhosphorTreatment(red: 1.0, green: 0.945, blue: 0.839, fresnelPower: 2.2)
    /// MOONLIT INDIGO #807AFF — thinking.
    static let lanternThinking = PhosphorTreatment(red: 0.502, green: 0.478, blue: 1.0, fresnelPower: 3.4)
    /// TILE TURQUOISE #2EC4B6 — listening.
    static let lanternListening = PhosphorTreatment(red: 0.180, green: 0.769, blue: 0.714, fresnelPower: 2.6)
}

public extension PhosphorTreatment {
    // Nowruz: spring. Blossom at rest, so it never reads as the default green.

    /// BLOSSOM #FF7DB5 — the resting phosphor.
    static let nowruzCalm = PhosphorTreatment(red: 1.0, green: 0.490, blue: 0.710, fresnelPower: 3.0)
    /// SPRING SUN #FFD84D — speaking.
    static let nowruzSpeaking = PhosphorTreatment(red: 1.0, green: 0.847, blue: 0.302, fresnelPower: 2.2)
    /// SKY #4FD1E8 — thinking.
    static let nowruzThinking = PhosphorTreatment(red: 0.310, green: 0.820, blue: 0.910, fresnelPower: 3.4)
    /// SABZEH GREEN #7BD84A — listening, the sprouted wheat on the table.
    static let nowruzListening = PhosphorTreatment(red: 0.482, green: 0.847, blue: 0.290, fresnelPower: 2.6)
}

public extension PhosphorTreatment {
    // St Patrick's: shamrock at rest, and the tricolour's white and orange for thinking and listening.

    /// SHAMROCK #19C25B — the resting phosphor, deeper than the default mint.
    static let shamrockCalm = PhosphorTreatment(red: 0.098, green: 0.761, blue: 0.357, fresnelPower: 3.0)
    /// GOLD #FFC93C — speaking, the pot at the end of it.
    static let shamrockSpeaking = PhosphorTreatment(red: 1.0, green: 0.788, blue: 0.235, fresnelPower: 2.2)
    /// WHITE #F2FFF5 — thinking.
    static let shamrockThinking = PhosphorTreatment(red: 0.949, green: 1.0, blue: 0.961, fresnelPower: 4.0)
    /// TRICOLOUR ORANGE #FF8C2B — listening.
    static let shamrockListening = PhosphorTreatment(red: 1.0, green: 0.549, blue: 0.169, fresnelPower: 2.6)
}
