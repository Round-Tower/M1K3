//
//  CompanionSpec.swift
//  M1K3Avatar
//
//  A 3D companion creature — the OPT-IN avatar skin for voice mode, sibling to
//  the procedural pixel face (which stays M1K3's default brand face everywhere).
//  Pure data: the creature's identity, its display scale, and which animation
//  dialect its converted USDZ clips speak. No RealityKit here — playback lives in
//  the app's CompanionAvatarView (verify-by-launch); this layer is `swift test`'d.
//
//  Assets are per-clip USDZs (one mesh per file, animation harvested by filename —
//  clip names die in USD, the FILENAME is the clip identity; see scratch/usdz-probe).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-11, Confidence 0.7 (mapping is by-design;
//  per-companion scale is a by-eye nudge on top of the view's auto-fit), Prior: Unknown
//
//  Review: Kev + claude-opus-5, 2026-07-26 — added `phosphorFox`, the site's hero
//  look made real in Blender (tools/companion-pipeline/build_phosphor_fox.py). A pure
//  data addition: the wireframe lattice is BAKED GEOMETRY, so no shader, renderer or
//  picker change was needed. Gated `rkprobe --tick` 3/3 MOVES + 2187 tests green;
//  the on-screen result is verify-at-⌘R.

/// The two animation vocabularies in M1K3's companion lineup. The Quaternius
/// "Quirky Series" pack shares a rich clip set (Idle_A/Idle_B/Walk/Run/Jump/Fear/…);
/// the Khronos Fox speaks a leaner three-clip dialect (Survey/Walk/Run). A dialect
/// maps every abstract `CompanionGait` onto a clip it actually ships, collapsing
/// where a clip is missing — so the mapper can never name a clip that isn't bundled.
public enum CompanionDialect: Equatable, Sendable {
    case quaternius
    case fox
    /// Quaternius rig, water-native accent: creatures that should never be
    /// seen walking. Moving = swimming; a beat of delight = the jet burst.
    case aquatic
    /// Quaternius rig, air-native accent: moving = on the wing; delight = a
    /// happy hop.
    case avian

    public func clipName(for gait: CompanionGait) -> String {
        switch self {
        case .quaternius:
            switch gait {
            case .rest: "Idle_A"
            case .alert: "Idle_B"
            case .move: "Walk"
            case .react: "Jump"
            case .distress: "Fear"
            }
        case .fox:
            switch gait {
            case .rest, .alert: "Survey" // no distinct alert clip — survey reads as attentive
            case .move: "Walk"
            case .react, .distress: "Run" // no jump/fear — run carries both energy and agitation
            }
        case .aquatic:
            switch gait {
            case .rest: "Idle_A"
            case .alert: "Idle_B"
            case .move: "Swim" // speaking/generating = gliding, never trudging
            case .react: "Fly" // the squid jet — delight as propulsion
            case .distress: "Fear"
            }
        case .avian:
            switch gait {
            case .rest: "Idle_A"
            case .alert: "Idle_B" // attentive head-tilt while listening/thinking
            case .move: "Fly" // a bird with something to say takes wing
            case .react: "Jump" // the happy hop
            case .distress: "Fear"
            }
        }
    }
}

/// One installable companion. `clips` is the exact set of per-clip USDZ filenames
/// bundled for it (without the `.usdz` extension); `idleClip` is the resting clip
/// loaded first (and the one whose file carries the mesh the others bind onto).
public struct CompanionSpec: Equatable, Sendable, Identifiable {
    public let id: String
    public let displayName: String
    public let dialect: CompanionDialect
    public let clips: [String]
    /// By-eye fine-tune multiplied on top of the view's bounding-box auto-fit.
    public let scale: Float

    public init(id: String, displayName: String, dialect: CompanionDialect, clips: [String], scale: Float = 1.0) {
        self.id = id
        self.displayName = displayName
        self.dialect = dialect
        self.clips = clips
        self.scale = scale
    }

    /// The resting clip — what the companion idles on and the mesh-bearing file.
    public var idleClip: String {
        dialect.clipName(for: .rest)
    }

    // MARK: - Catalogue

    /// v1 ship companion — the site's hero, the leanest assets (~390 KB), and the
    /// fox dialect's special case proven first.
    public static let fox = CompanionSpec(
        id: "Fox",
        displayName: "Fox",
        dialect: .fox,
        clips: ["Survey", "Walk", "Run"]
    )

