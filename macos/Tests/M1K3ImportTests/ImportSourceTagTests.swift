//
//  ImportSourceTagTests.swift
//  M1K3ImportTests
//
//  #711: every row an import writes carries `import/<provider>/<yyyy-MM-dd>` (UTC day) in BOTH
//  stores, which is what makes "forget everything from this import" one action. The provider
//  slugs persist in those rows, so they are pinned literals.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.9.
//  Prior: none (new file).

import Foundation
@testable import M1K3Import
import M1K3Knowledge
import Testing

struct ImportSourceTagTests {
    @Test("the provider slugs are pinned: they persist in memory and knowledge rows")
    func providerSlugsArePinned() {
        #expect(ImportProvider.allCases.map(\.rawValue) == ["chatgpt", "claude", "m1k3"])
    }

    @Test("the tag is import/<provider>/<UTC day> and parses back")
    func formatAndParse() {
        let tag = ImportSourceTag(provider: .chatgpt, date: utcDate(2026, 10, 26, 23, 30))
        #expect(tag.rawValue == "import/chatgpt/2026-10-26")
        #expect(ImportSourceTag(provider: .claude, date: utcDate(2026, 10, 27, 0, 15)).rawValue == "import/claude/2026-10-27")
        #expect(ImportSourceTag(rawValue: "import/claude/2026-10-26")?.provider == .claude)
        #expect(ImportSourceTag(rawValue: tag.rawValue) == tag)
        #expect(tag.knowledgeSource == KnowledgeSource(rawValue: "import/chatgpt/2026-10-26"))
        #expect(tag.graphSource == "import/chatgpt/2026-10-26")
    }

    @Test("anything that is not exactly an import tag does not parse")
    func rejectsOtherSources() {
        for raw in [
            "distilled", "mcp:remember", "import/bard/2026-10-26", "import/chatgpt/26-10-2026",
            "import/chatgpt/2026-10-26/extra", "import/chatgpt/2026-13-40", "import/chatgpt/2026-02-31",
            "import/chatgpt",
        ] {
            #expect(ImportSourceTag(rawValue: raw) == nil, "\(raw)")
        }
    }

    @Test("a conversation's sourceRef names the provider and its id, not the day")
    func conversationSourceRefIsDayFree() {
        let monday = ImportSourceTag(provider: .chatgpt, date: utcDate(2026, 10, 26))
        let friday = ImportSourceTag(provider: .chatgpt, date: utcDate(2026, 10, 30))
        #expect(monday.conversationSourceRef(id: "abc-123") == "import/chatgpt/conversation/abc-123")
        // A later export of the same account re-files nothing an earlier import filed.
        #expect(friday.conversationSourceRef(id: "abc-123") == monday.conversationSourceRef(id: "abc-123"))
        #expect(
            ImportSourceTag(provider: .claude, date: utcDate(2026, 10, 26)).conversationSourceRef(id: "abc-123")
                != monday.conversationSourceRef(id: "abc-123")
        )
    }
}
