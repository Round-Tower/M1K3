//
//  MemoriesScreen.swift
//  M1K3iOS / M1K3visionOS
//
//  The temporal memory graph, on mobile: a live fact count and a hybrid recall
//  search (FTS + cosine, RRF-fused with a similarity cutoff — the same MemoryStore
//  query the MCP recall_memory tool runs). Read-only for v1; capture happens
//  through chat auto-distillation, not a form.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-06, Confidence 0.75. Prior: Unknown.
//
//  Review: Kev + claude-fable-5.1, 2026-09-03 — cognitive-load cut: the description shows only while empty and lost its
//  privacy clause (Settings carries the guarantee; the search prompt carries the instruction).
//

import M1K3Knowledge
import M1K3Memory
import SwiftUI

struct MemoriesScreen: View {
    @Environment(AppCore.self) private var core
    @State private var query = ""
    @State private var hits: [MemoryHit] = []
    @State private var liveCount = 0
    @State private var searching = false

    var body: some View {
        Group {
            if core.memoryStore == nil {
                ContentUnavailableView(
                    "Memory unavailable",
                    systemImage: "brain",
                    description: Text("M1K3's memory store couldn't open on this device.")
                )
            } else if query.isEmpty {
                ContentUnavailableView {
                    Label("\(liveCount) memories", systemImage: "brain")
                } description: {
                    // Distillation is live on mobile (AppCore wires the shared
                    // MemoryDistillationCoordinator). One line, only while empty —
                    // once there are memories the search bar is the instruction.
                    if liveCount == 0 {
                        Text("Memories build up as you chat.")
                    }
                }
            } else if hits.isEmpty, !searching {
                ContentUnavailableView.search(text: query)
            } else {
                List(hits) { hit in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(hit.memory.text).font(.body)
                        Text(hit.memory.source)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Memories")
        .searchable(text: $query, prompt: "Recall a memory")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: query) { _, new in if new.isEmpty { hits = [] } }
        .onAppear { liveCount = (try? core.memoryStore?.liveCount()) ?? 0 }
    }

    private func search() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let memoryStore = core.memoryStore else { return }
        searching = true
        defer { searching = false }
        do {
            let vector = try await core.embedder.embedQuery(text)
            // Recall bar follows the embedder's cone — mobile ships hashing,
            // whose measured floor is far below the qwen default this call
            // would otherwise inherit (EmbedderFloors, 2026-07-31).
            hits = try memoryStore.recall(
                query: text, queryVector: vector, limit: 20,
                threshold: EmbedderFloors.forFingerprint(core.embedder.fingerprint).memory
            )
        } catch {
            hits = []
        }
    }
}
