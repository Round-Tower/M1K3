//
//  ImportedStyleTests.swift
//  M1K3ImportTests
//
//  #699 × #711, Kev's ruling (2026-10-27): a style ask found in an imported chat files as a
//  PREFERENCE. It is listed in Memories like any fact, but it never rides the system prompt and
//  never retires a live ask: an old conversation's "shorter, please" is history, not what the
//  user wants now. The same rule OKF's style→note mapping keeps. Pinned on both halves: the
//  review shows a preference, and a commit writes one, whatever the proposal says.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85, Prior: none (new file)
//

import Foundation
import M1K3Chat
@testable import M1K3Import
@testable import M1K3Knowledge
import M1K3Memory
import M1K3MemoryChatBridge
import Testing

/// Returns the same typed facts for every slice.
private struct TypedDistiller: MemoryDistilling {
    let facts: [DistilledFact]

    func distill(turns _: [ChatTurn]) async throws -> [DistilledFact] {
        facts
    }
}

struct ImportedStyleTests {
    private let short = "The user prefers short answers."
    private let long = "The user prefers long, detailed answers."

    @Test("an asked-for style in an imported chat is proposed as a preference")
    func proposedAsAPreference() async throws {
        let harness = try ImportHarness()
        let bundle = ImportBundle(provider: .chatgpt, conversations: [conversation("c1", [
            (.user, "Please keep your answers short from now on."),
            (.assistant, "Will do."),
        ])])
        let pipeline = harness.pipeline(TypedDistiller(facts: [DistilledFact(text: short, kind: .style)]))

        let proposals = try await pipeline.propose(bundle)

        #expect(proposals.map(\.fact) == [DistilledFact(text: short, kind: .preference)])
    }

    @Test("an import stating 'short' while 'long' is live leaves 'long' live, and files 'short' as a preference")
    func importNeverRetiresALiveAsk() async throws {
        let harness = try ImportHarness()
        // The user's live ask, written the way live distillation writes it.
        try await MemoryDistillationCoordinator(
            distiller: TypedDistiller(facts: []),
            ingester: DocumentIngester(store: harness.knowledge, embedder: harness.embedder),
            store: harness.knowledge,
            embedder: harness.embedder,
            graph: DistilledFactGraphAdapter(store: harness.memory),
            selfNames: .none
        ).store([DistilledFact(text: long, kind: .style)])
        let bundle = ImportBundle(provider: .chatgpt, conversations: [])
        // A proposal still typed .style (built by hand): commit files it as a preference anyway.
        let proposal = ImportProposal(
            id: 0, fact: DistilledFact(text: short, kind: .style), conversationID: nil, sourceTitle: nil,
            sensitivity: nil
        )

        let receipt = try await harness.pipeline(TypedDistiller(facts: []))
            .commit([proposal], from: bundle, filing: .none)

        #expect(receipt.factsWritten == 1)
        #expect(try harness.memory.liveStyleTexts() == [long])
        #expect(try harness.graphRow(short)?.kind == .preference)
        #expect(try harness.graphRow(short)?.supersededBy == nil)
        #expect(try harness.graphRow(long)?.supersededBy == nil)
        #expect(try harness.corpusItem(forFact: long)?.kind == .memory)
        #expect(try harness.corpusItem(forFact: short)?.kind == .memory)
    }
}
