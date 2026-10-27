//
//  ConversationImportPipelineTests.swift
//  M1K3ImportTests
//
//  #711's pipeline. propose: every conversation, in slices the distiller's own prompt cap holds,
//  through MemoryDistillationCoordinator.propose — the #288 fence anchors facts in the IMPORTED
//  user turns — and nothing is written. commit: the accepted facts through coordinator.store, the
//  same exact + semantic dedupe/supersede path live distillation uses (the bar is
//  semanticDedupeThreshold(for:), never restated), tagged import/<provider>/<day> in both stores;
//  then every conversation filed once as a cited `.conversation` knowledge item, never a memory.
//
//  The real distiller's judgement (stated facts kept, the cloud assistant's guesses not promoted)
//  needs the app's models: owed as a SelfTest arm, not provable under swift test.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85.
//  Prior: none (new file).

import Foundation
import M1K3Chat
@testable import M1K3Import
@testable import M1K3Knowledge
import M1K3Memory
import Testing

struct ConversationImportPipelineTests {
    // MARK: - propose

    @Test("propose keeps the fact the user stated, drops the one the assistant offered, writes nothing")
    func proposalsAreUserAnchored() async throws {
        let harness = try ImportHarness()
        let bundle = ImportBundle(provider: .chatgpt, conversations: [conversation("c1", [
            (.user, "I keep three hives of bees in the back garden in Kinsale"),
            (.assistant, "Lovely! If you ever fancy it, beekeepers often enjoy mead."),
        ])])
        let pipeline = harness.pipeline(ScriptedDistiller(["Kev keeps bees in Kinsale", "Kev enjoys mead"]))

        let proposals = try await pipeline.propose(bundle)

        #expect(proposals.map(\.fact.text) == ["Kev keeps bees in Kinsale"])
        #expect(proposals.first?.conversationID == "c1")
        #expect(proposals.first?.sourceTitle == "Conversation c1")
        #expect(try harness.knowledge.itemCount() == 0)
        #expect(try harness.memory.totalCount() == 0)
    }

    @Test("a conversation whose user turns are single words never reaches the distiller")
    func trivialUserTurnsSkipTheDistiller() async throws {
        let harness = try ImportHarness()
        let spy = SpyDistiller(["Kev says thanks a lot"])
        let bundle = ImportBundle(provider: .claude, conversations: [conversation("c1", [
            (.user, "hi"), (.assistant, "Hello! How can I help with your garden today?"), (.user, "thanks"),
        ])])

        let proposals = try await harness.pipeline(spy).propose(bundle)

        #expect(proposals.isEmpty)
        #expect(await spy.calls.isEmpty)
    }

    @Test("a long conversation is sliced so every turn fits the distiller prompt's own cap")
    func longConversationsAreSlicedToTheDistillersCap() async throws {
        let harness = try ImportHarness()
        let spy = SpyDistiller()
        var messages: [(ImportedRole, String)] = [(.user, "My sister Aoife moved to Galway in March")]
        for index in 0 ..< 60 {
            messages.append((.assistant, "Answer \(index): " + String(repeating: "long reply ", count: 60)))
            messages.append((.user, "Follow-up question number \(index) about the garden"))
        }
        let bundle = ImportBundle(provider: .chatgpt, conversations: [conversation("long", messages)])

        _ = try await harness.pipeline(spy).propose(bundle)

        let calls = await spy.calls
        #expect(calls.count > 1)
        #expect(calls.flatMap(\.self).count == messages.count)
        #expect(calls.first?.first?.text == "My sister Aoife moved to Galway in March")
        for slice in calls {
            let prompt = MemoryDistillationPrompt.build(turns: slice)
            for turn in slice {
                #expect(prompt.contains(MemoryDistillationPrompt.line(for: turn)))
            }
        }
    }

