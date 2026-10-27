//
//  ImportForgetTests.swift
//  M1K3ImportTests
//
//  #711's undo: "forget everything from this import" is one call. Every graph row and corpus item
//  carrying the import's tag goes (memories and filed conversations alike), and whatever the import
//  superseded is live again in BOTH stores — the graph by MemoryStore.forget(id:)'s un-supersede,
//  the corpus by the supersede ledger. Nothing another writer or another import wrote is touched.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85.
//  Prior: none (new file).

import Foundation
@testable import M1K3Chat
@testable import M1K3Import
import M1K3Knowledge
import M1K3Memory
import Testing

struct ImportForgetTests {
    @Test("forgetting an import removes its rows everywhere and revives what it superseded")
    func forgetByTagRevivesWhatItSuperseded() async throws {
        let harness = try ImportHarness()
        try await harness.seedLive("\(filler) dublin", said: "\(filler) dublin")
        try await harness.seedLive("Kev drinks his tea black", said: "I drink my tea black")
        let unrelated = Memory(kind: .note, text: "Kev's van is blue", source: "mcp:remember")
        try await harness.memory.remember(unrelated, embedding: harness.embedder.embed(unrelated.text))
        let bundle = ImportBundle(provider: .chatgpt, conversations: [
            conversation("c1", [(.user, "\(filler) ardmore"), (.assistant, "Noted.")]),
            conversation("c2", [(.user, "I keep bees in Kinsale"), (.assistant, "Lovely.")]),
        ])
        let pipeline = harness.pipeline(ScriptedDistiller(["\(filler) ardmore", "Kev keeps bees in Kinsale"]))
        _ = try await pipeline.commit(pipeline.propose(bundle), from: bundle)
        let dublinItem = try #require(try harness.corpusItem(forFact: "\(filler) dublin"))
        #expect(try harness.knowledge.item(id: dublinItem.id)?.kind == .memorySuperseded)

        let receipt = try ImportForget.forget(
            tag: harness.tag, knowledgeStore: harness.knowledge, memoryStore: harness.memory
        )

        #expect(receipt == ImportForgetReceipt(graphMemoriesForgotten: 2, corpusMemoriesForgotten: 2, conversationsForgotten: 2))
        #expect(try harness.memory.memories(source: harness.tag.graphSource).isEmpty)
        #expect(try harness.knowledge.itemIDs(source: harness.tag.knowledgeSource).isEmpty)
        #expect(try harness.knowledge.allItems(kind: .conversation).isEmpty)
        #expect(try harness.graphRow("\(filler) dublin")?.supersededBy == nil)
        #expect(try harness.knowledge.item(id: dublinItem.id)?.kind == .memory)
        #expect(try harness.knowledge.meta(key: MemoryDistillationCoordinator.supersededLinkKey(dublinItem.id)) == nil)
        #expect(try harness.graphRow("Kev drinks his tea black")?.source == "distilled")
        #expect(try harness.graphRow("Kev's van is blue")?.source == "mcp:remember")
        #expect(try harness.memory.liveCount() == 3)
        #expect(try harness.knowledge.allItems(kind: .memory).count == 2)
    }

    @Test("forgetting one import leaves another import's rows alone")
    func importsAreForgottenOneAtATime() async throws {
        let harness = try ImportHarness()
        let claudeTag = ImportSourceTag(provider: .claude, date: utcDate(2026, 10, 26))
        let chatgpt = ImportBundle(provider: .chatgpt, conversations: [conversation("g1", [(.user, "I keep bees in Kinsale")])])
        let claude = ImportBundle(provider: .claude, conversations: [conversation("k1", [(.user, "I play the fiddle in Cobh")])])
        let first = harness.pipeline(FlakyDistiller())
        _ = try await first.commit(first.propose(chatgpt), from: chatgpt)
        let second = harness.pipeline(FlakyDistiller(), tag: claudeTag)
        _ = try await second.commit(second.propose(claude), from: claude)

        _ = try ImportForget.forget(tag: harness.tag, knowledgeStore: harness.knowledge, memoryStore: harness.memory)

        #expect(try harness.memory.memories(source: claudeTag.graphSource).count == 1)
        #expect(try harness.knowledge.itemIDs(source: claudeTag.knowledgeSource).count == 2)
        #expect(try harness.knowledge.allItems(kind: .conversation).compactMap(\.sourceRef)
            == [claudeTag.conversationSourceRef(id: "k1")])
    }
}
