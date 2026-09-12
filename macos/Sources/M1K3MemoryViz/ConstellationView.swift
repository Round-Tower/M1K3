//
//  ConstellationView.swift
//  M1K3MemoryViz
//
//  The 3D memory constellation: motes for memories, threads for edges, accreting
//  as the store grows. A thin RealityKit adapter over the pure ConstellationModel
//  — all the layout/colour/geometry decisions are made (and tested) upstream;
//  this file just places entities and animates the growth. VERIFY-BY-RUN: there
//  are no unit tests for RealityView (the tested surface is ConstellationLayout +
//  ConstellationGeometry + ConstellationPalette); the visual feel is Kev's eye.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-16, Confidence 0.7 (compiles against
//  the RealityKit SPM target like M1K3Avatar; on-device look + the growth timing
//  are the named verify-owed). Prior: M1K3Avatar RealityKit views.
//  Review: Kev + claude-fable-5.1, 2026-09-08 — motes + threads use the palette on every platform (the white /
//  grey non-AppKit fallbacks retired) — the iPad field is the Mac field. Confidence now 0.8 (device-owed).
//  Review: Kev + claude-fable-5.1, 2026-09-12 — `paused:` stops the 30 fps clock + the idle drift (the thermal
//  audit's AvatarPresence contract); a hidden field is unmounted by the host, not paused. Confidence now 0.8.

import M1K3Memory
import RealityKit
import simd
import SwiftUI

public struct ConstellationView: View {
    private let model: ConstellationModel
    /// Seconds between each mote popping in — the accretion cadence.
    private let growthStep: TimeInterval
    /// Freeze the idle breath/float/rotation and stop the 30 fps clock (the
    /// AvatarPresence `.paused` contract — recede/still/Low Power). The field
    /// still draws and still grows on a store change; it just doesn't drift.
    /// NOTE: this does not stop RealityKit's own render loop — a surface that
    /// nobody can see must be UNMOUNTED by its host (AvatarSurface does).
    private let paused: Bool
    /// World scale applied to the unit-ish layout positions.
    private let spread: Float
    /// Star size is decoupled from `spread` so tightening the cluster doesn't
    /// shrink the motes — the field gets more compact, the stars stay visible.
    private let moteScale: Float = 2.0

    /// `root` spins (drag); `field` holds the motes/threads and is what we frame;
    /// the camera dollies to fit the field so all stars stay in view.
    @State private var root = Entity()
    @State private var field = Entity()
    @State private var camera = PerspectiveCamera()
    /// Accumulated spin, composed with each drag's delta so a new drag continues
    /// from where the last one ended instead of snapping back to the un-spun pose.
    @State private var storedOrientation = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    /// The idle-animation clock origin, captured at first build — NOT in `onAppear`
    /// (which fires after the first update pass, so the opening frame's delta would
    /// be wrong). The phase is measured as elapsed-since-this, NOT an absolute
    /// reference-date timestamp — whose ~7.7e8 magnitude (cast to Float) once
    /// quantised every frame delta to zero and froze the drift. See `ConstellationIdle`
    /// for the full autopsy; same fix as AudioCaptureBackdrop / AvatarView.
    @State private var start = Date()
    /// Honour the system Reduce Motion preference — freeze the idle breath/float/
    /// rotation (the field still draws + grows, it just doesn't drift on its own).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Per-frame bookkeeping for the change-gate. A reference type held in `@State`
    /// so mutating it inside the RealityView update closure costs nothing and does
    /// NOT trigger SwiftUI invalidation (unlike a @State value would).
    @State private var syncTracker = SyncTracker()

    public init(model: ConstellationModel, growthStep: TimeInterval = 0.08, spread: Float = 1.6, paused: Bool = false) {
        self.model = model
        self.growthStep = growthStep
        self.spread = spread
        self.paused = paused
    }

