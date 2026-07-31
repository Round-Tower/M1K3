//
//  AvatarView.swift
//  M1K3App
//
//  The companion avatar: a procedural pixel-cube FACE — a fixed LED-matrix of
//  RealityKit cubes (FaceGrid) whose brightness is recomputed every frame by the
//  pure FaceExpression model. Lighting the right cubes "draws" two pupils that
//  blink/look and a mouth that curves with emotion and opens when M1K3 speaks. No
//  asset file, no USDZ — fully in code, on-brand with the Silkscreen pixel look.
//
//  VERIFY-BY-LAUNCH: RealityKit entity/material behaviour is confirmed
//  interactively (⌘R); the matrix geometry + expression maths are unit-tested in
//  the M1K3Avatar package (FaceGrid / FaceExpression).
//
//  Signed: Kev + claude-sonnet-4-6, 2026-06-08, Confidence 0.6, Prior: Unknown
//  Review: Kev + claude-sonnet-4-6, 2026-06-08 — pivoted from the M1K3 wordmark to
//  an emoting face per Kev's feedback; same fixed-grid / mutate-emission renderer,
//  AvatarScene stays non-@Observable (the mutate-during-update crash fix).
//  Review: claude-fable-5, 2026-07-18 — `paused` flag on AvatarView + CRTOverlay
//  (default false, all existing call sites unchanged): the missing consumer for
//  ChatBackdropTreatment.animatesMotion. Both 30fps TimelineViews take
//  paused: — a frozen face renders one frame and stops the clocks.
//  Review: claude-fable-5, 2026-07-18 (later) — visionOS framing: no in-scene
//  camera there (eyes are the camera; content renders at true world scale), so
//  the face fit-scales to the view's scene-space bounds via GeometryReader3D.
//  Fit writes the outer `frame` node; jitter keeps owning `root` — separate
//  writers after the PR #60 review caught the per-tick position clobber.
//  macOS/iOS behaviour byte-for-byte unchanged (camera path, identity frame).
//  Review: claude-fable-5, 2026-07-31 — promoted the fit's core arithmetic to
//  `WindowFit.scale` (M1K3Avatar, test-pinned) so CompanionAvatarView's 3D
//  creatures can share the identical camera-less window-fit maths on visionOS
//  rather than re-deriving it. No behaviour change here — same 0.9 headroom,
//  same guard shape.

// AppKit on macOS, UIKit on iOS/visionOS — the avatar is brand-default and now
// cross-platform (the pixel face is pure RealityKit + SwiftUI; only the accent
// colour extraction is platform-specific). See the `rgb(of:)` helper below.
#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif
import M1K3Avatar

// RealityView's content type differs per platform: camera-capable on
// macOS/iOS, plain (eyes-are-the-camera) on visionOS.
#if os(visionOS)
    typealias AvatarRealityContent = RealityViewContent
#else
    typealias AvatarRealityContent = RealityViewCameraContent
#endif
import RealityKit
import SwiftUI

/// Stable reference holding the built cube entities (parallel to
/// FaceGrid.allCells()) so the per-frame update can drive them without re-querying
/// the RealityView content.
///
/// NOT @Observable: the per-frame `update` closure mutates `materials` while
/// SwiftUI is already updating the graph; an @Observable willSet there reenters
/// the AttributeGraph and traps ("thread_is_updating"). This is pure entity
/// storage the view never observes — TimelineView's clock drives redraws.
@MainActor
final class AvatarScene {
    /// The fit-owned OUTER node (visionOS window framing writes scale/position
    /// here). Separate from `root` so the per-tick jitter in `animateBody` —
    /// which assigns `root.position` outright — can never clobber the framing
    /// (PR #60 review catch). Identity on macOS/iOS (the camera frames there).
    var frame: Entity?
    var root: Entity?
    var cubes: [ModelEntity] = []
    /// One material per cube, allocated once and mutated in place each frame —
    /// avoids constructing a fresh UnlitMaterial per cube per frame (GPU churn).
    var materials: [UnlitMaterial] = []
    /// The matrix cells, parallel to `cubes`/`materials` (build + animate order).
    var cells: [(col: Int, row: Int)] = []
    var built = false
    /// Animation clock origin, captured at build time. Animation time is measured
    /// elapsed-since-build so `sin/cos` arguments stay small — mirrors the
    /// AudioCaptureBackdrop fix, where an absolute reference-date (~8e8) lost enough
    /// per-frame precision to flatten the motion. (BUGS.md / AudioCaptureBackdrop.)
    var startDate = Date()
}

