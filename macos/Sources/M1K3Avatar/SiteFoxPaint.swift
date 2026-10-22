//
//  SiteFoxPaint.swift
//  M1K3Avatar
//
//  The site Fox in the app: solid black triangles under the baked lattice, as m1k3.app draws it
//  (Kev, 2026-10-22: "go with the site fox, it's iconic"). The Phosphor Fox ships the site's two
//  parts (`build_phosphor_fox.py`: body 0x111111, lattice 0xe8e8e8), but its body is lit PBR
//  (roughness .55, metallic .25), so the app's lighting washed it to grey. The app now paints the
//  body unlit black and the lattice unlit in a colour this type picks: the site's white out of
//  season, the treatment's colour under phosphor, which is what a season wears (`wearing(_:)`), so
//  Halloween is a pumpkin lattice and Flight Club a runway-blue one, reacting to the activity.
//
//  RealityKit merges the skinned Fox into ONE ModelEntity whose mesh PARTS keep the prim names
//  (fox1 = body, slot 0; fox_wire_mesh = lattice, slot 1 — read off the shipped USDZ in a Simulator
//  log), so the glue matches parts by name, not entities. Other companions carry no lattice part
//  and never get this paint. Cel keeps its own texture shader.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-22, Confidence 0.85 (pure rule pinned in
//  SiteFoxPaintTests; the on-screen look was compared on the Simulator). Prior: none (new file).
//

public enum SiteFoxPaint {
    /// What a mesh part of the Fox is.
    public enum Role: Equatable, Sendable {
        case body
        case lattice
    }

    /// The site's lattice white, 0xe8e8e8.
    public static let siteWhite = SIMD3<Float>(0.91, 0.91, 0.91)

    /// Solid black: the site's triangles.
    public static let bodyColour = SIMD3<Float>(0, 0, 0)

    /// The lattice is the part baked as `fox_wire`; everything else is body.
    public static func role(ofPart id: String) -> Role {
        id.lowercased().contains("fox_wire") ? .lattice : .body
    }

    /// Whether a model with these mesh-part names gets the site paint under `style`: only a model
    /// that carries a lattice part, and only for the styles the paint stands in for (the default
    /// and phosphor). Cel reads the creature's own texture and keeps its shader.
    public static func applies(toParts ids: [String], style: CompanionShadingStyle) -> Bool {
        guard style != .cel else { return false }
        return ids.contains { role(ofPart: $0) == .lattice }
    }

    /// The lattice colour: the site's white by default; the treatment's colour under phosphor.
    public static func latticeColour(style: CompanionShadingStyle, treatment: PhosphorTreatment) -> SIMD3<Float> {
        style == .phosphor ? SIMD3(treatment.red, treatment.green, treatment.blue) : siteWhite
    }
}
