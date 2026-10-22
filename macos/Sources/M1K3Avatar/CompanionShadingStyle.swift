//
//  CompanionShadingStyle.swift
//  M1K3Avatar
//
//  How a 3D companion creature is shaded: its baked textures (off), or one of the
//  M1K3 surface-shader looks — phosphor (fresnel rim-glow) or cel (toon banding of
//  the creature's OWN texture). Each glow style maps to a Metal surface-shader
//  function compiled into the app's metallib (Phosphor.metal); the pure map lives
//  here so the picker + the render glue share one source of truth and it's
//  unit-tested off-device.
//
//  (A true interior wireframe needs a Blender-baked barycentric attribute — the
//  code-only fwidth(normal) trick only reads on flat-shaded normals, and our
//  companions are smoothed, so it's intentionally NOT offered. See PLAN.)
//
//  Signed: Kev + claude-opus-4-8, 2026-06-18, Confidence 0.9 (the style→function +
//  texture-preservation map is pinned by tests; the on-screen look is
//  verify-at-⌘R). Prior: Kev + claude-opus-4-8 (phosphor #46).
//  Review: Kev + claude-opus-5.5, 2026-10-11 — `wearing(_:)`: in season every style wears the
//  phosphor costume (the tint only exists in the phosphor shader, and the shading default is
//  .off, so without it most users would never see the Halloween look). Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-11 — the house shading is `.off` again
//  (`CompanionDefaults.houseShading`, the Phosphor Fox's white lattice); the `wearing(_:)` note above is
//  true as written. The `.phosphor` doc no longer calls itself "the default". Confidence 0.85.
//  Review: Kev + claude-sonnet-5.5, 2026-10-22 — `wearing(_:)` also covers Flight Club (any non-nil season), so the
//  shading pick is overridden while the device is offline in season, and returns when it is back online. Confidence 0.85.
//

public enum CompanionShadingStyle: String, CaseIterable, Identifiable, Sendable {
    /// The companion's own baked materials — no shader.
    case off
    /// Fresnel rim-glow over a near-black body (the site's look; an opt-in here).
    case phosphor
    /// Toon banding of the creature's own texture + ink silhouette.
    case cel

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .off: "Off (textured)"
        case .phosphor: "Phosphor"
        case .cel: "Cel"
        }
    }

    /// The surface-shader function name in the app's default.metallib, or nil for
    /// `.off` (keep the baked materials). Must match the `[[visible]]` entry points
    /// in Phosphor.metal.
    public var shaderFunctionName: String? {
        switch self {
        case .off: nil
        case .phosphor: "phosphorSurface"
        case .cel: "celSurface"
        }
    }

    /// Whether this style paints an M1K3 shader (vs leaving baked materials).
    public var usesShader: Bool {
        shaderFunctionName != nil
    }

    /// Whether the shader needs the creature's ORIGINAL textures (so the render
    /// glue builds the CustomMaterial FROM the baked material rather than blank).
    /// Cel adapts the fur texture; phosphor is a monochrome glow that ignores it.
    public var usesOriginalTexture: Bool {
        self == .cel
    }

    /// The style to paint while `season` is in: the costume IS the phosphor shader (its
    /// seasonal tint has nowhere else to live), so a season overrides the user's pick for
    /// its window; out of season the pick stands. The Seasonal looks opt-out is upstream
    /// (it makes `season` nil).
    public func wearing(_ season: SeasonalLook?) -> CompanionShadingStyle {
        season == nil ? self : .phosphor
    }
}