struct AvatarView: View {
    let controller: AvatarController
    /// Freeze the idle motion (and the CRT pass) — the consumer for
    /// ChatBackdropTreatment.animatesMotion, which promised "recede/still stop
    /// moving" but had no consumer until 2026-07-18. A paused face renders one
    /// crisp frame and goes quiet: no 30fps cube churn under a live blur, no
    /// battery cost under Low Power, no drift under Reduce Motion.
    var paused = false

    @State private var scene = AvatarScene()

    /// Layout constants (RealityKit world units).
    private static let spacing: Float = 0.1
    /// Die size vs the 0.1 spacing sets the gutter. 0.082 made the rounded dies
    /// touch (solid-quilt look, seen at ⌘R) — 0.068 gives a 0.032 gutter so each
    /// LED reads as its own peg even with a lit-cell swell on top.
    private static let cubeSize: Float = 0.068
    /// Corner rounding as a fraction of cube size: 0 = sharp dies, 0.5 ≈ dome.
    /// ~0.3 reads as keycap / Lite-Brite peg. Tune by eye at ⌘R.
    private static let cornerRadiusFactor: Float = 0.3
    /// Lit cells swell up to this much over background cells — a geometric fake
    /// of LED bloom (UnlitMaterial can't glow). Scaled by per-cell intensity.
    private static let litSwell: Float = 0.15

    var body: some View {
        #if os(visionOS)
            // visionOS IGNORES in-scene cameras — the user's eyes are the camera
            // and RealityView content renders at TRUE world scale, so the ~1.3 m
            // face grid overflowed the window volume unseen (the V0 spike's
            // black-avatar root cause, 2026-07-18). No camera; instead fit the
            // grid to the view's own bounds, re-fitted on timeline ticks so
            // window resizes track (a paused face re-fits on the next unpause).
            GeometryReader3D { geometry in
                faceCore(fit: { content, frame in
                    Self.fit(frame: frame, to: geometry, in: content)
                })
            }
        #else
            faceCore(fit: nil)
        #endif
    }

