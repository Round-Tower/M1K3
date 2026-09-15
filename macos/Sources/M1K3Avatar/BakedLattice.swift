//
//  BakedLattice.swift
//  M1K3Avatar
//
//  Which material slots of a loaded companion draw the Phosphor Fox's baked
//  lattice — the pure decision behind the app's phosphor-green tint.
//
//  The 09-12 tint matched ENTITY names ("fox_wire"). RealityKit, though, MERGES
//  a SkelRoot's skinned meshes into one ModelEntity named after the SkelRoot
//  ('root'); the `fox_wire` / `fox_wire_mesh` entities survive with no
//  ModelComponent, so the tint found the name, had nothing to paint, and every
//  surface kept the neutral 0xe8e8e8 wire — the grey fox in the App Store plates.
//  The merged mesh keeps the prim names on its PARTS ('fox1' → slot 0,
//  'fox_wire_mesh' → slot 1, probed on Survey/Walk/Run), so the part names decide.
//
//  Signed: Kev + claude-opus-5, 2026-09-15, Confidence 0.85 (layout read off the
//  shipped USDZs by a RealityKit probe; the on-screen green is verify-by-launch),
//  Prior: Unknown
//

public enum BakedLattice {
    /// One mesh part of a loaded model: its id (the source prim's name) and the
    /// material slot it draws with.
    public struct Part: Sendable, Equatable {
        public let id: String
        public let materialIndex: Int

        public init(id: String, materialIndex: Int) {
            self.id = id
            self.materialIndex = materialIndex
        }
    }

    /// The name the lattice carries in every layout the pipeline emits — the
    /// Xform and its mesh prim (`tools/companion-pipeline/build_phosphor_fox.py`).
    public static let marker = "fox_wire"

    /// The material slots that draw the lattice. An entity named for the lattice
    /// (an unskinned layout) owns every slot; otherwise only the slots of parts
    /// named for it. Slots outside `0..<materialCount` are dropped.
    public static func slots(entityName: String, parts: [Part], materialCount: Int) -> Set<Int> {
        guard materialCount > 0 else { return [] }
        if entityName.lowercased().contains(marker) {
            return Set(0 ..< materialCount)
        }
        return Set(
            parts
                .filter { $0.id.lowercased().contains(marker) }
                .map(\.materialIndex)
                .filter { (0 ..< materialCount).contains($0) }
        )
    }
}
