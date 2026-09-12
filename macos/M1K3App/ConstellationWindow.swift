//
//  ConstellationWindow.swift
//  M1K3App
//
//  The window + menu command that open the 3D memory constellation. Pulls the
//  live graph from the store (allMemories + allEdges), builds the pure
//  ConstellationModel, and hands it to the RealityKit ConstellationView. The
//  layout/colour/geometry are all tested upstream in M1K3Memory / M1K3MemoryViz;
//  this is app glue (verify-by-run, like the other windows).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-16, Confidence 0.75 (compiles against
//  the viz target; the live look + the "grows over time" feel are Kev's ⌘R).
//  Prior: Unknown.
//  Review: Kev + claude-fable-5.1, 2026-09-08 — `buildSeeded` delegates to the lifted `ConstellationSeeding`
//  (M1K3MemoryViz) that the iPad canvas shares; behaviour byte-identical, pinned there. Confidence now 0.85.
//  Review: Kev + claude-fable-5.1, 2026-09-12 — the canvas takes an `AvatarPresence`: unmounted → no
//  RealityView (the render loop stops) and the store poll backs off to `ConstellationPollCadence.hidden`
//  (test-pinned); paused → the field's 30 fps clock stops; a re-shown field pops in without replaying the
//  accretion stagger. The windowed wrapper reads `\.windowVisible` for its own presence. Confidence now 0.85.

import M1K3Avatar
import M1K3Knowledge
import M1K3Memory
import M1K3MemoryViz
import SwiftUI

extension M1K3App {
    /// Stable id so the menu command summons (not respawns) the constellation.
    static let constellationWindowID = "constellation"
}

/// The constellation canvas — polls the store, seeds from the knowledge base,
/// renders the live field. Frameless so it serves every surface: the window, the
/// voice-mode hero, the main-window companion. (See ConstellationWindowContent
/// for the windowed wrapper.)
struct MemoryConstellationCanvas: View {
    let env: AppEnvironment?
    /// Mount / pause / animate (AvatarPresence, M1K3Avatar). The host resolves
    /// it from window visibility + treatment + Low Power; `.unmounted` keeps
    /// this canvas (and its polled model) alive but drops the RealityView.
    var presence: AvatarPresence = .animating
    @State private var model: ConstellationModel?
    /// The field has been on screen at least once this mount — a later re-show
    /// (window un-occluded) pops the motes in rather than replaying the
    /// accretion stagger from the opening beat.
    @State private var hasPresented = false
    /// Last seen store revision — the cheap change signal that gates a relayout.
    /// `revision` (not a bare count) so a SUPERSESSION (net-zero count) still
    /// redraws the field on a correction.
    @State private var lastRevision: MemoryRevision?

    /// Cap the field so a big store stays legible and the O(n²) layout stays cheap;
    /// the view shows the newest motes.
    private let maxNodes = 300
    /// Poll cadence for "grows over time": 2 s on screen, 10 s under thermal /
    /// low-power pressure (the O(n²) relayout is speculative — Cool Head knob 1),
    /// 30 s while nobody can see the field. Re-checked each tick.
    private let cadence = ConstellationPollCadence()

    var body: some View {
        Group {
            if let model {
                if model.isEmpty {
                    ContentUnavailableView(
                        "No memories yet",
                        systemImage: "sparkles",
                        description: Text("As M1K3 remembers things, they appear here as a constellation that grows over time.")
                    )
                } else if presence.isMounted {
                    ConstellationView(model: model, growthStep: hasPresented ? 0 : 0.08, paused: presence.isPaused)
                        .onAppear { hasPresented = true }
                } else {
                    // Unmounted: the model stays, the RealityView goes.
                    Color.clear
                }
            } else {
                ProgressView("Mapping memory…")
            }
        }
        // Keyed on mount state so the poll loop restarts at the new cadence
        // the moment the window hides or returns (the closure captures `presence`).
        .task(id: presence.isMounted) { await watch() }
    }

