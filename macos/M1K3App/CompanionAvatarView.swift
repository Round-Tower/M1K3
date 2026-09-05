//
//  CompanionAvatarView.swift
//  M1K3App
//
//  The opt-in 3D companion creature — an alternative to the pixel face for voice
//  mode. Extracted from AvatarView.swift to keep that file under SwiftLint's
//  file_length ceiling. References CRTOverlay (same module, stays in AvatarView)
//  and the M1K3Avatar companion cores. RealityKit render is verify-by-launch; the
//  state→clip maths is unit-tested in M1K3Avatar (ClipMapper / CompanionSpec).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-14, Confidence 0.85, Prior: Kev +
//  claude-opus-4-8 (CompanionScene/CompanionAvatarView originate in AvatarView.swift,
//  2026-06-11; moved here verbatim).
//  Review: Kev + claude-opus-4-8, 2026-07-28 — cross-platform for the iOS/visionOS
//  shell (#if AppKit/UIKit; visionOS camera + CustomMaterial shading gated off) and
//  reworked to a SINGLE stable RealityView: a persistent root + lights + camera built
//  once, the creature swapped in place with a monotonic loadToken, so an iOS companion
//  switch can't recreate the RealityView (the "swap → black" lifecycle trap). Plus a
//  process-level clip cache and render-the-static-mesh-not-nothing on a missing idle.
//  Review: claude-fable-5, 2026-07-31 — applied AvatarView's #60 camera-less visionOS
//  framing here too: a fit-owned `frame` node (parent of the persistent `root`) is
//  scale-fit to the window's real scene-space bounds via `WindowFit.scale` (M1K3Avatar,
//  test-pinned, shared with AvatarView so the two surfaces can't drift), replacing the
//  fixed 0.45 m guess this file's own comment flagged as "Phase-D verify-owed." No
//  position write on the frame — same double-offset lesson AvatarView's fit documents.
//  A new `loadTick` @State nudge forces a render right when a creature finishes loading,
//  since (unlike AvatarView) this view has no continuous TimelineView clock to carry the
//  fit forward on its own. macOS/iOS PerspectiveCamera path is byte-for-byte unchanged.
//  Prior: Kev + claude-opus-4-8 (this file).

// AppKit on macOS, UIKit on iOS/visionOS — the companion render path is now
// cross-platform (shared into the M1K3iOSApp mobile shell). Only the emotion-fill
// colour extraction is platform-specific; RealityKit + the shading glue are not.
#if canImport(AppKit)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif
import M1K3Avatar
import os
import RealityKit
import SwiftUI

// MARK: - Companion avatar (opt-in 3D creature)

/// Process-level cache of harvested clips per companion id.
///
/// RealityKit's `Entity(contentsOf:)` keeps an internal asset cache, and on a
/// REPEAT load of the same USDZ it can hand back an instance whose
/// `availableAnimations` is EMPTY (the animations live on the first-loaded root).
/// Harvesting per-mount therefore worked for the first companion shown and left
/// every one after it a black, unbuilt view — the "first renders, switches go
/// black; none appear on device" bug. So we harvest ONCE per companion and reuse
/// the AnimationResources: they replay across fresh Entity instances of the same
/// rig, which is exactly how the cross-clip donor harvest already binds them.
@MainActor
enum CompanionClipCache {
    static var byCompanion: [String: [String: AnimationResource]] = [:]
}

