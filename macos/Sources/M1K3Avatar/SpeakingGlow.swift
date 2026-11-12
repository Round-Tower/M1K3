//
//  SpeakingGlow.swift
//  M1K3Avatar
//
//  Whether a companion glows, and how: on while M1K3's voice is speaking, off
//  otherwise. The pulse itself runs on the shader's own clock (Phosphor.metal),
//  so nothing here ticks: the app writes a level only when it changes, eased over
//  a few steps at the start and end of speech.
//
//  The decisions live here so they can be tested; the look is verify-by-launch.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.75 (the policy is
//  pinned; the numbers are a first pick judged on one Mac). Prior: Unknown.
//  Context: Kev, 2026-11-12: "adding one for when the voice synth is speaking - so
//  the Phosphor fox almost glows - and could do something similar for the other
//  Avatars". His picks: a pulse first, the voice's real loudness later; hot
//  lattice plus a soft halo; white at rest.
//  Open: the level is on/off with a pulse. Feeding it the voice's loudness (an
//  envelope from Kokoro's audio) is the follow-up; the level is where it lands.

import simd

public struct SpeakingGlow: Equatable, Sendable {
    /// How strong the glow is at rest in this state: 0 is off, 1 is full.
    public let level: Float
    /// Whether the shader animates it (a breathing pulse, a light along the lattice).
    public let pulses: Bool

    public init(level: Float, pulses: Bool) {
        self.level = level
        self.pulses = pulses
    }

    public static let off = SpeakingGlow(level: 0, pulses: false)
    /// Speaking: full, and alive.
    public static let speaking = SpeakingGlow(level: 1, pulses: true)
    /// Speaking where motion is unwelcome (Reduce Motion, a parked creature): dimmer and still.
    public static let steady = SpeakingGlow(level: 0.6, pulses: false)

    public var isOn: Bool {
        level > 0
    }

    public static func resolve(
        activity: AvatarActivity, enabled: Bool, reduceMotion: Bool, paused: Bool
    ) -> SpeakingGlow {
        guard enabled, activity == .speaking else { return .off }
        return reduceMotion || paused ? .steady : .speaking
    }

    /// The halo shader's `custom_parameter()` for one shell: x is the level right now, negative
    /// when the glow must hold still; y is the shell's width in the mesh's own units; z is how
    /// opaque that shell is at full level.
    public func customValue(level: Float, shell: Shell) -> SIMD4<Float> {
        SIMD4(pulses ? level : -level, shell.width, shell.opacity, 0)
    }

    /// One layer of the halo: a copy of the creature's body pushed out by `width`.
    public struct Shell: Equatable, Sendable {
        public let width: Float
        public let opacity: Float
    }

    /// The halo is nested shells, each wider and fainter than the last, so the edge falls away
    /// in steps. One hard shell reads as a white cut-out behind the creature (seen 2026-11-12).
    /// Widths are fractions of the creature's size; the list is innermost first.
    static let shellProfile: [(fraction: Float, opacity: Float)] = [
        (0.004, 0.30), (0.009, 0.22), (0.015, 0.15), (0.022, 0.10), (0.030, 0.06),
    ]

    /// The shells for a creature whose mesh is `extent` across, in the mesh's own units.
    public static func shells(forExtent extent: Float) -> [Shell] {
        shellProfile.map { Shell(width: max(0, extent) * $0.fraction, opacity: $0.opacity) }
    }

    /// The levels to step through from `from` to `to`: an ease-out that lands exactly
    /// on the target. One step under Reduce Motion; none when already there.
    public static func ramp(from: Float, to: Float, reduceMotion: Bool) -> [Float] {
        guard from != to else { return [] }
        guard !reduceMotion else { return [to] }
        return (1 ... rampSteps).map { step in
            guard step < rampSteps else { return to }
            let progress = Float(step) / Float(rampSteps)
            let eased = 1 - (1 - progress) * (1 - progress)
            return from + (to - from) * eased
        }
    }

    static let rampSteps = 6
    /// The pause between two ramp steps; six of them fade the glow in about a quarter second.
    public static let rampInterval: Duration = .milliseconds(40)

    /// White by default (Kev turned down a permanent tint); the treatment's colour under phosphor.
    public static func colour(style: CompanionShadingStyle, treatment: PhosphorTreatment) -> SIMD3<Float> {
        style == .phosphor ? SIMD3(treatment.red, treatment.green, treatment.blue) : SiteFoxPaint.siteWhite
    }
}