    /// The shared TimelineView + RealityView core. `fit` is the visionOS
    /// framing strategy (scale-to-view-bounds, applied to the OUTER frame node
    /// so the jitter's `root.position` writes can't clobber it); nil means
    /// macOS/iOS, where a head-on PerspectiveCamera frames the grid instead.
    private func faceCore(fit: ((AvatarRealityContent, Entity) -> Void)?) -> some View {
        TimelineView(schedule) { context in
            RealityView { content in
                // Build once: one cube per matrix cell, each with its own material
                // (mutated in place each frame, never reallocated). Two nodes:
                // `frame` is fit-owned (visionOS framing), `root` is
                // animate-owned (jitter) — separate writers, no clobbering.
                let frame = Entity()
                let root = Entity()
                frame.addChild(root)
                var cubes: [ModelEntity] = []
                var materials: [UnlitMaterial] = []
                let cells = FaceGrid.allCells()
                for cell in cells {
                    let mesh = MeshResource.generateBox(
                        size: Self.cubeSize,
                        cornerRadius: Self.cubeSize * Self.cornerRadiusFactor
                    )
                    let material = UnlitMaterial(color: .black)
                    let cube = ModelEntity(mesh: mesh, materials: [material])
                    cube.position = Self.basePosition(for: cell)
                    root.addChild(cube)
                    cubes.append(cube)
                    materials.append(material)
                }
                content.add(frame)

                if let fit {
                    fit(content, frame)
                } else {
                    #if !os(visionOS)
                        // A head-on camera so the matrix face reads
                        // flat-but-dimensional (macOS/iOS only — see body).
                        let camera = PerspectiveCamera()
                        camera.look(at: .zero, from: [0, 0, 2.6], relativeTo: nil)
                        content.add(camera)
                    #endif
                }

                scene.frame = frame
                scene.root = root
                scene.cubes = cubes
                scene.materials = materials
                scene.cells = cells
                scene.startDate = context.date
                scene.built = true
            } update: { content in
                guard scene.built else { return }
                if let fit, let frame = scene.frame {
                    fit(content, frame)
                }
                let time = context.date.timeIntervalSince(scene.startDate)
                animate(at: time)
            }
        }
        .overlay(CRTOverlay(paused: paused))
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    #if os(visionOS)
        /// Scale + centre the face grid inside the view's scene-space bounds.
        /// Writes ONLY the outer frame node — the jitter owns `root` (see
        /// faceCore). 0.9: headroom for the lit-cell swell + column shifts.
        /// A side bonus of the split: the jitter runs in fitted-frame space,
        /// so it scales with the face instead of being ±0.008 world metres.
        private static func fit(frame: Entity, to geometry: GeometryProxy3D, in content: AvatarRealityContent) {
            let bounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
            let gridWidth = Float(FaceGrid.cols - 1) * spacing + cubeSize
            let gridHeight = Float(FaceGrid.rows - 1) * spacing + cubeSize
            // The core arithmetic is shared with CompanionAvatarView's identical
            // window-fit (WindowFit.scale, M1K3Avatar) — promoted out of here 2026-07-31
            // so the two surfaces can't silently drift apart.
            guard let scale = WindowFit.scale(
                contentWidth: gridWidth, contentHeight: gridHeight,
                boundsWidth: bounds.extents.x, boundsHeight: bounds.extents.y,
                headroom: 0.9
            ) else { return }
            frame.scale = SIMD3(repeating: scale)
            // Deliberately NO position write: content entity space is already
            // window-relative with its origin at the view, so the grid is
            // centred as built. Writing bounds.center (scene space) here
            // double-offsets the face out of view — proven empirically: the
            // first cut did it, and only the jitter clobbering root.position
            // back to ~zero each tick made it LOOK right (screenshot A/B'd
            // both ways, 2026-07-18). Scale is the only fit dimension.
        }
    #endif

    // MARK: - Per-frame animation

    private func animate(at time: Double) {
        let state = controller.state
        let accent = Self.rgb(of: state.emotion.accentColor)

        for index in scene.cubes.indices {
            let cell = scene.cells[index]
            let cube = scene.cubes[index]

            // Depth pop for lit features, plus the error-glitch horizontal tear
            // (columnShift is in cell units → scale by the grid spacing).
            var position = Self.basePosition(for: cell)
            position.x += FaceExpression.columnShift(row: cell.row, state: state, time: time) * Self.spacing
            position.z = FaceExpression.displacement(col: cell.col, row: cell.row, state: state, time: time)
            cube.position = position

            // Brightness → emission. Mutate the cached material's colour in place
            // rather than allocating a new UnlitMaterial every frame.
            let intensity = FaceExpression.intensity(col: cell.col, row: cell.row, state: state, time: time)
            scene.materials[index].color = .init(tint: Self.scaled(accent, by: intensity))
            cube.model?.materials = [scene.materials[index]]

            // Lit cells swell with brightness — a geometric stand-in for LED
            // bloom. Background cells (~0.06) barely move; full-lit gets the
            // whole litSwell.
            cube.scale = SIMD3(repeating: 1 + Self.litSwell * intensity)
        }

        animateBody(at: time, root: scene.root)
    }

    /// Whole-face motion: a gentle multi-axis 3D drift (turn + nod + tilt at
    /// incommensurate rates, so it never repeats and reads as "alive") plus a tiny
    /// high-frequency positional jitter for an analog feel. Both move the entire
    /// face as one rigid body, so eyes + mouth stay perfectly in register.
    private func animateBody(at time: Double, root: Entity?) {
        guard let root else { return }
        let active = controller.state.activity.isActive
        let gain: Float = active ? 1.3 : 1.0 // a touch livelier mid-interaction

        // 3D drift — yaw (turn), pitch (nod), roll (tilt).
        let yaw = Float(sin(time * 0.45)) * 0.07 * gain
        let pitch = Float(sin(time * 0.33 + 1.0)) * 0.045 * gain
        let roll = Float(sin(time * 0.27)) * 0.025 * gain
        root.orientation = simd_quatf(angle: yaw, axis: [0, 1, 0])
            * simd_quatf(angle: pitch, axis: [1, 0, 0])
            * simd_quatf(angle: roll, axis: [0, 0, 1])

        // Micro-jitter — two summed sines per axis (≈±0.008 units) so it shivers
        // organically rather than buzzing at one rate. Kept ≤6 Hz so it stays
        // smooth at 30 fps instead of aliasing into a wobble.
        let jitterX = Float(sin(time * 6.0) + sin(time * 4.3)) * 0.004
        let jitterY = Float(sin(time * 5.0 + 2.0) + sin(time * 3.7)) * 0.004
        root.position = SIMD3(jitterX, jitterY, 0)
    }

    // MARK: - Geometry

    /// The resting position for a cell, centred on the origin. Row increases
    /// downward in the matrix, so Y is negated for RealityKit's Y-up space.
    private static func basePosition(for cell: (col: Int, row: Int)) -> SIMD3<Float> {
        let xPos = (Float(cell.col) - Float(FaceGrid.cols - 1) / 2) * spacing
        let yPos = -(Float(cell.row) - Float(FaceGrid.rows - 1) / 2) * spacing
        return SIMD3(xPos, yPos, 0)
    }

    /// The accent as device RGB (0...1), cross-platform. `RealityKit.Material.Color` is
    /// `NSColor` on macOS and `UIColor` on iOS/visionOS, and only NSColor exposes
    /// `.usingColorSpace`/`.redComponent`, so the extraction branches by platform.
    private static func rgb(of color: Color) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        #if canImport(AppKit)
            let ns = NSColor(color).usingColorSpace(.deviceRGB) ?? .white
            return (ns.redComponent, ns.greenComponent, ns.blueComponent)
        #else
            var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            return (r, g, b)
        #endif
    }