    @Test("the same fact from two conversations is proposed once; a sensitive one is flagged and unticked")
    func proposalsDedupeAndFlag() async throws {
        let harness = try ImportHarness()
        let bundle = ImportBundle(provider: .chatgpt, conversations: [
            conversation("c1", at: 1, [(.user, "Kev keeps bees in Kinsale")]),
            conversation("c2", at: 2, [(.user, "Kev keeps bees in Kinsale")]),
            conversation("c3", at: 3, [(.user, "Kev takes medication for asthma")]),
        ])

        let proposals = try await harness.pipeline(FlakyDistiller()).propose(bundle)

        #expect(proposals.map(\.fact.text) == ["Kev keeps bees in Kinsale", "Kev takes medication for asthma"])
        #expect(proposals.map(\.conversationID) == ["c1", "c3"])
        #expect(proposals.map(\.acceptedByDefault) == [true, false])
        #expect(proposals.last?.sensitivity == .health)
        #expect(Set(proposals.map(\.id)).count == proposals.count)
    }

    @Test("a distiller failure on one conversation is counted and skipped; the rest still propose")
    func oneFailureDoesNotSinkTheImport() async throws {
        let harness = try ImportHarness()
        let log = ProgressLog()
        let bundle = ImportBundle(provider: .chatgpt, conversations: [
            conversation("c1", at: 1, [(.user, "this one goes boom badly")]),
            conversation("c2", at: 2, [(.user, "Kev keeps bees in Kinsale")]),
        ])

        let proposals = try await harness.pipeline(FlakyDistiller()).propose(bundle) { log.record($0) }

        #expect(proposals.map(\.fact.text) == ["Kev keeps bees in Kinsale"])
        #expect(log.all().map(\.completed) == [1, 2])
        #expect(log.all().last?.failed == 1)
        #expect(log.all().allSatisfy { $0.phase == .proposing && $0.total == 2 })
    }

    @Test("OKF facts skip the distiller and become proposals as they are")
    func okfFactsSkipTheDistiller() async throws {
        let harness = try ImportHarness(tag: ImportSourceTag(provider: .m1k3, date: utcDate(2026, 10, 26)))
        let spy = SpyDistiller()
        let bundle = ImportBundle(provider: .m1k3, facts: [
            ImportedFact(kind: .profile, text: "Kev keeps bees", title: "Bees", createdAt: nil, originalSource: "distilled"),
        ])

        let proposals = try await harness.pipeline(spy).propose(bundle)

        #expect(proposals.map(\.fact) == [DistilledFact(text: "Kev keeps bees", kind: .profile)])
        #expect(proposals.first?.conversationID == nil)
        #expect(proposals.first?.sourceTitle == "Bees")
        #expect(await spy.calls.isEmpty)
    }

    // MARK: - commit

    @Test("commit writes only the accepted facts, tagged in both stores with the mapped kind")
    func commitTagsBothStores() async throws {
        let harness = try ImportHarness()
        let bundle = ImportBundle(provider: .chatgpt, conversations: [
            conversation("c1", [(.user, "Kev keeps bees in Kinsale")]),
            conversation("c2", [(.user, "Kev plays the fiddle in Cobh")]),
        ])
        let pipeline = harness.pipeline(FlakyDistiller())
        let proposals = try await pipeline.propose(bundle)
        let accepted = proposals.filter { $0.fact.text.contains("bees") }

        let receipt = try await pipeline.commit(accepted, from: bundle)

        #expect(receipt.factsWritten == 1)
        let item = try #require(try harness.corpusItem(titled: "Kev keeps bees"))
        #expect(item.kind == .memory)
        #expect(item.source == harness.tag.knowledgeSource)
        let row = try #require(try harness.graphRow("Kev keeps bees in Kinsale"))
        #expect(row.source == harness.tag.graphSource)
        #expect(row.kind == .note)
        #expect(try harness.corpusItem(titled: "Kev plays") == nil)
        #expect(try harness.graphRow("Kev plays the fiddle in Cobh") == nil)
    }

