//
//  BakedLatticeTests.swift
//  M1K3AvatarTests
//
//  Pins which material slots draw the Phosphor Fox's baked lattice. The 09-12
//  tint matched ENTITY names, but RealityKit merges a SkelRoot's skinned meshes
//  into one ModelEntity named after the SkelRoot; the `fox_wire` entities
//  survive with no ModelComponent, so the tint painted nothing and every
//  screenshot kept the grey wire. Probed on the shipped USDZs (Survey, Walk,
//  Run): one entity 'root', parts 'fox1' → slot 0 and 'fox_wire_mesh' → slot 1.
//
//  Signed: Kev + claude-opus-5, 2026-09-15, Confidence 0.85 (the layout is read
//  off the shipped assets by a RealityKit probe; the green on screen is
//  verify-by-launch), Prior: Unknown
//

@testable import M1K3Avatar
import Testing

struct BakedLatticeTests {
    @Test("the skinned fox: the merged entity's lattice part owns its slot, the body keeps its own")
    func skinnedLayoutPicksThePartSlot() {
        let slots = BakedLattice.slots(
            entityName: "root",
            parts: [.init(id: "fox1", materialIndex: 0), .init(id: "fox_wire_mesh", materialIndex: 1)],
            materialCount: 2
        )
        #expect(slots == [1])
    }

    @Test("an unskinned layout: an entity named for the lattice owns every slot")
    func latticeEntityOwnsEverySlot() {
        let slots = BakedLattice.slots(entityName: "fox_wire_mesh", parts: [], materialCount: 1)
        #expect(slots == [0])
    }

    @Test("a creature with no lattice is left alone")
    func otherCreaturesAreUntouched() {
        let slots = BakedLattice.slots(
            entityName: "root",
            parts: [.init(id: "Gecko_body", materialIndex: 0)],
            materialCount: 1
        )
        #expect(slots.isEmpty)
    }

    @Test("a part pointing past the material list is ignored, never an out-of-range write")
    func outOfRangeSlotIsIgnored() {
        let slots = BakedLattice.slots(
            entityName: "root",
            parts: [.init(id: "fox_wire_mesh", materialIndex: 5)],
            materialCount: 2
        )
        #expect(slots.isEmpty)
        #expect(BakedLattice.slots(entityName: "fox_wire", parts: [], materialCount: 0).isEmpty)
    }
}
