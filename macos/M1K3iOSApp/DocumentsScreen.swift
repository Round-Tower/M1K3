//
//  DocumentsScreen.swift
//  M1K3iOS / M1K3visionOS
//
//  The RAG corpus, on mobile: list indexed documents, import a PDF/text file, and
//  delete. Ingest runs the SAME DocumentIngester the Mac app uses (embed → chunk →
//  index), so anything added here becomes retrievable by the chat's grounding.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-06, Confidence 0.8. Prior: Unknown.
//

import M1K3Knowledge
import SwiftUI
import UniformTypeIdentifiers

struct DocumentsScreen: View {
    @Environment(AppCore.self) private var core
    @State private var items: [KnowledgeItem] = []
    @State private var importing = false

    var body: some View {
        Group {
            if items.isEmpty {
                ContentUnavailableView {
                    Label("No documents yet", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Import a PDF or text file and M1K3 can ground its answers in it.")
                } actions: {
                    Button("Import a file") { importing = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.title).font(.body)
                            Text(item.createdAt, format: .dateTime.day().month().year())
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .onDelete(perform: delete)
                }
            }
        }
        .navigationTitle("Documents")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { importing = true } label: { Image(systemName: "plus") }
            }
        }
        .fileImporter(
            isPresented: $importing,
            allowedContentTypes: [.pdf, .plainText, .text],
            allowsMultipleSelection: false
        ) { result in
            guard case let .success(urls) = result, let url = urls.first else { return }
            Task {
                await core.ingest(url: url)
                refresh()
            }
        }
        .overlay(alignment: .bottom) {
            if let status = core.lastIngestStatus {
                Text(status)
                    .font(.caption)
                    .padding(10)
                    .m1k3Glass(cornerRadius: 12)
                    .padding()
            }
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        items = core.documents()
    }

    private func delete(at offsets: IndexSet) {
        for index in offsets {
            core.deleteDocument(id: items[index].id)
        }
        refresh()
    }
}