    /// Blend the accent toward black by `1 - brightness` so low emission reads dim.
    private static func scaled(_ rgb: (r: CGFloat, g: CGFloat, b: CGFloat), by brightness: Float) -> RealityKit.Material.Color {
        let clamped = CGFloat(min(max(brightness, 0), 1))
        return RealityKit.Material.Color(
            red: rgb.r * clamped,
            green: rgb.g * clamped,
            blue: rgb.b * clamped,
            alpha: 1
        )
    }

    // MARK: - Timeline

    /// 30 fps throughout — the idle micro-jitter + LED flicker need a steady 30 fps
    /// to read as a smooth analog shiver rather than aliasing into a slow wobble.
    /// `paused` stops the clock entirely (one last frame renders, then quiet).
    private var schedule: AnimationTimelineSchedule {
        AnimationTimelineSchedule(minimumInterval: 1.0 / 30.0, paused: paused)
    }
}

// MARK: - CRT overlay

/// A retro-CRT pass composited over the avatar: horizontal scanlines, a slow
/// rolling sync band, a corner vignette, and a faint phosphor breathe. Pure
/// SwiftUI Canvas in a TimelineView — no Metal, no shaders, so it layers over
/// the RealityView (SwiftUI shader effects can't reach platform-backed views).
///
/// VERIFY-BY-LAUNCH: purely visual; tune the constants by eye at ⌘R.
/// Lives in this file (not its own) so the spike needs no xcodegen regen.
///
/// Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.6 (spike — constants
/// are first-guess, judged by eye, not measured), Prior: Unknown.
struct CRTOverlay: View {
    /// Freeze the rolling band + phosphor breathe (see AvatarView.paused).
    var paused = false