/// Stable storage for the loaded companion: the mesh-bearing host entity and the
/// harvested per-clip animations. NOT @Observable — like AvatarScene, the update
/// closure drives it while SwiftUI is mid-graph-update.
@MainActor
final class CompanionScene {
    /// The fit-owned OUTER node (visionOS window framing writes scale here, the
    /// same frame/root split AvatarView's pixel face uses — PR #60). Parent of
    /// `root`, so the window-fit scale can never be clobbered by anything that
    /// mutates `root`/`host` in place. Identity on macOS/iOS (the fixed camera
    /// frames there instead).
    var frame: Entity?
    /// The persistent root added to the RealityView ONCE. Creatures are swapped as
    /// its children in place, so the RealityView itself is never recreated on a
    /// companion switch — the fix for the iOS "swap → black" lifecycle trap.
    var root: Entity?
    /// The scaffold (root + lights + camera) has been built into the RealityView.
    var scaffoldBuilt = false
    /// The claimed target companion id — the in-place-reload gate. Set SYNCHRONOUSLY
    /// by the caller (make/update) before spawning the load, so the high-frequency
    /// update closure can't spawn a second reload Task for the same target. Left
    /// pointing at a failed target on load failure (deliberately — no retry storm);
    /// `displayedCompanion` is what's actually on screen.
    var loadedCompanionID: String?
    /// The companion actually rendered in `root` right now — may lag
    /// `loadedCompanionID` when a newer load is in flight or failed. sync() reads ITS
    /// dialect, so a failed switch keeps animating the creature that's really shown.
    var displayedCompanion: CompanionSpec?
    /// Monotonic reload token: a load that finishes after a newer one started is
    /// dropped, so rapid switches never leave an older creature winning the swap.
    var loadToken = 0
    var host: Entity?
    /// The loaded creature's own local-space visual bounds (host-local —
    /// captured before parenting, so no parent transform is baked in),
    /// captured once at load — right after `fit(_:)` normalizes it, right before
    /// it's parented — so the visionOS window-fit has a stable "designed content
    /// size" to scale against instead of re-measuring RealityKit bounds every
    /// tick. `nil` until the first successful load.
    var hostExtents: SIMD3<Float>?
    var fillLight: DirectionalLight?
    /// Clip name → harvested animation resource (cross-bound onto `host`'s rig).
    var clips: [String: AnimationResource] = [:]
    var currentClip: String?
    /// Last emotion the fill light was tinted for — guards the per-frame colour write.
    var lastEmotion: AvatarEmotion = .neutral
    /// Last activity the skin was tinted for — guards the per-frame material
    /// rewrite (only re-paint when the state actually changes).
    var lastActivity: AvatarActivity = .idle
    /// Last shading style painted — so switching the style picker repaints live.
    var lastShadingStyle: CompanionShadingStyle = .off
    /// The creature's baked materials, snapshotted before any shader is applied —
    /// cel rebuilds FROM these (keeping the fur texture) and Off restores them.
    var bakedMaterials: [ObjectIdentifier: [any RealityKit.Material]] = [:]
    var built = false
}

/// The 3D companion: an opt-in alternative to the pixel face for voice mode. Loads
/// one mesh + N per-clip USDZs from M1K3Avatar's bundle, harvests each clip onto a
/// single rig (the one-mesh/N-clip-files architecture proven in scratch/usdz-probe),
/// and crossfades clips as the AvatarController's state changes — driven by the same
/// AvatarState the pixel face reads, through ClipMapper instead of FaceExpression.
///
/// The pixel face stays M1K3's default brand face (chat, onboarding, the app icon);
/// this is the wink the curious user opts into.
///
/// VERIFY-BY-LAUNCH: RealityKit load/animation/lighting is eyeballed at ⌘R; the
/// state→clip maths is unit-tested in M1K3Avatar (ClipMapper / CompanionSpec).
///
/// Signed: Kev + claude-opus-4-8, 2026-06-11, Confidence 0.6 (render quality is the
/// gate this view exists to answer; lighting + framing constants are by-eye), Prior: Unknown
struct CompanionAvatarView: View {
    let controller: AvatarController
    let companion: CompanionSpec

    /// Opt-in shading style (phosphor glow / cel toon) over the companion's baked
    /// textures. Applies on build and switches live when the picker changes.
    @AppStorage(CompanionDefaults.shadingStyleKey) private var shadingRaw = CompanionShadingStyle.off.rawValue

    private var shadingStyle: CompanionShadingStyle {
        CompanionShadingStyle(rawValue: shadingRaw) ?? .off
    }

    /// Optional mirror of the mesh load for a host that wants a spinner (the
    /// iOS onboarding face step). Set on the main actor around `reload(to:)`.
    var loading: Binding<Bool>? = nil

    @State private var scene = CompanionScene()
    /// Bumped once at the end of every successful `reload(to:)` — a plain
    /// counter with no meaning of its own, purely to force a fresh SwiftUI
    /// render (and so a fresh RealityView `update` call) right when a creature
    /// finishes loading. Without it, the visionOS window-fit (which only runs
    /// inside `update`) would wait on the NEXT unrelated state change
    /// (`controller.state` can sit idle for a while) before framing correctly —
    /// a visible flash of default (unscaled) size between load and fit.
    @State private var loadTick = 0

