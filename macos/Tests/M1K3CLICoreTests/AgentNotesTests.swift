//
//  AgentNotesTests.swift
//  M1K3CLICoreTests
//
//  The block `m1k3 agent-notes` drops into a project's AGENTS.md / CLAUDE.md.
//  What matters is that a second run is a no-op — an agent that re-runs this
//  on every session must not stack five copies of the same paragraph — and
//  that the merge never eats the file it is merging into.
//
//  Signed: Kev + claude-opus-5, 2026-09-11, Confidence 0.9 (idempotence and
//  the marker arithmetic are pinned here; the block's WORDING is judgement and
//  will drift with the product). Prior: Unknown.
//

import Foundation
@testable import M1K3CLICore
import Testing

struct AgentNotesTests {
    @Test("the block is short, markdown, and fenced by its markers")
    func blockShape() {
        let lines = AgentNotes.block.components(separatedBy: "\n")
        #expect(lines.first == AgentNotes.beginMarker)
        #expect(lines.last == AgentNotes.endMarker)
        #expect(lines.count <= 12)
        #expect(!AgentNotes.block.hasSuffix("\n"))
    }

    @Test("the block says the four things a visiting agent needs")
    func blockContent() {
        let block = AgentNotes.block
        #expect(block.contains("ask_m1k3"))
        #expect(block.contains("search_knowledge"))
        #expect(block.contains("remember"))
        #expect(block.contains("speak"))
        // It can be down, and that is fine — never block on it.
        #expect(block.lowercased().contains("never block"))
    }

    @Test("no file yet: the block stands alone, one trailing newline")
    func mergeIntoNothing() {
        let merged = AgentNotes.merge(into: nil)
        #expect(merged == AgentNotes.block + "\n")
    }

    @Test("an existing file keeps its content; the block lands after one blank line")
    func mergeAppends() {
        let merged = AgentNotes.merge(into: "# Project\n\nBuild with make.\n")
        #expect(merged == "# Project\n\nBuild with make.\n\n" + AgentNotes.block + "\n")
    }

    @Test("a stale block is replaced in place, leaving the text around it alone")
    func mergeReplacesInPlace() {
        let stale = """
        # Project

        \(AgentNotes.beginMarker)
        ## M1K3 said something old
        \(AgentNotes.endMarker)

        Build with make.
        """
        let merged = AgentNotes.merge(into: stale)
        #expect(merged.contains("# Project"))
        #expect(merged.contains("Build with make."))
        #expect(!merged.contains("something old"))
        #expect(merged.contains(AgentNotes.block))
        #expect(merged.components(separatedBy: AgentNotes.beginMarker).count == 2)
    }

    @Test("merging twice changes nothing the second time")
    func idempotent() {
        for existing in [nil, "# Project\n", "# Project\n\nBuild with make.\n"] as [String?] {
            let once = AgentNotes.merge(into: existing)
            #expect(AgentNotes.merge(into: once) == once)
        }
    }

    @Test("a dangling begin marker is left alone and the block appended, never truncating the file")
    func danglingMarker() {
        let existing = "# Project\n\n\(AgentNotes.beginMarker)\nhalf a block\n"
        let merged = AgentNotes.merge(into: existing)
        #expect(merged.contains("half a block"))
        #expect(merged.hasSuffix(AgentNotes.block + "\n"))
        #expect(AgentNotes.merge(into: merged) == merged)
    }

    @Test("the default file is AGENTS.md")
    func defaultFile() {
        #expect(AgentNotes.defaultFileName == "AGENTS.md")
    }
}
