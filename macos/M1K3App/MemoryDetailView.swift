//
//  MemoryDetailView.swift
//  M1K3App
//
//  The explorable face of one memory — the payoff for the graph M1K3 already
//  builds but never let you see. Three sections, each over a tested MemoryStore
//  API:
//    · The fact — text, kind, provenance, when.
//    · How I learned this — the supersession lineage (SupersessionChain), so a
//      corrected fact shows its history instead of pretending it was always so.
//    · Connections — one-hop neighbours (MemoryStore.related), each a link that
//      pushes ITS detail, so exploration is recursion, not a dead end.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-20, Confidence 0.8 (verify-owed =
//  on-device click-through with real seeded memories).

import M1K3Memory
import SwiftUI

struct MemoryDetailView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let memory: Memory

    @State private var related: [Memory] = []
    @State private var history: [Memory] = []

    private var provenance: MemoryProvenance {
        MemoryProvenance(source: memory.source)
    }

    var body: some View {
        List {
            factSection
            historySection
            connectionsSection
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .navigationTitle("Memory")
        .toolbar {
            // HIDDEN (dead-control rule), not disabled, for a corrected row:
            // this screen is now reachable from the corrected-history section,
            // and forgetting a history row would sever the lineage behind the
            // live fact that replaced it — the same rule that keeps the forget
            // swipe off corrected rows in the list. (The store's forget also
            // revives whatever the row superseded — deleting mid-chain would
            // resurrect a STALE fact as live beside the true head.)
            if memory.supersededBy == nil {
                ToolbarItem(placement: .destructiveAction) {
                    Button(role: .destructive) {
                        if env.forgetMemory(memory) { dismiss() }
                    } label: {
                        Label("Forget", systemImage: "trash")
                    }
                    .help("Forget this — removes it everywhere, no residue")
                }
            }
        }
        .onAppear(perform: load)
    }

    private var factSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                if let title = memory.title, !title.isEmpty, title != memory.text {
                    Text(title).font(.headline)
                }
                Text(memory.text)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(memory.kind.rawValue.capitalized)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .background(.tint.opacity(0.15), in: Capsule())
                    Text("\(provenance.label) · \(memory.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private var historySection: some View {
        // A lone fact is its own single-item history — only worth a section
        // once there's an actual correction chain to show.
        if history.count > 1 {
            Section("How I learned this") {
                ForEach(history) { step in
                    historyRow(step)
                }
            }
        }
    }

    @ViewBuilder
    private func historyRow(_ step: Memory) -> some View {
        let isCurrent = step.id == memory.id
        let icon = isCurrent ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath"
        let when = historyWhen(for: step, isCurrent: isCurrent)
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.text).lineLimit(3)
                Text(when).font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func historyWhen(for step: Memory, isCurrent: Bool) -> String {
        if isCurrent { return String(localized: "now") }
        let date = step.createdAt.formatted(date: .abbreviated, time: .omitted)
        return String(localized: "corrected \(date)")
    }

    private var connectionsSection: some View {
        Section("Connections") {
            if related.isEmpty {
                Text("No connections yet — related facts will appear here as M1K3 links them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(related) { neighbour in
                    NavigationLink(value: neighbour) {
                        HStack(spacing: 10) {
                            Image(systemName: "point.3.connected.trianglepath.dotted")
                                .foregroundStyle(.secondary)
                                .accessibilityHidden(true)
                            Text(neighbour.title?.isEmpty == false ? neighbour.title! : neighbour.text)
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private func load() {
        related = env.relatedMemories(to: memory.id)
        history = env.supersessionHistory(for: memory)
    }
}
