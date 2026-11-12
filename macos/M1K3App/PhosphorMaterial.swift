//
//  PhosphorMaterial.swift
//  M1K3App
//
//  App glue for the companion shading styles: load a RealityKit CustomMaterial
//  surface shader (Phosphor.metal, compiled by Xcode into the app's
//  default.metallib) and paint it over a loaded companion's mesh tree. The look is
//  decided by the pure CompanionShadingStyle + PhosphorTreatment (M1K3Avatar);
//  this file is the RealityKit/Metal plumbing — verify-at-⌘R.
//
//  Cel ADAPTS the creature's own texture: its CustomMaterial is built FROM the
//  baked material (CustomMaterial(from:surfaceShader:) preserves the textures), so
//  the shader can sample the real fur. Phosphor is a monochrome glow that ignores
//  the texture, so it uses a cheap shared blank material. The baked materials are
//  snapshotted first so styles switch live — including restoring the textures when
//  switched back to Off — without reloading the companion.
//
//  Falls back gracefully: if a shader can't load (older OS, missing metallib),
//  apply() returns false and the caller keeps the current materials.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-18, Confidence 0.8 (shaders compile
//  against the RealityKit metal headers + load path is documented; the on-screen
//  result is verify-at-⌘R). Prior: Kev + claude-opus-4-8 (phosphor-only #46).
//  Review: Kev + claude-fable-5.1, 2026-09-12 — `tintBakedLattice`: the Phosphor Fox's wire mesh
//  gets an unlit phosphor-green material under every style's baseline. Confidence 0.75.
//  Review: Kev + claude-opus-5, 2026-09-15 — the tint never landed: RealityKit merges the skinned fox
//  into one ModelEntity ('root') and the `fox_wire` entities have no ModelComponent, so the name match
//  painted nothing and every plate kept the grey wire. The slot choice is now `BakedLattice.slots` by
//  mesh-part name (pinned; layout probed on the shipped USDZs), with a notice line when it lands.
//  Confidence 0.8 (the green on screen is verify-by-launch).
//  Review: Kev + claude-fable-5.1, 2026-09-15 (later) — `tintBakedLattice` REMOVED, with `BakedLattice`
//  (M1K3Avatar) and its tests. The green lattice was seen on the plates and rejected (Kev: "too
//  distracting — the white / original was better"); the Phosphor Fox keeps its baked neutral wire
//  (0xe8e8e8, `tools/companion-pipeline/build_phosphor_fox.py`). The RealityKit fact stays worth
//  knowing: a SkelRoot's skinned meshes merge into ONE ModelEntity whose PARTS keep the prim names.
//  Confidence 0.9.
//  Review: Kev + claude-opus-5-5, 2026-10-22 — the site Fox (Kev: "go with the site fox, it's iconic"): a model
//  with a baked lattice part paints its body unlit black and its lattice unlit (white, or the season's colour under
//  phosphor), by mesh-part name via SiteFoxPaint. Seen on the iPhone Simulator; the Mac is verify-by-launch.
//  Confidence 0.8.
//  Review: Kev + claude-fable-5.2, 2026-11-12 — the speaking halo (`SpeakingGlow`; Kev: "so the Phosphor fox
//  almost glows - and could do something similar for the other Avatars"). `addHalo` gives a loaded creature a
//  SHELL: a copy of every mesh part with smoothed normals, in one extra material slot, so it rides the skeleton.
//  `apply` re-seats the shell's material after every repaint (each paint path rewrites the slots), and
//  `setHalo` writes the level. With no shell (the mesh could not be rebuilt) nothing changes. Confidence 0.6:
//  the shell following a skinned mesh is tried by launch on the Mac; the iPhone is owed.
//

import M1K3Avatar
import Metal
import os
import RealityKit

@MainActor
enum PhosphorMaterial {
    private static let log = Logger(subsystem: "app.m1k3", category: "phosphor")

    /// The app's default.metallib, loaded once. `libraryFailed` latches so a
    /// missing metallib is logged once, not on every companion build.
    private static var library: MTLLibrary?
    private static var libraryFailed = false

    /// Per-function blank-material cache for texture-agnostic styles (phosphor),
    /// stored UNTINTED — apply() copies + tints. `failed` latches a bad function.
    private static var blankCache: [String: CustomMaterial] = [:]
    private static var failed: Set<String> = []

    private static func loadedLibrary() -> MTLLibrary? {
        if let library { return library }
        if libraryFailed { return nil }
        guard let device = MTLCreateSystemDefaultDevice() else {
            libraryFailed = true
            log.error("phosphor: no Metal device")
            return nil
        }
        do {
            let lib = try device.makeDefaultLibrary(bundle: .main)
            library = lib
            return lib
        } catch {
            libraryFailed = true
            log.error("phosphor: no default.metallib in app bundle (\(error.localizedDescription, privacy: .public))")
            return nil
        }
    }