    /// Poll the store while the window is open, relaying out only when the live
    /// memory count actually changes — so a new `remember` makes a mote appear
    /// within a couple of seconds, but an idle window does no work.
    private func watch() async {
        await rebuildIfChanged()
        while !Task.isCancelled {
            let interval = cadence.interval(
                hidden: !presence.isMounted, throttled: !AppEnvironment.backgroundWorkAllowed()
            )
            try? await Task.sleep(for: interval)
            await rebuildIfChanged()
        }
    }

    /// Poll the store and relayout only when its revision actually moves. The
    /// GRDB reads + the O(n²) layout run on a utility task (the stores are
    /// `@unchecked Sendable` GRDB handles, captured off the non-Sendable view);
    /// only the two `@State` mutations hop back to the MainActor. No main-thread IO.
    private func rebuildIfChanged() async {
        guard let memoryStore = env?.memoryStore else {
            // No graph store yet — seed from the knowledge base once so the
            // window isn't blank (no revision to track on this path).
            guard model == nil else { return }
            let knowledge = env?.store
            let cap = maxNodes
            model = await Task.detached(priority: .utility) {
                Self.buildSeeded(graphMemories: [], edges: [], knowledge: knowledge, maxNodes: cap)
            }.value
            return
        }
        let knowledge = env?.store
        let previous = lastRevision
        let alreadyBuilt = model != nil
        let cap = maxNodes

        let result: (revision: MemoryRevision, model: ConstellationModel)? = await Task.detached(priority: .utility) {
            let revision = (try? memoryStore.revision())
                ?? MemoryRevision(memoryCount: 0, edgeCount: 0, latestCreatedAt: 0)
            // Nothing changed and the field is already drawn → no work.
            if revision == previous, alreadyBuilt { return nil }
            let memories = (try? memoryStore.allMemories(limit: 2000)) ?? []
            let edges = (try? memoryStore.allEdges()) ?? []
            let model = Self.buildSeeded(
                graphMemories: memories, edges: edges, knowledge: knowledge, maxNodes: cap
            )
            return (revision, model)
        }.value

        guard let result else { return }
        lastRevision = result.revision
        model = result.model
    }

    /// Lay out the live graph UNIONed with existing `.memory` items from the
    /// knowledge base — so the constellation shows what M1K3 already knows on
    /// first open, then grows as the graph store fills (dedup keeps dual-written
    /// facts from showing twice). Pure + `static` so it runs off the MainActor.
    private nonisolated static func buildSeeded(
        graphMemories: [Memory], edges: [MemoryEdge], knowledge: KnowledgeStore?, maxNodes: Int
    ) -> ConstellationModel {
        // The recipe (merge → cap-before-affinity → typed ∪ affinity edges →
        // layout) lives in `ConstellationSeeding` (M1K3MemoryViz) since the
        // iPad canvas joined (2026-09-08) — one sky, two shells.
        ConstellationSeeding.build(
            graphMemories: graphMemories, edges: edges, seeds: knowledgeSeeds(from: knowledge), maxNodes: maxNodes
        )
    }

    /// Existing memories from the document/knowledge store, mapped to motes.
    /// They carry no edges (the graph layer is the new store's job) — a scattered
    /// field that threads itself together as relations accrue.
    private nonisolated static func knowledgeSeeds(from knowledge: KnowledgeStore?) -> [Memory] {
        guard let knowledge else { return [] }
        let items = (try? knowledge.allItems(kind: .memory, limit: 500)) ?? []
        return items.map { item in
            Memory(id: item.id, kind: .note, text: item.title, source: "knowledge", createdAt: item.createdAt)
        }
    }
}

/// The windowed wrapper — the canvas at a window's size, opened from the menu.
struct ConstellationWindowContent: View {
    let env: AppEnvironment?
    @Environment(\.windowVisible) private var windowVisible

    var body: some View {
        MemoryConstellationCanvas(env: env, presence: windowVisible ? .animating : .unmounted)
            .frame(minWidth: 640, minHeight: 480)
            .navigationTitle("Memory Constellation")
    }
}

/// Adds "Memory Constellation" to the Window menu.
struct ConstellationCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .windowList) {
            ConstellationMenuItem()
        }
    }
}

private struct ConstellationMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Memory Constellation") {
            openWindow(id: M1K3App.constellationWindowID)
        }
    }
}
