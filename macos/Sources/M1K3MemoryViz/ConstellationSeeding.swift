//
//  ConstellationSeeding.swift
//  M1K3MemoryViz
//
//  The one recipe that turns "what the stores hold" into a drawable field:
//  graph memories ∪ knowledge seeds (dedup, graph wins) → cap to the newest
//  `maxNodes` BEFORE affinity (O(n²), so only survivors are scored) → the
//  typed edges ∪ soft topical-affinity edges → layout. Lifted out of the Mac's
//  MemoryConstellationCanvas so the iPad canvas (hit list 2026-09-08, item 6)
//  composes the exact same field instead of a copy that drifts.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-08, Confidence 0.85 (pure; the
//  cap-before-affinity order and graph-wins dedup are pinned; the Mac host
//  now calls this, so the two shells cannot disagree). Prior: the Mac's
//  MemoryConstellationCanvas.buildSeeded (Kev + claude-fable-5, 2026-06-17).
//

import Foundation
import M1K3Memory

public enum ConstellationSeeding {
    /// `graphMemories` + `edges` are the live MemoryStore graph; `seeds` are
    /// edge-less motes from elsewhere (the knowledge base's `.memory` items) that
    /// only ADD, never shadow. Nothing here touches a store — callers read on
    /// whatever queue suits them and hand the rows in.
    public static func build(
        graphMemories: [Memory],
        edges: [MemoryEdge],
        seeds: [Memory],
        maxNodes: Int
    ) -> ConstellationModel {
        let merged = ConstellationSeed.merge(graph: graphMemories, seeds: seeds)
        let capped = merged.count > maxNodes
            ? Array(merged.sorted { $0.createdAt > $1.createdAt }.prefix(maxNodes))
            : merged
        let affinity = MemoryAffinity.edges(among: capped)
        return ConstellationLayout.build(memories: capped, edges: edges + affinity, maxNodes: maxNodes)
    }
}