    private static func surfaceShader(_ function: String) -> CustomMaterial.SurfaceShader? {
        guard let lib = loadedLibrary() else { return nil }
        return CustomMaterial.SurfaceShader(named: function, in: lib)
    }

    /// Snapshot the baked materials per ModelEntity so styles can be switched live:
    /// cel rebuilds its CustomMaterials FROM these (preserving the fur texture), and
    /// Off restores them. Call once, right after the companion loads.
    static func snapshotMaterials(of root: Entity) -> [ObjectIdentifier: [any RealityKit.Material]] {
        var out: [ObjectIdentifier: [any RealityKit.Material]] = [:]
        func walk(_ entity: Entity) {
            if let model = entity.components[ModelComponent.self] {
                out[ObjectIdentifier(entity)] = model.materials
            }
            for child in entity.children {
                walk(child)
            }
        }
        walk(root)
        return out
    }

    /// Paint `style` over the companion. `originals` is the baked snapshot. Returns
    /// false (caller keeps current materials) only when a shader can't load.
    @discardableResult
    static func apply(
        _ style: CompanionShadingStyle,
        treatment: PhosphorTreatment,
        originals: [ObjectIdentifier: [any RealityKit.Material]],
        halo: Halo? = nil,
        glow: (shape: SpeakingGlow, level: Float) = (.off, 0),
        to root: Entity
    ) -> Bool {
        // Every paint path below rewrites the material slots, the shell's included: put the
        // halo back afterwards, whatever was painted.
        defer {
            if let halo {
                setHalo(
                    halo, glow: glow.shape, level: glow.level,
                    colour: SpeakingGlow.colour(style: style, treatment: treatment)
                )
            }
        }
        // The site Fox (SiteFoxPaint): a model with a baked lattice part gets black unlit triangles
        // and an unlit lattice, white by default and the season's colour under phosphor.
        if SiteFoxPaint.applies(toParts: meshPartNames(of: root), style: style) {
            paintSiteFox(root, lattice: SiteFoxPaint.latticeColour(style: style, treatment: treatment))
            return true
        }
        guard let function = style.shaderFunctionName else {
            restore(originals, onto: root) // .off — put the baked textures back
            return true
        }
        if style.usesOriginalTexture {
            guard let surface = surfaceShader(function) else { return false }
            paintTextured(surface: surface, value: treatment.customValue, originals: originals, onto: root)
        } else {
            guard var material = blank(function: function) else { return false }
            material.custom.value = treatment.customValue
            paint(material, onto: root)
        }
        return true
    }

    /// Every mesh-part name under `root`. The skinned Fox merges into ONE ModelEntity whose
    /// parts keep the prim names (fox1, fox_wire_mesh), so parts, not entities, carry the roles.
    private static func meshPartNames(of root: Entity) -> [String] {
        var names: [String] = []
        func walk(_ entity: Entity) {
            if let model = entity.components[ModelComponent.self] {
                for mesh in model.mesh.contents.models {
                    names += mesh.parts.map(\.id)
                }
            }
            for child in entity.children {
                walk(child)
            }
        }
        walk(root)
        return names
    }

    /// Paint each part by its SiteFoxPaint role: unlit black body, unlit lattice in `lattice`.
    private static func paintSiteFox(_ root: Entity, lattice: SIMD3<Float>) {
        func colour(_ rgb: SIMD3<Float>) -> RealityKit.Material.Color {
            RealityKit.Material.Color(red: CGFloat(rgb.x), green: CGFloat(rgb.y), blue: CGFloat(rgb.z), alpha: 1)
        }
        let body = UnlitMaterial(color: colour(SiteFoxPaint.bodyColour))
        let wire = UnlitMaterial(color: colour(lattice))
        func walk(_ entity: Entity) {
            if var model = entity.components[ModelComponent.self] {
                var materials: [any RealityKit.Material] = model.materials
                for mesh in model.mesh.contents.models {
                    for part in mesh.parts {
                        let slot = part.materialIndex
                        while materials.count <= slot {
                            materials.append(body)
                        }
                        materials[slot] = SiteFoxPaint.role(ofPart: part.id) == .lattice ? wire : body
                    }
                }
                model.materials = materials
                entity.components.set(model)
            }
            for child in entity.children {
                walk(child)
            }
        }
        walk(root)
    }

