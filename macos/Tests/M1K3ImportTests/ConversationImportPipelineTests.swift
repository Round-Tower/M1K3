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
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — pins what the review found unpinned: last-wins
//  attribution (A, B, A ends with A live), chronological commit whatever the export order, the caller's `filing`
//  choice, OKF facts committed in batches with their kinds, loose facts, a failing fact or transcript counted and
//  retried, a cancel inside a write or inside the distiller. Confidence 0.85.

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
        // Last wins: the bees fact moves to c2, the newer conversation that said it.
        #expect(proposals.map(\.conversationID) == ["c2", "c3"])
        #expect(proposals.first?.statedIn == ["c1", "c2"])
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

        let receipt = try await pipeline.commit(accepted, from: bundle, filing: .all)

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
        let sameReceipt = try await samePipeline.commit(samePipeline.propose(same), from: same, filing: .all)
        #expect(sameReceipt.factsWritten == 0)
        #expect(try harness.memory.liveCount() == 1)
        #expect(try harness.knowledge.allItems(kind: .memory).count == 1)

        let moved = ImportBundle(provider: .chatgpt, conversations: [conversation("c2", [(.user, "\(filler) ardmore")])])
        let movedPipeline = harness.pipeline(ScriptedDistiller(["\(filler) ardmore"]))
        let movedReceipt = try await movedPipeline.commit(movedPipeline.propose(moved), from: moved, filing: .all)

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

        let receipt = try await pipeline.commit([], from: bundle, filing: .all)

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

        let again = try await pipeline.commit([], from: bundle, filing: .all)
        #expect(again == ImportReceipt(factsWritten: 0, conversationsFiled: 0, conversationsAlreadyFiled: 2))
        #expect(try harness.knowledge.allItems(kind: .conversation).count == 2)
    }

    @Test("commit with no accepted facts reports one progress step per filed conversation")
    func commitProgress() async throws {
        let harness = try ImportHarness()
        let log = ProgressLog()
        let bundle = ImportBundle(
            provider: .chatgpt,
            conversations: [conversation("c1", at: 2, [(.user, "a b")]), conversation("c2", at: 1, [(.user, "c d")])]
        )

        _ = try await harness.pipeline(ScriptedDistiller([])).commit([], from: bundle, filing: .all) { log.record($0) }

        #expect(log.all().map(\.completed) == [1, 2])
        #expect(log.all().allSatisfy { $0.phase == .committing && $0.total == 2 })
        let filed = try harness.knowledge.allItems(kind: .conversation)
        #expect(filed.count == 2)
    }

    // MARK: - Review fold: attribution and order

    @Test("the same fact said again later moves to the later conversation: A, B, A ends with A live")
    func lastStatementWins() async throws {
        let harness = try ImportHarness()
        let bundle = ImportBundle(provider: .chatgpt, conversations: [
            conversation("c1", at: 1, [(.user, "\(filler) dublin")]),
            conversation("c2", at: 2, [(.user, "\(filler) ardmore")]),
            conversation("c3", at: 3, [(.user, "\(filler) dublin")]),
        ])
        let pipeline = harness.pipeline(FlakyDistiller())

        let proposals = try await pipeline.propose(bundle)

        #expect(proposals.map(\.fact.text) == ["\(filler) dublin", "\(filler) ardmore"])
        #expect(proposals.map(\.id) == [0, 1])
        #expect(proposals.map(\.conversationID) == ["c3", "c2"])
        #expect(proposals.map(\.statedIn) == [["c1", "c3"], ["c2"]])
        #expect(proposals.first?.sourceTitle == "Conversation c3")

        _ = try await pipeline.commit(proposals, from: bundle, filing: .none)

        let dublin = try #require(try harness.graphRow("\(filler) dublin"))
        let ardmore = try #require(try harness.graphRow("\(filler) ardmore"))
        #expect(ardmore.supersededBy == dublin.id)
        #expect(dublin.supersededBy == nil)
        #expect(try harness.memory.liveCount() == 1)
        #expect(try harness.corpusItem(forFact: "\(filler) dublin")?.kind == .memory)
        #expect(try harness.corpusItem(forFact: "\(filler) ardmore")?.kind == .memorySuperseded)
    }

    @Test("propose and commit run oldest first whatever the export's order, so the newer statement wins")
    func commitIsChronological() async throws {
        let harness = try ImportHarness()
        let bundle = ImportBundle(provider: .chatgpt, conversations: [
            conversation("newer", at: 20, [(.user, "\(filler) ardmore")]),
            conversation("older", at: 10, [(.user, "\(filler) dublin")]),
        ])
        let pipeline = harness.pipeline(FlakyDistiller())

        let proposals = try await pipeline.propose(bundle)
        #expect(proposals.map(\.fact.text) == ["\(filler) dublin", "\(filler) ardmore"])
        _ = try await pipeline.commit(proposals, from: bundle, filing: .all)

        let dublin = try #require(try harness.graphRow("\(filler) dublin"))
        let ardmore = try #require(try harness.graphRow("\(filler) ardmore"))
        #expect(dublin.supersededBy == ardmore.id)
        #expect(ardmore.supersededBy == nil)
        #expect(try harness.corpusItem(forFact: "\(filler) dublin")?.kind == .memorySuperseded)
    }

    // MARK: - Review fold: what is filed

    @Test("filing is the caller's choice: none files no transcript, only files exactly the named ones")
    func filingIsTheCallersChoice() async throws {
        let bundle = ImportBundle(provider: .chatgpt, conversations: [
            conversation("c1", at: 1, [(.user, "Kev keeps bees in Kinsale")]),
            conversation("c2", at: 2, [(.user, "Kev takes medication for asthma")]),
        ])

        let memoriesOnly = try ImportHarness()
        let first = memoriesOnly.pipeline(FlakyDistiller())
        let receipt = try await first.commit(first.propose(bundle), from: bundle, filing: .none)
        #expect(receipt == ImportReceipt(factsWritten: 2))
        #expect(try memoriesOnly.knowledge.allItems(kind: .conversation).isEmpty)
        #expect(try memoriesOnly.knowledge.itemCount() == 2)
        #expect(try memoriesOnly.knowledge.searchFTS(query: "asthma").allSatisfy { $0.kind == .memory })

        let chosen = try ImportHarness()
        let second = chosen.pipeline(FlakyDistiller())
        let proposals = try await second.propose(bundle)
        // Every fact unticked, one transcript chosen: that one is filed, the other is not.
        let filed = try await second.commit([], from: bundle, filing: .only(["c1"]))
        #expect(filed == ImportReceipt(conversationsFiled: 1))
        #expect(try chosen.knowledge.allItems(kind: .conversation).compactMap(\.sourceRef)
            == [chosen.tag.conversationSourceRef(id: "c1")])
        #expect(try chosen.knowledge.searchFTS(query: "asthma").isEmpty)
        #expect(proposals.last?.acceptedByDefault == false)
    }

    @Test("facts whose conversation is not in the bundle are written; nothing is filed for them")
    func looseFactsWriteWithoutTheirConversation() async throws {
        let harness = try ImportHarness()
        let bundle = ImportBundle(
            provider: .chatgpt, conversations: [conversation("c1", [(.user, "Kev keeps bees in Kinsale")])]
        )
        let pipeline = harness.pipeline(FlakyDistiller())
        let proposals = try await pipeline.propose(bundle)

        let receipt = try await pipeline.commit(
            proposals, from: ImportBundle(provider: .chatgpt), filing: .all
        )

        #expect(receipt == ImportReceipt(factsWritten: 1))
        #expect(try harness.graphRow("Kev keeps bees in Kinsale")?.source == harness.tag.graphSource)
        #expect(try harness.knowledge.allItems(kind: .conversation).isEmpty)
    }

    @Test("OKF facts commit in batches of fifty, one step each, tagged m1k3 with their kinds")
    func okfFactsCommitInBatches() async throws {
        let tag = ImportSourceTag(provider: .m1k3, date: utcDate(2026, 10, 26))
        let harness = try ImportHarness(tag: tag)
        let kinds: [DistilledFactKind] = [.profile, .preference, .note]
        let facts = (0 ..< 120).map { index in
            ImportedFact(
                kind: kinds[index % kinds.count], text: "Kev noted \(distinctWords(index))",
                title: nil, createdAt: nil, originalSource: "distilled"
            )
        }
        let bundle = ImportBundle(provider: .m1k3, facts: facts)
        let pipeline = harness.pipeline(SpyDistiller())
        let log = ProgressLog()

        let receipt = try await pipeline.commit(pipeline.propose(bundle), from: bundle, filing: .all) { log.record($0) }

        #expect(receipt == ImportReceipt(factsWritten: 120))
        #expect(log.all().map(\.completed) == [1, 2, 3])
        #expect(log.all().allSatisfy { $0.phase == .committing && $0.total == 3 })
        #expect(try harness.memory.memories(source: tag.graphSource).count == 120)
        #expect(try harness.memory.liveCount() == 120)
        #expect(try harness.knowledge.itemIDs(source: tag.knowledgeSource).count == 120)
        #expect(try harness.graphRow(facts[0].text)?.kind == .profile)
        #expect(try harness.graphRow(facts[1].text)?.kind == .preference)
        #expect(try harness.graphRow(facts[2].text)?.kind == .note)
    }

    // MARK: - Review fold: failure and cancellation

    @Test("a failing fact or transcript is counted and skipped; the next commit writes and files it")
    func failuresAreCountedAndRetried() async throws {
        let harness = try ImportHarness(embedder: FailingEmbedder(marker: "zap"))
        let bundle = ImportBundle(provider: .chatgpt, conversations: [
            conversation("c1", at: 1, [(.user, "Kev keeps bees in Kinsale")]),
            conversation("c2", at: 2, [(.user, "Kev owns a zap gun from 1985")]),
            conversation("c3", at: 3, [(.user, "Kev plays the fiddle in Cobh")]),
        ])
        let pipeline = harness.pipeline(FlakyDistiller())
        let proposals = try await pipeline.propose(bundle)
        let log = ProgressLog()

        let receipt = try await pipeline.commit(proposals, from: bundle, filing: .all) { log.record($0) }

        #expect(receipt == ImportReceipt(
            factsWritten: 2, factsFailed: 1, conversationsFiled: 2, conversationsFailed: 1
        ))
        #expect(log.all().map(\.completed) == [1, 2, 3, 4])
        #expect(try harness.graphRow("Kev owns a zap gun from 1985") == nil)

        let healthy = harness.pipeline(FlakyDistiller(), embedder: HashingEmbeddingService())
        let retry = try await healthy.commit(proposals, from: bundle, filing: .all)

        #expect(retry == ImportReceipt(factsWritten: 1, conversationsFiled: 1, conversationsAlreadyFiled: 2))
        #expect(try harness.memory.totalCount() == 3)
        #expect(try harness.knowledge.allItems(kind: .conversation).count == 3)
    }

    @Test("a cancel inside a fact write returns the partial receipt, not a throw")
    func cancelInsideAWriteReturnsThePartialReceipt() async throws {
        let harness = try ImportHarness(embedder: FailingEmbedder(marker: "zap", cancels: true))
        let bundle = ImportBundle(provider: .chatgpt, conversations: [
            conversation("c1", at: 1, [(.user, "Kev keeps bees in Kinsale")]),
            conversation("c2", at: 2, [(.user, "Kev owns a zap gun from 1985")]),
            conversation("c3", at: 3, [(.user, "Kev plays the fiddle in Cobh")]),
        ])
        let pipeline = harness.pipeline(FlakyDistiller())

        let receipt = try await pipeline.commit(pipeline.propose(bundle), from: bundle, filing: .all)

        #expect(receipt == ImportReceipt(factsWritten: 1, wasCancelled: true))
        #expect(try harness.knowledge.allItems(kind: .conversation).isEmpty)
    }

    @Test("a distiller that throws CancellationError cancels propose; it is not counted as a failure")
    func cancelInsideTheDistillerPropagates() async throws {
        let harness = try ImportHarness()
        let log = ProgressLog()
        let bundle = ImportBundle(
            provider: .chatgpt, conversations: [conversation("c1", [(.user, "Kev keeps bees in Kinsale")])]
        )

        await #expect(throws: CancellationError.self) {
            try await harness.pipeline(CancellingDistiller()).propose(bundle) { log.record($0) }
        }
        #expect(log.all().isEmpty)
    }
}
