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
        to root: Entity
    ) -> Bool {
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
