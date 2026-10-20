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
//  Review: Kev + claude-opus-5-5, 2026-10-20 — once the motes have grown in, the field bakes into one mesh per
//  colour plus one for the threads (ConstellationBake): ~1,000 entities drew every frame, holding an idle M1K3
//  at ~132% CPU against the Fox's ~65%. Growth still animates per mote; a later bake folds the newcomers in.
//  Placement is tracked in SyncTracker, not read off the children the bake replaces. Confidence 0.75.

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
    /// A thread's thickness, as the per-edge box drew it.
    private let threadThickness: Float = 0.01

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
                let growth = sync(into: field, firstBuild: true)
                frameToFit()
                syncTracker.note(model)
                scheduleBake(after: growth)
            } update: { _ in
                // The model only GROWS (sync is additive, entities named by id), so a
                // node/edge count change is a reliable "something new" signal. Reconcile
                // + re-frame ONLY then — the old code walked the whole entity tree
                // (visualBounds) and allocated dedup Sets EVERY frame just to discover
                // nothing was new. The idle breath/float/rotation still ticks per frame
                // (three trig ops — cheap), so the field stays alive at rest.
                if syncTracker.changed(model) {
                    let growth = sync(into: field, firstBuild: false)
                    frameToFit()
                    syncTracker.note(model)
                    scheduleBake(after: growth)
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

    /// Idempotent reconcile: place any node/edge not placed yet. Placement is
    /// tracked by id so re-running is cheap and additive — the heart of the
    /// "grows over time" effect. On the first build motes stagger in along the
    /// accretion timeline; motes added later just pop in. Returns how long the
    /// growth it started runs, so the bake waits for it.
    private func sync(into container: Entity, firstBuild: Bool) -> TimeInterval {
        let growthIndex = Dictionary(
            uniqueKeysWithValues: model.growthOrder.enumerated().map { ($1, $0) }
        )
        var longest: TimeInterval = 0
        for node in model.nodes where syncTracker.placedNodes.insert(node.id).inserted {
            let mote = makeMote(node)
            container.addChild(mote)
            let delay = firstBuild ? Double(growthIndex[node.id] ?? 0) * growthStep : 0
            scheduleGrowth(of: mote, fullScale: 1, delay: delay)
            longest = max(longest, delay + Self.growthDuration)
        }

        // Threads — keyed by endpoints + relation so each is placed once, which also
        // dedupes any repeat within this pass.
        for edge in model.edges {
            guard let a = model.node(edge.from), let b = model.node(edge.to) else { continue }
            let key = "\(edge.from.uuidString):\(edge.to.uuidString):\(edge.relation)"
            guard syncTracker.placedEdges.insert(key).inserted else { continue }
            container.addChild(makeThread(from: a.position * spread, to: b.position * spread))
        }
        return longest
    }

    // MARK: - Bake

    /// Bake once the growth `sync` started has finished (plus a beat). A newer
    /// schedule supersedes an older one, so a burst of new memories bakes once.
    private func scheduleBake(after growth: TimeInterval) {
        syncTracker.bakeGeneration += 1
        let generation = syncTracker.bakeGeneration
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(growth + 0.25))
            guard syncTracker.bakeGeneration == generation else { return }
            bake()
        }
    }

    /// Swap every placed mote and thread for merged meshes: one per mote colour,
    /// one for the threads. Same positions, sizes and materials, a few draws.
    private func bake() {
        let placed = model.nodes.filter { syncTracker.placedNodes.contains($0.id) }
        let motes = placed.map { node in
            ConstellationBake.Mote(
                center: node.position * spread,
                radius: node.radius * moteScale,
                colour: .init(hue: node.hue, saturation: node.saturation)
            )
        }
        let ends: [(SIMD3<Float>, SIMD3<Float>)] = model.edges.compactMap { edge in
            let key = "\(edge.from.uuidString):\(edge.to.uuidString):\(edge.relation)"
            guard syncTracker.placedEdges.contains(key),
                  let a = model.node(edge.from), let b = model.node(edge.to) else { return nil }
            return (a.position * spread, b.position * spread)
        }
        var baked: [ModelEntity] = []
        for (colour, parts) in ConstellationBake.motes(motes) {
            let material = UnlitMaterial(
                color: ConstellationPalette.materialColor(forHue: colour.hue, saturation: colour.saturation)
            )
            if let entity = Self.entity(parts, material: material) { baked.append(entity) }
        }
        if let entity = Self.entity(ConstellationBake.threads(ends, thickness: threadThickness), material: threadMaterial) {
            baked.append(entity)
        }
        // Build first, then swap, so a failed mesh leaves the live entities drawing.
        guard !baked.isEmpty else { return }
        for child in Array(field.children) {
            child.removeFromParent()
        }
        for entity in baked {
            field.addChild(entity)
        }
    }

    private static func entity(_ parts: ConstellationBake.Parts, material: any RealityKit.Material) -> ModelEntity? {
        guard !parts.positions.isEmpty else { return nil }
        var descriptor = MeshDescriptor(name: "constellation")
        descriptor.positions = MeshBuffers.Positions(parts.positions)
        descriptor.normals = MeshBuffers.Normals(parts.normals)
        descriptor.primitives = .triangles(parts.indices)
        guard let mesh = try? MeshResource.generate(from: [descriptor]) else { return nil }
        return ModelEntity(mesh: mesh, materials: [material])
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
        let mesh = MeshResource.generateBox(size: SIMD3<Float>(threadThickness, max(length, 0.0001), threadThickness))
        let thread = ModelEntity(mesh: mesh, materials: [threadMaterial])
        thread.position = ConstellationGeometry.midpoint(from, to)
        thread.orientation = ConstellationGeometry.orientation(from: from, to: to)
        return thread
    }

    private var threadMaterial: SimpleMaterial {
        var material = SimpleMaterial(color: .init(white: 0.6, alpha: 1.0), isMetallic: false)
        material.roughness = 1.0
        return material
    }

    private static let growthDuration: TimeInterval = 0.6

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
            entity.move(to: target, relativeTo: entity.parent, duration: Self.growthDuration, timingFunction: .easeOut)
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
    /// the (allocating, tree-walking) `sync` + `frameToFit` unless the field grew,
    /// what is placed (the bake replaces the per-mote entities, so the children
    /// can't say), and which scheduled bake is current.
    private final class SyncTracker {
        private var nodes = -1
        private var edges = -1
        var placedNodes: Set<UUID> = []
        var placedEdges: Set<String> = []
        var bakeGeneration = 0

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