    private static func blank(function: String) -> CustomMaterial? {
        if let cached = blankCache[function] { return cached }
        if failed.contains(function) { return nil }
        guard let surface = surfaceShader(function) else {
            failed.insert(function)
            return nil
        }
        do {
            let material = try CustomMaterial(surfaceShader: surface, lightingModel: .lit)
            blankCache[function] = material
            return material
        } catch {
            failed.insert(function)
            log.error("phosphor: CustomMaterial '\(function, privacy: .public)' failed (\(error.localizedDescription, privacy: .public))")
            return nil
        }
    }

    /// Slot-preserving paint of one shared material (texture-agnostic styles).
    private static func paint(_ material: CustomMaterial, onto entity: Entity) {
        if var model = entity.components[ModelComponent.self] {
            model.materials = model.materials.isEmpty ? [material] : model.materials.map { _ in material }
            entity.components.set(model)
        }
        for child in entity.children {
            paint(material, onto: child)
        }
    }

    /// Build a CustomMaterial FROM each baked material (preserving its textures) so
    /// the cel shader can sample the real fur. Falls back to the original material
    /// per-slot if the from-init throws.
    private static func paintTextured(
        surface: CustomMaterial.SurfaceShader,
        value: SIMD4<Float>,
        originals: [ObjectIdentifier: [any RealityKit.Material]],
        onto entity: Entity
    ) {
        if var model = entity.components[ModelComponent.self] {
            let base = originals[ObjectIdentifier(entity)] ?? model.materials
            model.materials = base.map { original in
                guard var custom = try? CustomMaterial(from: original, surfaceShader: surface) else { return original }
                custom.custom.value = value
                return custom
            }
            entity.components.set(model)
        }
        for child in entity.children {
            paintTextured(surface: surface, value: value, originals: originals, onto: child)
        }
    }

    private static func restore(_ originals: [ObjectIdentifier: [any RealityKit.Material]], onto entity: Entity) {
        if var model = entity.components[ModelComponent.self], let baked = originals[ObjectIdentifier(entity)] {
            model.materials = baked
            entity.components.set(model)
        }
        for child in entity.children {
            restore(originals, onto: child)
        }
    }
}

// MARK: - The speaking halo

extension PhosphorMaterial {
    /// A loaded creature's halo shell: which entities carry it, and in which material slot.
    struct Halo {
        /// Each entity's FIRST shell slot; shell `n` sits in slot `first + n`.
        fileprivate var slots: [(entity: Entity, first: Int)]
        /// The nested shells, innermost first (`SpeakingGlow.shells`).
        let shells: [SpeakingGlow.Shell]
    }

    /// The prefix of a shell part's id. It must never read as a lattice part (SiteFoxPaint).
    private static let haloPartPrefix = "m1k3_halo_"

    /// Give `root` a halo shell: every mesh part copied with smoothed normals into one new
    /// material slot per entity. Call once, right after `snapshotMaterials`. Returns nil,
    /// leaving the creature untouched, when a mesh cannot be rebuilt or the shader is missing.
    static func addHalo(to root: Entity) -> Halo? {
        guard haloMaterial(glow: .zero, colour: SiteFoxPaint.siteWhite) != nil else { return nil }
        var extent: Float = 0
        func measure(_ entity: Entity) {
            if let model = entity.components[ModelComponent.self] {
                extent = max(extent, model.mesh.bounds.extents.max())
            }
            for child in entity.children {
                measure(child)
            }
        }
        measure(root)
        let shells = SpeakingGlow.shells(forExtent: extent)
        var slots: [(entity: Entity, first: Int)] = []
        func walk(_ entity: Entity) {
            if var model = entity.components[ModelComponent.self] {
                let first = max(model.materials.count, (maxMaterialIndex(of: model.mesh) ?? -1) + 1)
                if let mesh = meshWithShells(model.mesh, firstSlot: first, count: shells.count) {
                    model.mesh = mesh
                    entity.components.set(model)
                    slots.append((entity, first))
                }
            }
            for child in entity.children {
                walk(child)
            }
        }
        walk(root)
        guard !slots.isEmpty else { return nil }
        log.notice("halo: \(shells.count, privacy: .public) shell(s) on \(slots.count, privacy: .public) mesh(es), extent \(extent, privacy: .public)")
        return Halo(slots: slots, shells: shells)
    }

    /// Seat the shell's material with this level and colour. Cheap enough for a ramp's few
    /// steps; never call it per frame.
    static func setHalo(_ halo: Halo, glow: SpeakingGlow, level: Float, colour: SIMD3<Float>) {
        let layers = halo.shells.compactMap {
            haloMaterial(glow: glow.customValue(level: level, shell: $0), colour: colour)
        }
        guard layers.count == halo.shells.count, let filler = layers.first else { return }
        for (entity, first) in halo.slots {
            guard var model = entity.components[ModelComponent.self] else { continue }
            var materials = model.materials
            while materials.count < first + layers.count {
                materials.append(filler)
            }
            for (offset, layer) in layers.enumerated() {
                materials[first + offset] = layer
            }
            model.materials = materials
            entity.components.set(model)
        }
    }