    public var body: some View {
        // 30fps is plenty for a gentle breath/float/rotation — uncapped `.animation`
        // ran at the display's native rate (120Hz on ProMotion), burning 4× the work
        // for motion the eye can't resolve at this amplitude.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: paused)) { timeline in
            RealityView { content in
                root.addChild(field)
                content.add(root)
                content.add(camera)
                sync(into: field, firstBuild: true)
                frameToFit()
                syncTracker.note(model)
            } update: { _ in
                // The model only GROWS (sync is additive, entities named by id), so a
                // node/edge count change is a reliable "something new" signal. Reconcile
                // + re-frame ONLY then — the old code walked the whole entity tree
                // (visualBounds) and allocated dedup Sets EVERY frame just to discover
                // nothing was new. The idle breath/float/rotation still ticks per frame
                // (three trig ops — cheap), so the field stays alive at rest.
                if syncTracker.changed(model) {
                    sync(into: field, firstBuild: false)
                    frameToFit()
                    syncTracker.note(model)
                }
                if !reduceMotion, !paused {
                    idle(at: timeline.date.timeIntervalSince(start))
                }
            }
            // No background: render transparent over the app's glass, like the 3D
            // companions — rounded-clipped to the same card silhouette.
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .gesture(spinGesture)
            // Pragmatic first cut: the field is opaque to VoiceOver (no per-node 3D
            // elements — that's its own, bigger, piece of work), so speak the shape
            // of what's here as one combined element and point at the accessible
            // list alternative rather than leaving the scene silent.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.accessibilitySummary)
            .accessibilityHint("For a full accessible list, open Memories from the toolbar.")
        }
    }

    /// Subtle life at rest: a slow rotation about a gently tilted axis, a shallow
    /// breath (scale pulse), and a soft vertical float. Applied to `field` so it
    /// composes with the user's drag-spin (on `root`) rather than fighting it.
    private func idle(at elapsed: TimeInterval) {
        let pose = ConstellationIdle.pose(elapsed: elapsed)
        field.orientation = simd_quatf(angle: pose.rotationAngle, axis: ConstellationIdle.axis)
        field.scale = SIMD3<Float>(repeating: pose.breathScale)
        field.position.y = pose.floatY
    }

    // MARK: - Scene construction

    /// Dolly the camera so the WHOLE field fits — count-independent framing, so a
    /// dozen seeds and a few hundred memories both fill the card (fixes "too zoomed
    /// in"). Measured in the field's own space so the drag-spin (on `root`) never
    /// perturbs the fit.
    private func frameToFit() {
        // Field-local bounds: invariant to the idle rotation/breath on `field`, so
        // the camera distance stays steady while the field animates.
        let bounds = field.visualBounds(relativeTo: field)
        let maxDim = max(bounds.extents.x, bounds.extents.y, bounds.extents.z)
        // Camera at ~1.3× the field's extent → everything in frame with margin.
        let distance = max(maxDim * 1.3, 1.5)
        camera.look(at: .zero, from: SIMD3<Float>(0, 0, distance), relativeTo: nil)
    }

    /// Idempotent reconcile: place any node/edge not already in the scene. Entities
    /// are named by id so re-running is cheap and additive — the heart of the
    /// "grows over time" effect. On the first build motes stagger in along the
    /// accretion timeline; motes added later just pop in.
    private func sync(into container: Entity, firstBuild: Bool) {
        let present = Set(container.children.compactMap { UUID(uuidString: $0.name) })
        let growthIndex = Dictionary(
            uniqueKeysWithValues: model.growthOrder.enumerated().map { ($1, $0) }
        )
        for node in model.nodes where !present.contains(node.id) {
            let mote = makeMote(node)
            mote.name = node.id.uuidString
            container.addChild(mote)
            let delay = firstBuild ? Double(growthIndex[node.id] ?? 0) * growthStep : 0
            scheduleGrowth(of: mote, fullScale: 1, delay: delay)
        }

        // Threads — named by endpoints so each is placed once. Pre-compute the
        // present edge names into a Set (mirrors the node dedup above) so reconcile
        // is O(edges), not O(edges × children); inserting as we go also dedupes any
        // repeat within this pass.
        var presentEdges = Set(container.children.compactMap(\.name).filter { $0.hasPrefix("edge:") })
        for edge in model.edges {
            let name = "edge:\(edge.from.uuidString):\(edge.to.uuidString):\(edge.relation)"
            guard presentEdges.insert(name).inserted else { continue }
            guard let a = model.node(edge.from), let b = model.node(edge.to) else { continue }
            let thread = makeThread(from: a.position * spread, to: b.position * spread)
            thread.name = name
            container.addChild(thread)
        }
    }

    private func makeMote(_ node: ConstellationNode) -> ModelEntity {
        let mesh = MeshResource.generateSphere(radius: node.radius * moteScale)
        // Material.Color is NSColor / UIColor per platform; the palette hands
        // back whichever one this build has (both shells get coloured motes).
        let material = UnlitMaterial(
            color: ConstellationPalette.materialColor(forHue: node.hue, saturation: node.saturation)
        )
        let mote = ModelEntity(mesh: mesh, materials: [material])
        mote.position = node.position * spread
        mote.scale = SIMD3<Float>(repeating: 0.001) // collapsed until its turn
        return mote
    }

    private func makeThread(from: SIMD3<Float>, to: SIMD3<Float>) -> ModelEntity {
        let length = ConstellationGeometry.distance(from, to)
        // A thin box used as a line; +Y is its long axis (matches the geometry helper).
        let mesh = MeshResource.generateBox(size: SIMD3<Float>(0.01, max(length, 0.0001), 0.01))
        var material = SimpleMaterial(color: .init(white: 0.6, alpha: 1.0), isMetallic: false)
        material.roughness = 1.0
        let thread = ModelEntity(mesh: mesh, materials: [material])
        thread.position = ConstellationGeometry.midpoint(from, to)
        thread.orientation = ConstellationGeometry.orientation(from: from, to: to)
        return thread
    }

    /// Animate a mote from collapsed to full scale, staggered by `delay`.
    private func scheduleGrowth(of entity: Entity, fullScale: Float, delay: TimeInterval) {
        let target = Transform(
            scale: SIMD3<Float>(repeating: fullScale),
            rotation: entity.orientation,
            translation: entity.position
        )
        // Structured concurrency over DispatchQueue.main.asyncAfter: keeps the
        // non-Sendable Entity capture inside a proven @MainActor context (no Swift 6
        // strict-concurrency warning), and the growth cancels automatically when the
        // view's task tree tears down.
        Task { @MainActor [entity] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            entity.move(to: target, relativeTo: entity.parent, duration: 0.6, timingFunction: .easeOut)
        }
    }

    // MARK: - Interaction

    private var spinGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                root.orientation = storedOrientation * Self.spinDelta(value.translation)
            }
            .onEnded { value in
                storedOrientation *= Self.spinDelta(value.translation)
            }
    }

    /// Tracks the last-reconciled node/edge counts so the per-frame update can skip
    /// the (allocating, tree-walking) `sync` + `frameToFit` unless the field grew.
    private final class SyncTracker {
        private var nodes = -1
        private var edges = -1

        func changed(_ model: ConstellationModel) -> Bool {
            model.nodes.count != nodes || model.edges.count != edges
        }

        func note(_ model: ConstellationModel) {
            nodes = model.nodes.count
            edges = model.edges.count
        }
    }

    /// The incremental rotation for a drag translation: yaw about Y, pitch about X.
    private static func spinDelta(_ translation: CGSize) -> simd_quatf {
        let yaw = Float(translation.width) * 0.005
        let pitch = Float(translation.height) * 0.005
        return simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            * simd_quatf(angle: pitch, axis: SIMD3<Float>(1, 0, 0))
    }
}