    // Fit the creature's largest dimension to this many world units, then frame it.
    // macOS/iOS frame it with a fixed PerspectiveCamera, so the absolute size only
    // has to suit that camera (1.7). visionOS IGNORES in-scene cameras and renders
    // at TRUE world scale inside the window volume — rather than guess a metres
    // size that happens to suit "a window", the creature is normalized to this
    // reference size and then the OUTER frame node is scale-fit to the view's real
    // window bounds (the #60 pattern, promoted 2026-07-31 — see `fit(frame:to:in:)`
    // below). 1.0: an arbitrary but stable reference; only its ratio to the
    // measured extents matters once the window-fit rescales it.
    #if os(visionOS)
        private static let targetSize: Float = 1.0
    #else
        private static let targetSize: Float = 1.7
    #endif
    /// A flattering three-quarter base pose (radians about Y) rather than head-on —
    /// after the upright correction the creature's length runs in Z (depth), so this
    /// turns its broadside toward the camera.
    private static let baseYaw: Float = -0.9

    var body: some View {
        // Read (and discard) `loadTick` HERE — not inside a closure below — so
        // SwiftUI's @State dependency tracking actually registers it against
        // THIS body evaluation. A read inside the `fit` closure wouldn't count:
        // that closure only runs later, when RealityView invokes it, by which
        // point body has already finished evaluating its dependencies. `let _ =`
        // (a declaration), not `_ = ` (an expression statement) — `body` is
        // @ViewBuilder-inferred, and only declarations pass through unchanged;
        // a bare discard-assignment gets funneled through `buildExpression` and
        // fails to type-check as a View.
        let _ = loadTick
        #if os(visionOS)
            // visionOS IGNORES in-scene cameras — the wearer's eyes are the camera
            // and RealityView content renders at TRUE world scale, exactly the V0
            // black-avatar root cause AvatarView's pixel face hit first (PR #60).
            // Same fix here: no camera; scale-fit the creature's frame to the
            // view's own bounds instead of the old fixed 0.45 m guess.
            GeometryReader3D { geometry in
                companionCore(fit: { content, frame in
                    guard let extents = scene.hostExtents else { return }
                    Self.fit(frame: frame, to: geometry, in: content, extents: extents)
                })
            }
        #else
            companionCore(fit: nil)
        #endif
    }