    private static var haloBase: CustomMaterial?
    private static var haloFailed = false

    private static func haloMaterial(glow: SIMD4<Float>, colour: SIMD3<Float>) -> CustomMaterial? {
        if haloBase == nil, !haloFailed {
            do {
                guard let lib = loadedLibrary() else { throw CocoaError(.fileNoSuchFile) }
                var material = try CustomMaterial(
                    surfaceShader: .init(named: "haloSurface", in: lib),
                    geometryModifier: .init(named: "haloGeometry", in: lib),
                    lightingModel: .unlit
                )
                // Front faces culled: the body hides the shell except beyond its outline.
                material.faceCulling = .front
                material.blending = .transparent(opacity: 1.0)
                haloBase = material
            } catch {
                haloFailed = true
                log.error("halo: material failed (\(error.localizedDescription, privacy: .public))")
            }
        }
        guard var material = haloBase else { return nil }
        material.custom.value = glow
        material.emissiveColor = .init(color: RealityKit.Material.Color(
            red: CGFloat(colour.x), green: CGFloat(colour.y), blue: CGFloat(colour.z), alpha: 1
        ))
        return material
    }

    private static func maxMaterialIndex(of mesh: MeshResource) -> Int? {
        mesh.contents.models.flatMap { $0.parts.map(\.materialIndex) }.max()
    }

    /// `mesh` with `count` shells beside it: every body model copied as shell MODELS (same skeleton
    /// and joint influences, smoothed normals, one material slot per shell from `firstSlot`), each
    /// placed by a copy of the model's instances. A part added to an existing model is dropped by
    /// the rebuild (probed 2026-11-12), so the shells are their own models. nil when it cannot
    /// be rebuilt.
    private static func meshWithShells(_ mesh: MeshResource, firstSlot: Int, count: Int) -> MeshResource? {
        var contents = mesh.contents
        var models = contents.models
        var instances = contents.instances
        var added = 0
        for model in contents.models where !model.id.hasPrefix(haloPartPrefix) {
            // The body only: a wire lattice has no outside to push toward, and its shell is shards.
            let body = model.parts.filter { SiteFoxPaint.role(ofPart: $0.id) == .body }
            guard !body.isEmpty else { continue }
            let smoothed = body.map { smoothedNormals(of: $0) }
            for layer in 0 ..< count {
                let prefix = "\(haloPartPrefix)\(layer)_"
                let parts = zip(body, smoothed).map { part, normals in
                    var shell = part
                    shell.id = prefix + part.id
                    shell.materialIndex = firstSlot + layer
                    shell.normals = MeshBuffers.Normals(normals)
                    return shell
                }
                models.insert(MeshResource.Model(id: prefix + model.id, parts: parts))
                for instance in contents.instances where instance.model == model.id {
                    instances.insert(MeshResource.Instance(
                        id: prefix + instance.id, model: prefix + model.id, at: instance.transform
                    ))
                    added += 1
                }
            }
        }
        guard added > 0 else { return nil }
        contents.models = models
        contents.instances = instances
        do {
            return try MeshResource.generate(from: contents)
        } catch {
            log.error("halo: mesh rebuild failed (\(error.localizedDescription, privacy: .public))")
            return nil
        }
    }

    /// One normal per POSITION: a faceted mesh splits its vertices per face, and a shell pushed
    /// out along split normals cracks open at every edge. Averaging by position keeps it closed.
    private static func smoothedNormals(of part: MeshResource.Part) -> [SIMD3<Float>] {
        let positions = part.positions.elements
        let normals = part.normals?.elements ?? []
        guard normals.count == positions.count else {
            return positions.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3(0, 1, 0) }
        }
        struct Key: Hashable { let x, y, z: Int32 }
        func key(_ p: SIMD3<Float>) -> Key {
            Key(x: Int32((p.x * 10000).rounded()), y: Int32((p.y * 10000).rounded()), z: Int32((p.z * 10000).rounded()))
        }
        var sums: [Key: SIMD3<Float>] = [:]
        for (position, normal) in zip(positions, normals) {
            sums[key(position), default: .zero] += normal
        }
        return zip(positions, normals).map { position, normal in
            let sum = sums[key(position)] ?? normal
            return simd_length(sum) > 1e-6 ? simd_normalize(sum) : normal
        }
    }
}