    /// Every known companion. The voice-mode picker self-limits to the subset that
    /// actually ships assets (CompanionAssets.isInstalled), so adding a creature is
    /// a spec line here plus its USDZ folder — no picker wiring.
    ///
    /// The companion-jam pair (2026-07-09): a squid and a sparrow, each with a
    /// nature-true dialect (aquatic swims/jets, avian flies/hops). Clips list
    /// = the full exported set; bundled ⊋ emittable is fine (Walk/Run/Sit/
    /// Clicked/Swim-for-the-bird are just bytes until a dialect wants them).
    public static let inkfish = CompanionSpec(
        id: "Inkfish",
        displayName: "Inkfish",
        dialect: .aquatic,
        clips: ["Idle_A", "Idle_B", "Walk", "Run", "Jump", "Fear", "Sit", "Clicked", "Swim", "Fly"]
    )

    public static let sparrow = CompanionSpec(
        id: "Sparrow",
        displayName: "Sparrow",
        dialect: .avian,
        clips: ["Idle_A", "Idle_B", "Walk", "Run", "Jump", "Fear", "Sit", "Clicked", "Swim", "Fly"]
    )

    /// Gecko's comeback (2026-07-17). Dropped 2026-06-21 when her converted
    /// clips froze on-device — later root-caused in #20 as two stacked traps
    /// (a SkelRoot prim named `Rig`, which RealityKit refuses to bind, and the
    /// Quirky pack's 11-frame compressed takes), both fixed in the pipeline.
    /// Re-exported with --retime 4; rkprobe --tick verified 8/8 clips MOVES.
    /// First creature to speak the plain `.quaternius` dialect.
    public static let gecko = CompanionSpec(
        id: "Gecko",
        displayName: "Gecko",
        dialect: .quaternius,
        clips: ["Idle_A", "Idle_B", "Walk", "Run", "Jump", "Fear", "Sit", "Clicked"]
    )

    /// Colobus (2026-07-17, same pipeline run as the gecko comeback):
    /// re-exported with --retime 4, rkprobe --tick 8/8 MOVES.
    public static let colobus = CompanionSpec(
        id: "Colobus",
        displayName: "Colobus",
        dialect: .quaternius,
        clips: ["Idle_A", "Idle_B", "Walk", "Run", "Jump", "Fear", "Sit", "Clicked"]
    )

    /// The Phosphor Fox (2026-07-26) — the site's hero look, made real in Blender.
    ///
    /// m1k3.app renders its fox as a dark body plus an *additive glowing wireframe
    /// shell* (`site/index.html` → `phosphorise()`): a see-through triangle lattice
    /// you can look straight through to the far legs. The app's `.phosphor` shading
    /// style is a different animal — a fresnel rim-glow, which lights the silhouette
    /// but has no interior lattice — so the two never matched.
    ///
    /// A shader can't close that gap honestly: a surface shader only draws on front
    /// faces over an opaque body, so the see-through quality (the thing that makes
    /// the site read as a wireframe sculpture) is unreachable. So the lattice is
    /// **real geometry** instead — Blender welds the GLB's triangle soup back into a
    /// closed manifold (V−E+F = 2, 864 clean edges, no doubles) and a Wireframe
    /// modifier turns every edge into a tube, baked at glTF export. Vertex groups
    /// survive the modifier, so one skeleton drives body + lattice together.
    ///
    /// Ships as its OWN creature rather than a re-skin: the look is in the asset, so
    /// it needs no shader, and `.off` (baked) shading reproduces the site exactly.
    /// Same Khronos rig → same `.fox` dialect, same three clips.
    public static let phosphorFox = CompanionSpec(
        id: "PhosphorFox",
        displayName: "Phosphor Fox",
        dialect: .fox,
        clips: ["Survey", "Walk", "Run"]
    )

    public static let all: [CompanionSpec] = [.fox, .inkfish, .sparrow, .gecko, .colobus, .phosphorFox]

    /// Resolve a persisted picker id to a spec. The empty string (and any unknown
    /// id) means "pixel face" — the default — and returns nil.
    public static func named(_ id: String) -> CompanionSpec? {
        all.first { $0.id == id }
    }
}
