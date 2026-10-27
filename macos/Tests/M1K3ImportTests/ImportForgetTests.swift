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
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — the precondition is checked before the forget
//  (no vacuous optional), and new pins: an import that exactly restates a corrected fact changes nothing and forgets
//  to nothing, forget is idempotent, two imports of one provider on different days are forgotten apart, and a
//  forgotten import can be imported again. Confidence 0.85.

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
        _ = try await pipeline.commit(pipeline.propose(bundle), from: bundle, filing: .all)
        let dublinItem = try #require(try harness.corpusItem(forFact: "\(filler) dublin"))
        #expect(try harness.knowledge.item(id: dublinItem.id)?.kind == .memorySuperseded)
        #expect(try #require(try harness.graphRow("\(filler) dublin")).supersededBy != nil)

        let receipt = try ImportForget.forget(
            tag: harness.tag, knowledgeStore: harness.knowledge, memoryStore: harness.memory
        )

        #expect(receipt == ImportForgetReceipt(graphMemoriesForgotten: 2, corpusMemoriesForgotten: 2, conversationsForgotten: 2))
        #expect(try harness.memory.memories(source: harness.tag.graphSource).isEmpty)
        #expect(try harness.knowledge.itemIDs(source: harness.tag.knowledgeSource).isEmpty)
        #expect(try harness.knowledge.allItems(kind: .conversation).isEmpty)
        #expect(try #require(try harness.graphRow("\(filler) dublin")).supersededBy == nil)
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
        _ = try await first.commit(first.propose(chatgpt), from: chatgpt, filing: .all)
        let second = harness.pipeline(FlakyDistiller(), tag: claudeTag)
        _ = try await second.commit(second.propose(claude), from: claude, filing: .all)

        _ = try ImportForget.forget(tag: harness.tag, knowledgeStore: harness.knowledge, memoryStore: harness.memory)

        #expect(try harness.memory.memories(source: harness.tag.graphSource).isEmpty)
        #expect(try harness.memory.memories(source: claudeTag.graphSource).count == 1)
        #expect(try harness.knowledge.itemIDs(source: claudeTag.knowledgeSource).count == 2)
        #expect(try harness.knowledge.allItems(kind: .conversation).compactMap(\.sourceRef)
            == [claudeTag.conversationSourceRef(id: "k1")])
    }

    @Test("an old chat exactly restating a corrected fact changes nothing, and forgetting it changes nothing")
    func anImportNeverRevivesACorrectedFact() async throws {
        let harness = try ImportHarness()
        try await harness.seedLive("\(filler) dublin", said: "\(filler) dublin")
        try await harness.seedLive("\(filler) ardmore", said: "\(filler) ardmore")
        let dublin = try #require(try harness.corpusItem(forFact: "\(filler) dublin"))
        let ardmore = try #require(try harness.corpusItem(forFact: "\(filler) ardmore"))
        func expectArdmoreLive() throws {
            #expect(try harness.knowledge.item(id: dublin.id)?.kind == .memorySuperseded)
            #expect(try harness.knowledge.item(id: ardmore.id)?.kind == .memory)
            let oldRow = try #require(try harness.graphRow("\(filler) dublin"))
            let newRow = try #require(try harness.graphRow("\(filler) ardmore"))
            #expect(oldRow.supersededBy == newRow.id)
            #expect(newRow.supersededBy == nil)
            #expect(try harness.memory.liveCount() == 1)
            #expect(try harness.memory.totalCount() == 2)
        }
        try expectArdmoreLive()
        let bundle = ImportBundle(
            provider: .chatgpt, conversations: [conversation("old", [(.user, "\(filler) dublin")])]
        )
        let pipeline = harness.pipeline(FlakyDistiller())

        let receipt = try await pipeline.commit(pipeline.propose(bundle), from: bundle, filing: .none)

        #expect(receipt == ImportReceipt(factsWritten: 0))
        try expectArdmoreLive()
        let forgotten = try ImportForget.forget(
            tag: harness.tag, knowledgeStore: harness.knowledge, memoryStore: harness.memory
        )
        #expect(forgotten == ImportForgetReceipt(
            graphMemoriesForgotten: 0, corpusMemoriesForgotten: 0, conversationsForgotten: 0
        ))
        try expectArdmoreLive()
    }

    @Test("forget is idempotent, and a tag that wrote nothing forgets nothing")
    func forgetIsIdempotent() async throws {
        let harness = try ImportHarness()
        let bundle = ImportBundle(
            provider: .chatgpt, conversations: [conversation("c1", [(.user, "Kev keeps bees in Kinsale")])]
        )
        let pipeline = harness.pipeline(FlakyDistiller())
        _ = try await pipeline.commit(pipeline.propose(bundle), from: bundle, filing: .all)
        let none = ImportForgetReceipt(graphMemoriesForgotten: 0, corpusMemoriesForgotten: 0, conversationsForgotten: 0)

        func forget() throws -> ImportForgetReceipt {
            try ImportForget.forget(tag: harness.tag, knowledgeStore: harness.knowledge, memoryStore: harness.memory)
        }
        let first = try forget()
        let second = try forget()
        let stranger = try ImportForget.forget(
            tag: ImportSourceTag(provider: .claude, date: utcDate(2026, 1, 5)),
            knowledgeStore: harness.knowledge, memoryStore: harness.memory
        )

        #expect(first == ImportForgetReceipt(
            graphMemoriesForgotten: 1, corpusMemoriesForgotten: 1, conversationsForgotten: 1
        ))
        #expect(second == none)
        #expect(stranger == none)
    }

    @Test("two imports of one provider on different days are forgotten apart; transcripts belong to the first")
    func sameProviderDaysAreForgottenApart() async throws {
        let monday = ImportSourceTag(provider: .chatgpt, date: utcDate(2026, 10, 26))
        let friday = ImportSourceTag(provider: .chatgpt, date: utcDate(2026, 10, 30))
        let harness = try ImportHarness(tag: monday)
        let early = [
            conversation("c1", at: 1, [(.user, "Kev keeps bees in Kinsale")]),
            conversation("c2", at: 2, [(.user, "Kev plays the fiddle in Cobh")]),
        ]
        let mondayBundle = ImportBundle(provider: .chatgpt, conversations: early)
        let fridayBundle = ImportBundle(
            provider: .chatgpt, conversations: early + [conversation("c3", at: 3, [(.user, "Kev rows on the Lee")])]
        )
        let first = harness.pipeline(FlakyDistiller(), tag: monday)
        _ = try await first.commit(first.propose(mondayBundle), from: mondayBundle, filing: .all)
        let second = harness.pipeline(FlakyDistiller(), tag: friday)

        let later = try await second.commit(second.propose(fridayBundle), from: fridayBundle, filing: .all)

        #expect(later == ImportReceipt(factsWritten: 1, conversationsFiled: 1, conversationsAlreadyFiled: 2))
        #expect(try harness.knowledge.itemIDs(source: friday.knowledgeSource).count == 2)

        _ = try ImportForget.forget(tag: friday, knowledgeStore: harness.knowledge, memoryStore: harness.memory)

        #expect(try harness.graphRow("Kev rows on the Lee") == nil)
        #expect(try harness.memory.memories(source: monday.graphSource).count == 2)
        #expect(try harness.knowledge.allItems(kind: .conversation).count == 2)
        #expect(try harness.knowledge.itemIDs(source: monday.knowledgeSource).count == 4)

        _ = try ImportForget.forget(tag: monday, knowledgeStore: harness.knowledge, memoryStore: harness.memory)

        #expect(try harness.memory.totalCount() == 0)
        #expect(try harness.knowledge.itemCount() == 0)
    }

    @Test("a forgotten import can be imported again: its transcripts and facts are filed afresh")
    func reimportAfterForget() async throws {
        let harness = try ImportHarness()
        let bundle = ImportBundle(
            provider: .chatgpt, conversations: [conversation("c1", [(.user, "Kev keeps bees in Kinsale")])]
        )
        let pipeline = harness.pipeline(FlakyDistiller())
        _ = try await pipeline.commit(pipeline.propose(bundle), from: bundle, filing: .all)
        _ = try ImportForget.forget(tag: harness.tag, knowledgeStore: harness.knowledge, memoryStore: harness.memory)

        let again = try await pipeline.commit(pipeline.propose(bundle), from: bundle, filing: .all)

        #expect(again == ImportReceipt(factsWritten: 1, conversationsFiled: 1))
        #expect(try harness.knowledge.itemIDs(source: harness.tag.knowledgeSource).count == 2)
    }
}