    @Test("an identical fact dedupes; a restatement supersedes the live twin; one live row either way")
    func duplicatesSupersedeNotDouble() async throws {
        let harness = try ImportHarness()
        try await harness.seedLive("\(filler) dublin", said: "\(filler) dublin")
        #expect(MemoryDistillationCoordinator.semanticDedupeThreshold(for: harness.embedder) == EmbedderFloors.hashing.dedupe)

        let same = ImportBundle(provider: .chatgpt, conversations: [conversation("c1", [(.user, "\(filler) dublin")])])
        let samePipeline = harness.pipeline(ScriptedDistiller(["\(filler) dublin"]))
        let sameReceipt = try await samePipeline.commit(samePipeline.propose(same), from: same)
        #expect(sameReceipt.factsWritten == 0)
        #expect(try harness.memory.liveCount() == 1)
        #expect(try harness.knowledge.allItems(kind: .memory).count == 1)

        let moved = ImportBundle(provider: .chatgpt, conversations: [conversation("c2", [(.user, "\(filler) ardmore")])])
        let movedPipeline = harness.pipeline(ScriptedDistiller(["\(filler) ardmore"]))
        let movedReceipt = try await movedPipeline.commit(movedPipeline.propose(moved), from: moved)

        #expect(movedReceipt.factsWritten == 1)
        #expect(try harness.memory.liveCount() == 1)
        let old = try #require(try harness.graphRow("\(filler) dublin"))
        let new = try #require(try harness.graphRow("\(filler) ardmore"))
        #expect(old.supersededBy == new.id)
        #expect(new.source == harness.tag.graphSource)
        #expect(try harness.knowledge.allItems(kind: .memory).count == 1)
        #expect(try harness.knowledge.allItems(kind: .memorySuperseded).count == 1)
    }

    @Test("each conversation is filed once as cited knowledge, never as a memory; a re-commit files nothing")
    func conversationsBecomeCitedKnowledge() async throws {
        let harness = try ImportHarness()
        let bundle = ImportBundle(provider: .chatgpt, conversations: [
            conversation("c1", [(.user, "Where should the beehives face"), (.assistant, "South east, out of the wind.")]),
            conversation("c2", [(.user, "Tune the fiddle to GDAE"), (.assistant, "Low to high: G, D, A, E.")]),
        ])
        let pipeline = harness.pipeline(ScriptedDistiller([]))

        let receipt = try await pipeline.commit([], from: bundle)

        #expect(receipt == ImportReceipt(factsWritten: 0, conversationsFiled: 2, conversationsAlreadyFiled: 0))
        let items = try harness.knowledge.allItems(kind: .conversation)
        #expect(Set(items.compactMap(\.sourceRef)) == [
            harness.tag.conversationSourceRef(id: "c1"), harness.tag.conversationSourceRef(id: "c2"),
        ])
        #expect(items.allSatisfy { $0.source == harness.tag.knowledgeSource })
        #expect(try harness.memory.totalCount() == 0)
        #expect(try harness.knowledge.allItems(kind: .memory).isEmpty)

        let query = "where should the beehives face"
        let hits = try await harness.knowledge.searchGrounding(
            query: query, queryVector: harness.embedder.embedQuery(query)
        )
        let (knowledge, memories) = GroundingGate.partition(hits, floors: .hashing)
        #expect(knowledge.first?.itemTitle == "Conversation c1")
        #expect(memories.isEmpty)

        let again = try await pipeline.commit([], from: bundle)
        #expect(again == ImportReceipt(factsWritten: 0, conversationsFiled: 0, conversationsAlreadyFiled: 2))
        #expect(try harness.knowledge.allItems(kind: .conversation).count == 2)
    }

    @Test("commit reports one progress step per conversation and OKF batch, in order")
    func commitProgress() async throws {
        let harness = try ImportHarness()
        let log = ProgressLog()
        let bundle = ImportBundle(
            provider: .chatgpt,
            conversations: [conversation("c1", at: 2, [(.user, "a b")]), conversation("c2", at: 1, [(.user, "c d")])]
        )

        _ = try await harness.pipeline(ScriptedDistiller([])).commit([], from: bundle) { log.record($0) }

        #expect(log.all().map(\.completed) == [1, 2])
        #expect(log.all().allSatisfy { $0.phase == .committing && $0.total == 2 })
        let filed = try harness.knowledge.allItems(kind: .conversation)
        #expect(filed.count == 2)
    }
}
