//
//  MemoryConstellationCanvas.swift
//  M1K3iOS / M1K3visionOS
//
//  The iPad's memory constellation (hit list 2026-09-08, item 6) — the Mac's
//  MemoryConstellationCanvas, same field, same recipe: poll the memory store's
//  revision, and only when it moves, read graph + knowledge seeds off the main
//  actor and rebuild through the ONE shared builder (`ConstellationSeeding`,
//  M1K3MemoryViz) so the two shells can never draw different skies from the
//  same stores. No thermal back-off here: the Mac's Cool Head knob has no
//  mobile sibling yet, so the poll is a flat 3 s.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-08, Confidence 0.75 (a port of the
//  Mac host onto the lifted builder; the RealityKit field on an actual iPad
//  is verify-by-launch — the simulator has no Metal). Prior: the Mac's
//  ConstellationWindow.swift (Kev + claude-fable-5, 2026-06-17).
//

import M1K3Knowledge
import M1K3Memory
import M1K3MemoryViz
import SwiftUI

struct MemoryConstellationCanvas: View {
    @Environment(AppCore.self) private var core
    @State private var model: ConstellationModel?
    @State private var lastRevision: MemoryRevision?

    private let maxNodes = 300
    private let refresh: Duration = .seconds(3)

    var body: some View {
        Group {
            if let model {
                if model.isEmpty {
                    ContentUnavailableView(
                        "No memories yet",
                        systemImage: "sparkles",
                        description: Text("As M1K3 remembers things, they appear here as a constellation.")
                    )
                } else {
                    ConstellationView(model: model)
                }
            } else {
                ProgressView("Mapping memory…")
            }
        }
        .task { await watch() }
    }

    private func watch() async {
        await rebuildIfChanged()
        while !Task.isCancelled {
            try? await Task.sleep(for: refresh)
            await rebuildIfChanged()
        }
    }

    /// GRDB reads + the O(n²) layout on a utility task; only the two `@State`
    /// writes land back on the main actor.
    private func rebuildIfChanged() async {
        let knowledge = core.store
        let cap = maxNodes
        guard let memoryStore = core.memoryStore else {
            guard model == nil else { return }
            model = await Task.detached(priority: .utility) {
                ConstellationSeeding.build(
                    graphMemories: [], edges: [], seeds: Self.knowledgeSeeds(from: knowledge), maxNodes: cap
                )
            }.value
            return
        }
        let previous = lastRevision
        let alreadyBuilt = model != nil
        let result: (revision: MemoryRevision, model: ConstellationModel)? = await Task.detached(priority: .utility) {
            let revision = (try? memoryStore.revision())
                ?? MemoryRevision(memoryCount: 0, edgeCount: 0, latestCreatedAt: 0)
            if revision == previous, alreadyBuilt { return nil }
            let memories = (try? memoryStore.allMemories(limit: 2000)) ?? []
            let edges = (try? memoryStore.allEdges()) ?? []
            let model = ConstellationSeeding.build(
                graphMemories: memories, edges: edges, seeds: Self.knowledgeSeeds(from: knowledge), maxNodes: cap
            )
            return (revision, model)
        }.value
        guard let result else { return }
        lastRevision = result.revision
        model = result.model
    }

    private nonisolated static func knowledgeSeeds(from knowledge: KnowledgeStore) -> [Memory] {
        let items = (try? knowledge.allItems(kind: .memory, limit: 500)) ?? []
        return items.map { item in
            Memory(id: item.id, kind: .note, text: item.title, source: "knowledge", createdAt: item.createdAt)
        }
    }
}
