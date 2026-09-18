//
//  ConstellationSeedingTests.swift
//  M1K3MemoryVizTests
//
//  Pins the one shared recipe both shells draw the sky from: seeds add but
//  never shadow the graph, the cap keeps the newest motes and runs BEFORE
//  affinity, related memories thread themselves, empty is empty.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-08, Confidence 0.85. Prior: Unknown.
//  Review: Kev + claude-fable-5.1, 2026-09-18 — two pins: a typed + an affinity edge between the same pair draw ONE thread (the typed
//  one, in either direction), and affinity still threads the pairs the typed graph leaves uncovered. Both red first. Confidence 0.9.
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

    @Test("a typed edge and an affinity edge between the SAME two memories draw ONE thread, and the typed one wins")
    func noDoubledThreads() {
        // Related memories thread themselves (affinity) — and the user, or the
        // distiller, may ALSO have linked them. `edges + affinity` with no dedupe drew
        // two lines on top of each other for that pair, in either direction (found by
        // a review of the screengrab seed, #383 — but it is every user's sky).
        let a = memory("The hydraulic seal failed under load")
        let b = memory("Replace the hydraulic seal every spring")
        let c = memory("Pancakes on Sunday")
        let typed = MemoryEdge(fromID: b.id, toID: a.id, relation: "caused-by") // note: b → a
        let model = ConstellationSeeding.build(graphMemories: [a, b, c], edges: [typed], seeds: [], maxNodes: 300)
        let between = model.edges.filter { Set([$0.from, $0.to]) == Set([a.id, b.id]) }
        #expect(between.count == 1)
        #expect(between.first?.from == b.id && between.first?.to == a.id, "the typed edge is the one kept")
    }

    @Test("affinity still threads a pair the typed edges do not cover")
    func affinityStillFillsTheGaps() {
        let a = memory("The hydraulic seal failed under load")
        let b = memory("Replace the hydraulic seal every spring")
        let c = memory("The hydraulic press needs a new seal")
        let typed = MemoryEdge(fromID: a.id, toID: b.id, relation: "related")
        let model = ConstellationSeeding.build(graphMemories: [a, b, c], edges: [typed], seeds: [], maxNodes: 300)
        #expect(model.edges.contains { Set([$0.from, $0.to]) == Set([a.id, c.id]) || Set([$0.from, $0.to]) == Set([b.id, c.id]) })
        #expect(model.edges.count(where: { Set([$0.from, $0.to]) == Set([a.id, b.id]) }) == 1)
    }
}
