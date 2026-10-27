//
//  OKFImportParserTests.swift
//  M1K3ImportTests
//
//  #711: an OKF folder written by another M1K3 (`OKFExport.files`) reads back as facts, one per
//  file: frontmatter `type` / `title` / `timestamp` / `source`, the body up to the Relations
//  section. The round trip is pinned against the REAL serializer, so a change to the export's
//  shape fails here. The parser takes files, never a path (ADR 0003 containment).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85.
//  Prior: none (new file).

import Foundation
import M1K3Chat
@testable import M1K3Import
import M1K3Memory
import Testing

struct OKFImportParserTests {
    @Test("OKFExport.files → parse gives back each live memory's text, kind, title, source and second")
    func roundTripsOKFExport() throws {
        let stamp = Date(timeIntervalSince1970: 1_761_480_000.75)
        let bees = Memory(kind: .profile, text: "Kev keeps bees in Kinsale", source: "distilled", createdAt: stamp)
        let quoted = Memory(
            kind: .preference, text: "Kev prefers metric units\nand en-GB spelling",
            title: #"The "metric" rule \ always"#, source: "mcp:remember", createdAt: stamp
        )
        let corrected = Memory(kind: .note, text: "Kev lives in Dublin", source: "distilled", createdAt: stamp)
        let live = Memory(kind: .profile, text: "Kev lives in Ardmore", source: "distilled", createdAt: stamp)
        var superseded = corrected
        superseded.supersededBy = live.id
        let files = OKFExport.files(
            memories: [bees, quoted, superseded, live],
            edges: [MemoryEdge(fromID: bees.id, toID: live.id, relation: "related")],
            exportedAt: stamp
        )

        let bundle = OKFImportParser.parse(files: files)

        #expect(bundle.provider == .m1k3)
        #expect(bundle.conversations.isEmpty)
        #expect(bundle.facts.count == 3)
        for memory in [bees, quoted, live] {
            let fact = try #require(bundle.facts.first { $0.text == memory.text })
            #expect(fact.kind.rawValue == memory.kind.rawValue)
            #expect(fact.title == memory.title)
            #expect(fact.originalSource == memory.source)
            #expect(fact.createdAt.map { $0.timeIntervalSince1970.rounded(.down) } == 1_761_480_000)
        }
        #expect(!bundle.facts.contains { $0.text.contains("Relations") || $0.text.contains("](./") })
        #expect(!bundle.facts.contains { $0.text.contains("Dublin") })
    }

    @Test("README, non-markdown files and files without frontmatter or type are skipped")
    func skipsWhatIsNotAFact() {
        let files = [
            OKFExport.File(name: "README.md", content: "# M1K3 memory export\n"),
            OKFExport.File(name: "notes.txt", content: "---\ntype: note\n---\n\nnot markdown\n"),
            OKFExport.File(name: "plain.md", content: "Just a markdown file.\n"),
            OKFExport.File(name: "untyped.md", content: "---\ntitle: \"x\"\n---\n\nno type\n"),
            OKFExport.File(name: "empty.md", content: "---\ntype: note\n---\n\n\n"),
            OKFExport.File(name: "odd-kind.md", content: "---\ntype: Recipe\r\nsource: \"other-tool\"\r\n---\r\n\r\nSoda bread\r\n"),
        ]

        let facts = OKFImportParser.parse(files: files).facts

        #expect(facts.map(\.text) == ["Soda bread"])
        #expect(facts.first?.kind == .note)
        #expect(facts.first?.originalSource == "other-tool")
        #expect(facts.first?.createdAt == nil)
    }

    @Test("a body whose own text has a Relations heading keeps it unless only links follow")
    func relationsCutOnlyWhenItIsTheLinkList() {
        let content = "---\ntype: note\n---\n\nAgenda\n\n## Relations\nwith the neighbours is good\n"
        let facts = OKFImportParser.parse(files: [OKFExport.File(name: "a.md", content: content)]).facts
        #expect(facts.first?.text == "Agenda\n\n## Relations\nwith the neighbours is good")
    }
}
