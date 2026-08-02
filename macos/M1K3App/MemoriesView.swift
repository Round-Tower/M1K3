//
//  MemoriesView.swift
//  M1K3App
//
//  The memory surface, now explorable: every fact M1K3 holds about you, who
//  wrote it ("you told me" vs "I noticed"), a free-text interrogation box
//  ("what do you know about X?"), one-tap forget, and a tap-through into each
//  fact's detail — its correction history and its connections in the graph.
//
//  Reads the memory GRAPH (AppEnvironment+Memory) rather than the corpus twin
//  the old flat list used, so rows carry the ids + edges + provenance that make
//  traversal possible. Delete is still the real cascade (graph + corpus twin).
//
//  Corrected facts (dream-cycle Tier 2 supersedes instead of eating) are
//  hidden by default and revealed by the header toggle as their own dimmed
//  section — the same reveal idiom as DocumentsView's quarantine lock. They
//  navigate to detail (the correction chain lives there) but carry no forget
//  swipe: forgetting a history row would sever the chain the live fact's
//  "how did you learn this?" story depends on.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-20, Confidence 0.82 (verify-owed =
//  on-device click-through). Prior: flat list over documents(kind: .memory)
//  (Kev + claude-fable-5, 2026-06-12).
//  Review: Kev + claude-fable-5, 2026-08-01 — the corrected-facts section.
//  TWO independent queries, not fetch-then-partition: the review caught that
//  a shared LIMIT lets recent corrected rows displace live rows out of the
//  fetched window, silently shrinking the live list/count. Live rows load
//  exactly as before the lens existed; corrected rows come from the store's
//  own supersededMemories query (TDD'd in M1K3Memory). The count chip reads
//  the live fetch only, so toggling the lens structurally cannot change how
//  many facts M1K3 claims to hold.

import M1K3Memory
import SwiftUI

/// The consent-facing label for a fact's provenance. UI copy lives here
/// (localized), while the pure `MemoryProvenance` classifier lives in the core.
extension MemoryProvenance {
    var label: String {
        switch self {
        case .youToldMe: String(localized: "you told me")
        case .iNoticed: String(localized: "I noticed")
        case .remembered: String(localized: "remembered")
        }
    }
}

