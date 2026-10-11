//
//  CompanionDefaults.swift
//  M1K3Avatar
//
//  The UserDefaults spellings for the avatar/companion choice, hoisted into the
//  package so BOTH composition roots share one source of truth: the macOS
//  `AppEnvironment` (AppKit-bound, Mac-only) and the iOS/visionOS `AppCore`. Before
//  this, the keys lived on `AppEnvironment`, so the shared `CompanionAvatarView`
//  couldn't compile for the mobile shell (it referenced a Mac-only type). Same
//  string VALUES as the Mac always used — a persisted choice reads back identically.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-28, Confidence 0.9 (pure constants;
//  values preserved verbatim from AppEnvironment+VoiceMode so no migration).
//  Prior: AppEnvironment+VoiceMode (Kev + claude-opus-4-8 lineage).
//  Review: Kev + claude-opus-5.5, 2026-10-11 — adds `seasonalLooksKey` (the opt-out). Confidence 0.9.
//  Review: Kev + claude-opus-5.5, 2026-10-11 — adds `houseCompanion` / `houseShading` / `registeredDefaults`:
//  the Phosphor Fox in its white lattice is the default on Mac and iOS (Kev, TestFlight 499), one source
//  for both entry points and every @AppStorage fallback. Confidence 0.85.
//

public enum CompanionDefaults {
    /// Persisted avatar choice. Empty string = the pixel face (an explicit pick);
    /// otherwise a `CompanionSpec` id (e.g. "Colobus") or the constellation
    /// sentinel below. A never-touched install resolves to `houseCompanion`
    /// through `registeredDefaults`.
    public static let companionKey = "voiceMode.companion"

    /// The house look (Kev, TestFlight 499, 2026-10-11): the Phosphor Fox in its
    /// white baked lattice, as on every store plate.
    public static let houseCompanion = CompanionSpec.phosphorFox

    /// The house shading: `.off` keeps the baked white lattice untouched.
    public static let houseShading = CompanionShadingStyle.off

    /// What both composition roots hand to `UserDefaults.register(defaults:)`.
    /// Registered, never written: an explicit persisted choice (any face, any
    /// skin, the pixel face's "") always wins; only never-touched keys resolve here.
    public static let registeredDefaults: [String: String] = [
        companionKey: houseCompanion.id,
        shadingStyleKey: houseShading.rawValue,
    ]

    /// Sentinel `companionKey` value selecting the live 3D memory constellation
    /// (procedural, not a USDZ creature). Distinct from "" (pixel face) and any
    /// spec id. Only the macOS surface renders it today; the mobile resolver
    /// treats it as the pixel face until the constellation canvas is ported.
    public static let constellationID = "memory-constellation"

    /// Shading style for 3D creature companions — a `CompanionShadingStyle`
    /// rawValue (off / phosphor / cel). House default `.off` (the baked textures).
    public static let shadingStyleKey = "companion.shadingStyle"

    /// Opt-out for seasonal looks (Halloween first). Bool, default true.
    public static let seasonalLooksKey = "avatar.seasonalLooks"

    /// Sentinel `companionKey` value meaning NO avatar at all — the shell shows
    /// just the conversation (no hero face, no live backdrop, no preview).
    /// Distinct from "" (pixel face). Only the mobile shell offers it today; the
    /// Mac resolver treats it like any unknown id (pixel-face fallback), so a
    /// synced/stale value can never blank a surface that doesn't support it.
    public static let noneID = "avatar-none"

    /// True when the persisted choice means "show no avatar". ONLY the explicit
    /// none sentinel hides — an unknown/retired companion id falls back to the
    /// pixel face rather than a blank surface.
    public static func hidesAvatar(_ persisted: String) -> Bool {
        persisted == noneID
    }
}
