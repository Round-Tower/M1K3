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
//

public enum CompanionDefaults {
    /// Persisted avatar choice. Empty string (default) = the pixel face; otherwise
    /// a `CompanionSpec` id (e.g. "Fox") or the constellation sentinel below.
    public static let companionKey = "voiceMode.companion"

    /// Sentinel `companionKey` value selecting the live 3D memory constellation
    /// (procedural, not a USDZ creature). Distinct from "" (pixel face) and any
    /// spec id. Only the macOS surface renders it today; the mobile resolver
    /// treats it as the pixel face until the constellation canvas is ported.
    public static let constellationID = "memory-constellation"

    /// Shading style for 3D creature companions — a `CompanionShadingStyle`
    /// rawValue (off / phosphor / cel). Default off (the baked textures).
    public static let shadingStyleKey = "companion.shadingStyle"

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