struct MemoriesView: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    /// Live facts only — never includes superseded rows, whatever the lens.
    @State private var memories: [Memory] = []
    /// Corrected (superseded) facts, loaded only while the lens is on. Its own
    /// fetch with its own row budget — see the header Review note.
    @State private var corrected: [Memory] = []
    @State private var query: String = ""
    /// nil = not interrogating (show the full list); non-nil = search results.
    @State private var results: [Memory]?
    @State private var searching = false
    /// Reveal the corrected-facts section (superseded rows kept as history).
    @State private var showCorrected = false

    /// What the list renders: interrogation results when searching, else all.
    /// Interrogation only ever recalls live facts, so the corrected section
    /// stays out of search results by construction.
    private var shown: [Memory] {
        results ?? memories
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                interrogateField
                content
            }
            .navigationDestination(for: Memory.self) { memory in
                MemoryDetailView(memory: memory)
            }
        }
        .onAppear { reload() }
    }

    private var header: some View {
        HStack {
            Label("Memories", systemImage: "brain")
                .font(.pixelTitle)
            Spacer()
            Button {
                openWindow(id: M1K3App.constellationWindowID)
            } label: {
                Label("Constellation", systemImage: "sparkles")
            }
            .buttonStyle(.borderless)
            .help("See your memories as a 3D constellation")
            // The DocumentsView lock idiom: a quiet reveal for kept history.
            Button {
                showCorrected.toggle()
                reload()
            } label: {
                Image(systemName: "clock.arrow.circlepath")
            }
            .buttonStyle(.borderless)
            .help(showCorrected ? "Hide corrected facts" : "Show corrected facts (kept as history)")
            .foregroundStyle(showCorrected ? Color.primary : Color.secondary)
            .accessibilityLabel(showCorrected ? "Hide corrected facts" : "Show corrected facts")
            Text("\(liveCount) memor\(liveCount == 1 ? "y" : "ies")")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    /// The count chip stays a LIVE count no matter the lens — `memories` never
    /// contains superseded rows, so toggling the reveal structurally cannot
    /// change how many facts M1K3 claims to hold.
    private var liveCount: Int {
        memories.count
    }

    private var interrogateField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Ask what I know…", text: $query)
                .textFieldStyle(.plain)
                .onSubmit(runInterrogation)
            if searching {
                ProgressView().controlSize(.small)
            } else if results != nil {
                Button {
                    query = ""
                    results = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    /// The corrected section renders only under the reveal, and only while the
    /// list is not showing interrogation results (search recalls live facts).
    private var shownCorrected: [Memory] {
        (showCorrected && results == nil) ? corrected : []
    }

    @ViewBuilder
    private var content: some View {
        if shown.isEmpty, shownCorrected.isEmpty {
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "brain")
            } description: {
                Text(emptyMessage)
            }
        } else {
            List {
                ForEach(shown) { memory in
                    NavigationLink(value: memory) {
                        MemoryRow(memory: memory)
                    }
                    .swipeActions {
                        Button(role: .destructive) { forget(memory) } label: {
                            Label("Forget", systemImage: "trash")
                        }
                    }
                }
                if !shownCorrected.isEmpty {
                    // Corrected rows navigate (the chain story lives in detail)
                    // but carry NO forget swipe — forgetting a history row would
                    // sever the lineage behind the live fact that replaced it.
                    Section {
                        ForEach(shownCorrected) { memory in
                            NavigationLink(value: memory) {
                                MemoryRow(memory: memory, corrected: true)
                            }
                        }
                    } header: {
                        Label("Corrected — kept as history", systemImage: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .listStyle(.inset)
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyTitle: String {
        results == nil
            ? String(localized: "Nothing remembered about you yet")
            : String(localized: "No memories match that")
    }

    private var emptyMessage: String {
        results == nil
            ? String(localized: "Tell M1K3 to remember something, or let it learn as you chat.")
            : String(localized: "Try different words, or clear the search to see everything.")
    }

    private func reload() {
        memories = env.memories()
        corrected = showCorrected ? env.correctedMemories() : []
    }

    private func runInterrogation() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            results = nil
            return
        }
        searching = true
        Task {
            let hits = await env.interrogateMemories(q)
            await MainActor.run {
                results = hits
                searching = false
            }
        }
    }

    private func forget(_ memory: Memory) {
        env.forgetMemory(memory)
        reload()
        // Keep an active search consistent without a round-trip re-query.
        results?.removeAll { $0.id == memory.id }
    }
}

/// One row in the memory list: the fact, its provenance, and when it landed.
/// Navigation + forget are owned by the parent so the row stays a pure label.
/// `corrected` rows dim (the DocumentsView quarantine idiom) and say so in
/// the caption — the full replacement story is one tap away in detail.
private struct MemoryRow: View {
    let memory: Memory
    var corrected = false

    private var displayText: String {
        // Titled MCP facts carry discriminating context the bare text may lack.
        if let title = memory.title, !title.isEmpty, title != memory.text {
            return title
        }
        return memory.text
    }

    private var caption: String {
        let base = "\(MemoryProvenance(source: memory.source).label) · \(memory.createdAt.formatted(date: .abbreviated, time: .omitted))"
        return corrected ? String(localized: "corrected · \(base)") : base
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: corrected ? "clock.arrow.circlepath" : "brain")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayText)
                    .lineLimit(2)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .opacity(corrected ? 0.55 : 1.0)
        .accessibilityElement(children: .combine)
        .accessibilityHint(corrected ? Text("Corrected fact, kept as history") : Text(""))
    }
}