    /// The shared RealityView core. `fit` is the visionOS window-fit strategy
    /// (scale-to-view-bounds, applied to the OUTER frame node — same split as
    /// AvatarView's `faceCore`, so nothing that mutates `root`/`host` in place
    /// can clobber the framing); nil means macOS/iOS, where the fixed
    /// PerspectiveCamera frames the creature instead (byte-for-byte unchanged).
    private func companionCore(fit: ((AvatarRealityContent, Entity) -> Void)?) -> some View {
        RealityView { content in
            // Build the STABLE scaffold once — a persistent frame + root + lights +
            // camera. The creature is loaded into `root` and reloaded IN PLACE when
            // the selection changes; the RealityView is never recreated, so it can't
            // go black on a swap (the iOS "swap → black" lifecycle trap that made
            // every companion after the first render as a black panel). `frame` is
            // fit-owned (visionOS window framing); `root` is where creatures swap.
            let frame = Entity()
            let root = Entity()
            frame.addChild(root)
            content.add(frame)
            scene.frame = frame
            scene.root = root
            addLighting(to: &content)
            #if !os(visionOS)
                addCamera(to: &content)
            #endif
            scene.scaffoldBuilt = true
            scene.loadedCompanionID = companion.id
            await reload(to: companion)
        } update: { content in
            guard scene.scaffoldBuilt else { return }
            if let fit, scene.built, let frame = scene.frame {
                fit(content, frame)
            }
            if companion.id != scene.loadedCompanionID {
                // Selection changed → claim the target SYNCHRONOUSLY here (not inside
                // the async Task), so this high-frequency closure can't spawn a second
                // reload for the same companion before the first begins. The swap
                // happens in the SAME RealityView (no recreation → no black).
                scene.loadedCompanionID = companion.id
                let target = companion
                Task { await reload(to: target) }
            } else if scene.built {
                sync(to: controller.state)
            }
        }
        .overlay(CRTOverlay())
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    #if os(visionOS)
        /// Scale (never translate — content entity space is already
        /// window-relative, so writing `bounds.center` here would double-offset
        /// the creature out of view, the exact PR #60 lesson AvatarView's fit
        /// documents) the OUTER frame node so the loaded creature's own extents
        /// fill the view's real window bounds. `extents` is captured once at
        /// load (`reload(to:)`, right after the per-companion normalize-to-
        /// `targetSize` step) rather than re-measured every tick. Shares its
        /// arithmetic with AvatarView's identical fit via `WindowFit.scale`.
        private static func fit(
            frame: Entity, to geometry: GeometryProxy3D, in content: AvatarRealityContent, extents: SIMD3<Float>
        ) {
            let bounds = content.convert(geometry.frame(in: .local), from: .local, to: .scene)
            guard let scale = WindowFit.scale(
                contentWidth: extents.x, contentHeight: extents.y,
                boundsWidth: bounds.extents.x, boundsHeight: bounds.extents.y,
                headroom: 0.9
            ) else { return }
            frame.scale = SIMD3(repeating: scale)
        }
    #endif

    // MARK: - Load a creature into the persistent root (in place)

    /// Blender exports Z-up; RealityKit is Y-up, so a companion loads standing on
    /// its nose. The base pose pitches it upright (−90° about X) THEN turns it to
    /// the three-quarter yaw. Uniform across companions — all share the Blender
    /// export pipeline; a future Y-up source would need this per-spec.
    private static let blenderZUpCorrection: Float = -.pi / 2
    private static var basePose: simd_quatf {
        simd_quatf(angle: baseYaw, axis: [0, 1, 0])
            * simd_quatf(angle: blenderZUpCorrection, axis: [1, 0, 0])
    }

    private static let log = Logger(subsystem: "app.m1k3", category: "companion")

    /// Load `companion`'s mesh and swap it into the persistent `root` IN PLACE — the
    /// RealityView, lights and camera are untouched, so a switch can never blank the
    /// surface. Cancels stragglers via a monotonic token (a slow load that finishes
    /// after a newer switch is dropped). Called once on build and again whenever the
    /// selection changes.
    private func reload(to companion: CompanionSpec) async {
        guard let root = scene.root else { return }
        scene.loadToken += 1
        let token = scene.loadToken
        loading?.wrappedValue = true
        defer { if token == scene.loadToken { loading?.wrappedValue = false } }
        // `loadedCompanionID` was claimed synchronously by the caller (make/update).

        guard let idleURL = CompanionAssets.clipURL(companion: companion.id, clip: companion.idleClip),
              let host = try? await Entity(contentsOf: idleURL)
        else {
            // Keep whatever creature is already shown rather than blanking. We do NOT
            // revert loadedCompanionID: leaving it on the failed target stops update()
            // from re-spawning the doomed load every tick (a retry storm). sync() reads
            // `displayedCompanion` (still the on-screen creature), so animation stays
            // correct even though the claim points at the failed target.
            //
            // Edge case: if this fails on the FIRST load of a companion (nothing yet
            // displayed — scene.host == nil), the surface stays blank until the user
            // re-selects (picking another face and back re-triggers update → reload).
            // Only reachable via a corrupt bundled USDZ that still resolves as a URL
            // (isInstalled checks resolution, not decodability) — i.e. a packaging bug,
            // not a runtime one. Accepting the reselect-to-recover path over a per-tick
            // retry storm; the assets are pipeline-validated (rkprobe --tick) before ship.
            // Staleness-check BEFORE logging: a superseded load's failure is
            // not an error the user can still see — logging it would plant a
            // red herring beside any real load failure (PR #82 review).
            if token == scene.loadToken {
                Self.log.error("companion \(companion.id, privacy: .public): mesh failed to load")
            }
            return
        }
        guard token == scene.loadToken else { return } // a newer switch superseded us

        // Reuse the process-cached clips when we've harvested this companion before:
        // RealityKit's asset cache can return an animationless clone on a repeat load,
        // which is what left re-mounted companions animation-less. Harvest (and cache)
        // only on the first miss. See CompanionClipCache.
        let clips: [String: AnimationResource]
        if let cached = CompanionClipCache.byCompanion[companion.id], !cached.isEmpty {
            clips = cached
        } else {
            let harvested = await harvestClips(idleHost: host)
            if !harvested.isEmpty { CompanionClipCache.byCompanion[companion.id] = harvested }
            clips = harvested
        }
        guard token == scene.loadToken else { return }
        // ⚠️ No `await` below this point (review invariant, PR #91): the token
        // re-check above is the LAST one, and everything after runs atomically
        // on @MainActor. Adding a suspension anywhere in this tail would let a
        // superseded load write hostExtents/host/built unguarded — re-check the
        // token after any future await here.

        // Pose BEFORE fit() so the recentre + scale measure the final, upright silhouette.
        host.orientation = Self.basePose
        fit(host)
        // Captured BEFORE `root.addChild(host)` — host has no parent yet, so
        // `relativeTo: nil` reads local-space extents (the visionOS window-fit's
        // "designed content size"), same assumption `fit(_:)` already documents.
        scene.hostExtents = host.visualBounds(relativeTo: nil).extents

        // The swap: drop the previous creature, add the new one to the SAME root.
        scene.host?.removeFromParent()
        root.addChild(host)

        // Play the resting clip if we have it; otherwise render the STATIC mesh rather
        // than nothing. A frozen creature reads as quiet/loading; a black panel reads
        // as broken — and the mesh appearing at all is the whole point.
        if let idle = clips[companion.idleClip] {
            host.playAnimation(idle.repeat(), transitionDuration: 0.3)
        } else {
            Self.log.warning("companion \(companion.id, privacy: .public): no idle clip harvested — static mesh")
        }

        let activity = controller.state.activity
        // Opt-in shading style: paint the selected M1K3 shader over the baked
        // materials. CustomMaterial surface shaders are macOS/iOS only — on visionOS
        // the creature simply shows its baked textures (see PhosphorMaterial note).
        #if !os(visionOS)
            // Snapshot the baked materials BEFORE any shader, so cel can adapt the
            // fur texture and Off can restore it on a live switch.
            scene.bakedMaterials = PhosphorMaterial.snapshotMaterials(of: host)
            // Rides the skeletal animation for free (per-fragment shader, blind to
            // the rig). Falls back silently if the shader can't load.
            PhosphorMaterial.apply(
                shadingStyle, treatment: activity.phosphorTreatment,
                originals: scene.bakedMaterials, to: host
            )
        #endif

        scene.host = host
        scene.displayedCompanion = companion // what's really on screen now (sync reads its dialect)
        scene.clips = clips
        // nil when the idle clip is missing, so sync() will try to start a real clip
        // as soon as the state changes rather than believing idle is already playing.
        scene.currentClip = clips[companion.idleClip] != nil ? companion.idleClip : nil
        scene.lastEmotion = controller.state.emotion
        scene.lastActivity = activity
        scene.lastShadingStyle = shadingStyle
        scene.built = true
        // Force a fresh SwiftUI render right now — see the `loadTick` doc comment;
        // otherwise the visionOS window-fit (which only runs inside `update`) waits
        // on the next unrelated `controller.state` change to frame correctly.
        loadTick &+= 1
    }

    /// Harvest each bundled clip as an animation resource bound to the idle host's
    /// rig. The idle file's own clip comes from `host`; the rest cross-bind from
    /// their donor files (one mesh + N clip files — proven in scratch/usdz-probe).
    private func harvestClips(idleHost host: Entity) async -> [String: AnimationResource] {
        var clips: [String: AnimationResource] = [:]
        if let idleAnim = host.availableAnimations.first {
            clips[companion.idleClip] = idleAnim
        }
        for (name, url) in CompanionAssets.clipURLs(for: companion) where name != companion.idleClip {
            if let donor = try? await Entity(contentsOf: url), let anim = donor.availableAnimations.first {
                clips[name] = anim
            }
        }
        return clips
    }

    /// Scale the creature so its largest extent fills `targetSize`, then recentre it
    /// on the origin — companions are authored at wildly different native sizes (the
    /// probe read native height from accessor min/max; this does it live). Assumes
    /// `host`'s parent is identity-transform (the freshly-made `root`), so world-space
    /// bounds equal local bounds.
    private func fit(_ host: Entity) {
        host.scale = SIMD3(repeating: companion.scale)
        let extents = host.visualBounds(relativeTo: nil).extents
        let maxDim = max(extents.x, extents.y, extents.z)
        if maxDim > 0 { host.scale *= Self.targetSize / maxDim }
        // Re-measure post-scale: the centre shifts with scale, so this is a second,
        // necessary read (not a cacheable duplicate of the pre-scale bounds above).
        host.position -= host.visualBounds(relativeTo: nil).center
    }

    private func addLighting(to content: inout some RealityViewContentProtocol) {
        let key = DirectionalLight()
        key.light.intensity = 6000
        key.light.color = .white
        key.look(at: .zero, from: [-1.2, 1.4, 2.0], relativeTo: nil)
        content.add(key)

        // Emotion-accent fill from the opposite side — the companion's equivalent
        // of the pixel face's accent tint, as mood lighting (textures survive).
        let fill = DirectionalLight()
        fill.light.intensity = 1800
        fill.light.color = Self.fillColor(for: controller.state.emotion)
        fill.look(at: .zero, from: [1.6, 0.4, 1.6], relativeTo: nil)
        content.add(fill)
        scene.fillLight = fill
    }

    #if !os(visionOS)
        private func addCamera(to content: inout some RealityViewContentProtocol) {
            let camera = PerspectiveCamera()
            camera.look(at: [0, 0, 0], from: [0, 0.15, 2.4], relativeTo: nil)
            content.add(camera)
        }
    #endif

    // MARK: - Per-update sync

    private func sync(to state: AvatarState) {
        // Re-tint the fill only when the emotion actually changes — sync() runs every
        // SwiftUI update (30 fps) and a colour write is a GPU command each time.
        if state.emotion != scene.lastEmotion {
            scene.fillLight?.light.color = Self.fillColor(for: state.emotion)
            scene.lastEmotion = state.emotion
        }

        // Reactive shading: shift the glow/tint with M1K3's state, AND repaint live
        // when the style picker changes (incl. restoring textures on switch to Off).
        // Re-paint only on a real change — sync() runs ~30 fps. macOS/iOS only
        // (CustomMaterial is unavailable on visionOS — see build()).
        #if !os(visionOS)
            let style = shadingStyle
            if let host = scene.host, state.activity != scene.lastActivity || style != scene.lastShadingStyle {
                PhosphorMaterial.apply(
                    style, treatment: state.activity.phosphorTreatment,
                    originals: scene.bakedMaterials, to: host
                )
                scene.lastActivity = state.activity
                scene.lastShadingStyle = style
            }
        #endif

        // Use the DISPLAYED companion's dialect, not the binding's: if a switch failed
        // to load, the binding points at the failed target while the previous creature
        // is still on screen, and its clip vocabulary is what `scene.clips`/`host` hold.
        let dialect = (scene.displayedCompanion ?? companion).dialect
        let desired = ClipMapper.clip(for: state, dialect: dialect)
        guard desired != scene.currentClip, let resource = scene.clips[desired], let host = scene.host
        else { return }
        let gait = ClipMapper.gait(for: state)
        host.playAnimation(resource.repeat(), transitionDuration: ClipMapper.crossfadeDuration(to: gait))
        scene.currentClip = desired
    }

    /// Accent colour for the fill light. Neutral gets a soft warm white rather than
    /// the dynamic `.secondary` grey, which doesn't read as light. `Material.Color`
    /// is `NSColor` on macOS and `UIColor` on iOS/visionOS — only NSColor exposes
    /// `.usingColorSpace`, so the extraction branches by platform (the AvatarView pattern).
    private static func fillColor(for emotion: AvatarEmotion) -> RealityKit.Material.Color {
        guard emotion != .neutral else {
            return RealityKit.Material.Color(white: 0.95, alpha: 1)
        }
        #if canImport(AppKit)
            return NSColor(emotion.accentColor).usingColorSpace(.deviceRGB) ?? .white
        #else
            return RealityKit.Material.Color(emotion.accentColor)
        #endif
    }
}