    /// Elapsed-time origin — sin/cos arguments stay small (the
    /// AudioCaptureBackdrop precision lesson; see AvatarScene.startDate).
    @State private var start = Date()

    // Tunables, judged by eye.
    private static let scanlineOpacity: Double = 0.20
    private static let bandHeight: CGFloat = 70
    private static let bandSpeed: CGFloat = 26 // points per second, downward
    private static let vignetteOpacity: Double = 0.38

    /// Scanline pitch scales WITH the surface so the CRT reads the same at any
    /// avatar size. A fixed 3pt pitch is a fine texture on the ~200pt panel but a
    /// dense venetian blind when the face fills the window (voice-mode hero). Tied
    /// to height (≈ view/100) and clamped [3, 8]: the small panel + tiny menu-bar
    /// glyph stay at the original 3pt; the full-window face widens to ~7pt — wider
    /// lines, and (1px thick) lighter coverage, like a bigger tube.
    private static func scanlineSpacing(forHeight height: CGFloat) -> CGFloat {
        min(8, max(3, height / 100))
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { context in
            let time = context.date.timeIntervalSince(start)
            Canvas { canvas, size in
                drawScanlines(canvas, size: size, time: time)
                drawRollingBand(canvas, size: size, time: time)
                drawVignette(canvas, size: size)
            }
        }
        .allowsHitTesting(false)
        // Purely decorative — scanlines/band/vignette add nothing VoiceOver should
        // announce; the meaningful label lives on the avatar surface underneath.
        .accessibilityHidden(true)
    }

    /// Thin dark lines every few points; opacity breathes ~8% at a slow beat so
    /// the mask shimmers like a real tube instead of sitting like a sticker.
    private func drawScanlines(_ canvas: GraphicsContext, size: CGSize, time: Double) {
        let breathe = 1 + 0.08 * sin(time * 1.7)
        let opacity = Self.scanlineOpacity * breathe
        let spacing = Self.scanlineSpacing(forHeight: size.height)
        var y: CGFloat = 0
        while y < size.height {
            let line = CGRect(x: 0, y: y, width: size.width, height: 1)
            canvas.fill(Path(line), with: .color(.black.opacity(opacity)))
            y += spacing
        }
    }

    /// A soft bright band rolling down the screen — the classic out-of-sync
    /// refresh artifact. Starts above the frame and exits below before wrapping.
    private func drawRollingBand(_ canvas: GraphicsContext, size: CGSize, time: Double) {
        let travel = size.height + Self.bandHeight * 2
        let offset = (CGFloat(time) * Self.bandSpeed).truncatingRemainder(dividingBy: travel)
        let bandY = offset - Self.bandHeight
        let rect = CGRect(x: 0, y: bandY, width: size.width, height: Self.bandHeight)
        let gradient = Gradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .white.opacity(0.05), location: 0.5),
            .init(color: .clear, location: 1),
        ])
        canvas.fill(
            Path(rect),
            with: .linearGradient(
                gradient,
                startPoint: CGPoint(x: 0, y: rect.minY),
                endPoint: CGPoint(x: 0, y: rect.maxY)
            )
        )
    }

    /// Radial darkening toward the corners — curved-glass falloff. The radius
    /// eases outward as the surface grows (0.75 → ~1.05) so a full-window face
    /// keeps gentle corner curvature instead of crushed black wells; the small
    /// panel is unchanged.
    private func drawVignette(_ canvas: GraphicsContext, size: CGSize) {
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let ease = min(0.30, size.height / 3000)
        let radius = max(size.width, size.height) * (0.75 + ease)
        let gradient = Gradient(stops: [
            .init(color: .clear, location: 0),
            .init(color: .clear, location: 0.55),
            .init(color: .black.opacity(Self.vignetteOpacity), location: 1),
        ])
        canvas.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(gradient, center: centre, startRadius: 0, endRadius: radius)
        )
    }
}
