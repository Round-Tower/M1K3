//
//  ConstellationSeedingTests.swift
//  M1K3MemoryVizTests
//
//  Pins the one shared recipe both shells draw the sky from: seeds add but
//  never shadow the graph, the cap keeps the newest motes and runs BEFORE
//  affinity, related memories thread themselves, empty is empty.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-08, Confidence 0.85. Prior: Unknown.
//

import Foundation
import M1K3Memory
@testable import M1K3MemoryViz
import Testing

private func memory(_ text: String, at seconds: TimeInterval = 0) -> Memory {
    Memory(id: UUID(), kind: .note, text: text, source: "test", createdAt: Date(timeIntervalSince1970: seconds))
}

struct ConstellationSeedingTests {
    @Test("seeds add motes the graph lacks; a duplicate seed never shadows the graph row")
    func seedsAddNeverShadow() {
        let graph = [memory("Kev lives in Ardmore")]
        let seeds = [memory("kev lives in ardmore"), memory("Cartogram is a wallpaper app")]
        let model = ConstellationSeeding.build(graphMemories: graph, edges: [], seeds: seeds, maxNodes: 300)
        #expect(model.nodes.count == 2)
        #expect(model.nodes.contains { $0.id == graph[0].id })
    }

    @Test("the cap keeps the NEWEST motes, and is applied before affinity")
    func capKeepsNewest() {
        let old = memory("old fact about seals", at: 1)
        let mid = memory("mid fact about seals", at: 2)
        let new = memory("new fact about seals", at: 3)
        let model = ConstellationSeeding.build(graphMemories: [old, mid, new], edges: [], seeds: [], maxNodes: 2)
        let ids = Set(model.nodes.map(\.id))
        #expect(ids == [mid.id, new.id])
        // Affinity ran over the survivors only: no edge can reference the culled mote.
        #expect(!model.edges.contains { $0.from == old.id || $0.to == old.id })
    }

    @Test("topically related memories thread themselves even with no typed edges")
    func affinityThreads() {
        let a = memory("The hydraulic seal failed under load")
        let b = memory("Replace the hydraulic seal every spring")
        let c = memory("Pancakes on Sunday")
        let model = ConstellationSeeding.build(graphMemories: [a, b, c], edges: [], seeds: [], maxNodes: 300)
        #expect(model.edges.contains { ($0.from == a.id && $0.to == b.id) || ($0.from == b.id && $0.to == a.id) })
    }

    @Test("an empty world is an empty model")
    func emptyIsEmpty() {
        #expect(ConstellationSeeding.build(graphMemories: [], edges: [], seeds: [], maxNodes: 10).isEmpty)
    }
}
