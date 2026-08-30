//
//  OKFExportTests.swift
//  M1K3MemoryTests
//
//  Pins the OKF export serializer (ADR 0003: OKF is an export format, not
//  the memory model). One .md per LIVE memory, frontmatter from the typed
//  row, edges as markdown links with the relation riding in the link text.
//  Deterministic — same graph, same bytes — and contained: nothing here
//  reads a store or touches the filesystem; the app glue does the writing.
//
//  Signed: Kev + claude-fable-5, 2026-08-30, Confidence 0.9 (pure function,
//  pinned red-first). Prior: none (new file).
//

import Foundation
@testable import M1K3Memory
import Testing

struct OKFExportTests {
    private let idA = UUID(uuidString: "AAAAAAAA-1111-2222-3333-444444444444")!
    private let idB = UUID(uuidString: "BBBBBBBB-1111-2222-3333-444444444444")!
    private let idC = UUID(uuidString: "CCCCCCCC-1111-2222-3333-444444444444")!
    private let when = Date(timeIntervalSince1970: 1_788_036_000) // 2026-08-29T20:40:00Z

    private func memory(
        _ id: UUID, kind: MemoryKind = .note, text: String, title: String? = nil,
        supersededBy: UUID? = nil
    ) -> Memory {
        Memory(
            id: id, kind: kind, text: text, title: title,
            source: "mcp:remember", createdAt: when, supersededBy: supersededBy
        )
    }

    @Test("one markdown file per live memory, plus a README")
    func onefilePerLiveMemory() {
        let files = OKFExport.files(
            memories: [
                memory(idA, text: "Kev's sister is Aoife."),
                memory(idB, text: "Old fact.", supersededBy: idA),
            ],
            edges: [], exportedAt: when
        )
        #expect(files.count == 2)
        #expect(files.contains { $0.name == "README.md" })
        #expect(!files.contains { $0.content.contains("Old fact.") })
    }

    @Test("frontmatter carries type, title, timestamp, and source from the typed row")
    func frontmatter() throws {
        let files = OKFExport.files(
            memories: [memory(idA, kind: .preference, text: "Prefers en-GB spellings.", title: "Spelling")],
            edges: [], exportedAt: when
        )
        let file = try #require(files.first { $0.name != "README.md" })
        #expect(file.content.hasPrefix("---\n"))
        #expect(file.content.contains("type: preference"))
        #expect(file.content.contains("title: \"Spelling\""))
        #expect(file.content.contains("source: \"mcp:remember\""))
        #expect(file.content.contains("timestamp: 2026-08-29T"))
        #expect(file.content.contains("Prefers en-GB spellings."))
    }

    @Test("a title with quotes stays valid YAML")
    func yamlEscaping() throws {
        let files = OKFExport.files(
            memories: [memory(idA, text: "x", title: #"The "big" idea: notes"#)],
            edges: [], exportedAt: when
        )
        let file = try #require(files.first { $0.name != "README.md" })
        #expect(file.content.contains(#"title: "The \"big\" idea: notes""#))
    }

    @Test("edges become markdown links — the relation rides in the link text")
    func edgesAsLinks() throws {
        let files = OKFExport.files(
            memories: [
                memory(idA, text: "Shipped the exporter.", title: "Export day"),
                memory(idB, text: "ADR 0003 accepted.", title: "The ruling"),
            ],
            edges: [MemoryEdge(fromID: idA, toID: idB, relation: "caused-by", createdAt: when)],
            exportedAt: when
        )
        let from = try #require(files.first { $0.content.contains("Shipped the exporter.") })
        let toName = try #require(files.first { $0.content.contains("ADR 0003") }?.name)
        #expect(from.content.contains("## Relations"))
        #expect(from.content.contains("[caused-by](./\(toName))"))
    }

    @Test("an edge to a superseded or missing memory is dropped, not a broken link")
    func danglingEdgesDropped() throws {
        let files = OKFExport.files(
            memories: [
                memory(idA, text: "Live fact."),
                memory(idB, text: "Corrected fact.", supersededBy: idA),
            ],
            edges: [
                MemoryEdge(fromID: idA, toID: idB, relation: "supersedes", createdAt: when),
                MemoryEdge(fromID: idA, toID: idC, relation: "about-person", createdAt: when),
            ],
            exportedAt: when
        )
        let live = try #require(files.first { $0.content.contains("Live fact.") })
        #expect(!live.content.contains("## Relations"))
    }

    @Test("filenames are slugged from the title with a stable id suffix")
    func filenames() throws {
        let files = OKFExport.files(
            memories: [memory(idA, text: "body", title: "Kev's Sister — Aoife!")],
            edges: [], exportedAt: when
        )
        let file = try #require(files.first { $0.name != "README.md" })
        #expect(file.name == "kev-s-sister-aoife-aaaaaaaa.md")
    }

    @Test("an untitled memory slugs from its text")
    func untitledFilename() throws {
        let files = OKFExport.files(
            memories: [memory(idB, text: "Prefers pnpm over npm for Node work.")],
            edges: [], exportedAt: when
        )
        let file = try #require(files.first { $0.name != "README.md" })
        #expect(file.name.hasPrefix("prefers-pnpm-over-npm"))
        #expect(file.name.hasSuffix("-bbbbbbbb.md"))
    }

    @Test("the README names the export and its exposure in plain words")
    func readme() throws {
        let files = OKFExport.files(
            memories: [memory(idA, text: "x")], edges: [], exportedAt: when
        )
        let readme = try #require(files.first { $0.name == "README.md" })
        #expect(readme.content.contains("M1K3"))
        #expect(readme.content.lowercased().contains("plain text"))
        #expect(readme.content.contains("2026-08-29"))
    }

    @Test("deterministic — same graph, same bytes, stable order")
    func deterministic() {
        let memories = [
            memory(idA, text: "a", title: "Alpha"),
            memory(idB, text: "b", title: "Beta"),
        ]
        let edges = [MemoryEdge(fromID: idA, toID: idB, relation: "part-of", createdAt: when)]
        let one = OKFExport.files(memories: memories, edges: edges, exportedAt: when)
        let two = OKFExport.files(memories: memories.reversed(), edges: edges, exportedAt: when)
        #expect(one == two)
    }
}
