//
//  MemoryDistillationCoordinatorStyleTests.swift
//  M1K3ChatTests
//
//  #699: the coordinator and the `style` kind. A style fact rides every system prompt once
//  stored, so it needs StyleAskFence's explicit ask on top of #284's anchor rule; `didWrite`
//  tells the app to re-read the style rows, once per writing slice and also when a later fact
//  threw after earlier ones landed; and a style ask whose exact words a pre-#699 store already
//  holds under another kind re-files that graph node instead of vanishing as a duplicate.
//  Split from MemoryDistillationCoordinatorTests with its own fixtures, so neither file
//  outgrows its lint bounds.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85, Prior: the first three tests
//  moved here unchanged from MemoryDistillationCoordinatorTests (this PR's earlier commit).
//

import Foundation
@testable import M1K3Chat
@testable import M1K3Knowledge
import Testing

private struct Scripted: MemoryDistilling {
    let facts: [DistilledFact]
    func distill(turns _: [ChatTurn]) async throws -> [DistilledFact] {
        facts
    }
}

/// Records which facts reached the graph, with which kind, and every re-file asked for.
private actor GraphSpy: DistilledFactGraphWriting {
    private(set) var writes: [(text: String, kind: DistilledFactKind)] = []
    private(set) var refiles: [(text: String, kind: DistilledFactKind)] = []
    let refileAnswer: Bool
    init(refileAnswer: Bool = true) {
        self.refileAnswer = refileAnswer
    }

    func writeDistilledFact(
        _ text: String, kind: DistilledFactKind, embedding _: [Float], superseding _: String?
    ) async throws {
        writes.append((text, kind))
    }

    func reviveFact(_ text: String, kind: DistilledFactKind, embedding _: [Float]) async throws -> String? {
        writes.append((text, kind))
        return nil
    }

    func refileDistilledFact(_ text: String, as kind: DistilledFactKind, embedding _: [Float]) async throws -> Bool {
        refiles.append((text, kind))
        return refileAnswer
    }

    func texts() -> [String] {
        writes.map(\.text)
    }

    func kinds() -> [DistilledFactKind] {
        writes.map(\.kind)
    }
}

/// A coordinator over typed facts, with the `didWrite` hook.
private func makeFixture(
    _ facts: [DistilledFact],
    graph: (any DistilledFactGraphWriting)? = nil,
    didWrite: (@Sendable (Int) -> Void)? = nil
) throws -> (MemoryDistillationCoordinator, KnowledgeStore) {
    let store = try KnowledgeStore()
    let embedder = HashingEmbeddingService()
    return (
        MemoryDistillationCoordinator(
            distiller: Scripted(facts: facts),
            ingester: DocumentIngester(store: store, embedder: embedder),
            store: store,
            embedder: embedder,
            graph: graph,
            didWrite: didWrite,
            selfNames: .none
        ),
        store
    )
}

/// Real user content that anchors every non-style fact these tests use (#284).
private let someTurns = [
    ChatTurn(
        role: .user,
        text: "My sister Aoife lives in Cork, prefers metric units, and decided the memory "
            + "architecture should use the existing knowledge store rather than a separate database."
    ),
    ChatTurn(role: .assistant, text: "Noted!"),
]

struct MemoryDistillationCoordinatorStyleTests {
    @Test("a style fact the user's turns anchor but never ask for is dropped; other kinds are untouched")
    func styleWithoutAnAskIsDropped() async throws {
        let graph = GraphSpy()
        let slice = [
            ChatTurn(role: .user, text: "short answers are what I give at work, and I live in Cork"),
            ChatTurn(role: .assistant, text: "Want me to keep mine short too?"),
        ]
        let (coordinator, store) = try makeFixture([
            DistilledFact(text: "The user prefers short answers.", kind: .style),
            DistilledFact(text: "The user lives in Cork.", kind: .profile),
        ], graph: graph)

        let written = try await coordinator.distillAndStore(turns: slice)

        #expect(written == 1)
        #expect(await graph.kinds() == [.profile])
        #expect(try store.searchFTS(query: "short").isEmpty)
    }

    @Test("a style fact the user asked for lands, and reaches the graph as .style")
    func styleWithAnAskLands() async throws {
        let graph = GraphSpy()
        let slice = [
            ChatTurn(role: .user, text: "can you keep your answers short from now on"),
            ChatTurn(role: .assistant, text: "Short it is."),
        ]
        let (coordinator, _) = try makeFixture(
            [DistilledFact(text: "The user prefers short answers.", kind: .style)], graph: graph
        )

        let written = try await coordinator.distillAndStore(turns: slice)

        #expect(written == 1)
        #expect(await graph.kinds() == [.style])
        #expect(await graph.texts() == ["The user prefers short answers."])
    }

    @Test("didWrite fires once with the count when facts land, and not at all when nothing did")
    func didWriteFiresOncePerWritingSlice() async throws {
        nonisolated(unsafe) var calls: [Int] = []
        let (coordinator, _) = try makeFixture(
            [
                DistilledFact(text: "Kev's sister is called Aoife.", kind: .profile),
                DistilledFact(text: "The user prefers metric units.", kind: .preference),
            ],
            didWrite: { calls.append($0) }
        )

        #expect(try await coordinator.distillAndStore(turns: someTurns) == 2)
        #expect(calls == [2])

        // The same slice again: both are exact duplicates, nothing is written, nothing fires.
        #expect(try await coordinator.distillAndStore(turns: someTurns) == 0)
        #expect(calls == [2])
    }

    @Test("didWrite still fires when a later fact throws after earlier ones landed")
    func didWriteFiresWhenALaterFactThrows() async throws {
        nonisolated(unsafe) var calls: [Int] = []
        let (coordinator, store) = try makeFixture(
            [
                DistilledFact(text: "Kev's sister is called Aoife.", kind: .profile),
                // Markup: the ingester refuses it (markupNotProse), after the first fact is in.
                DistilledFact(text: "<html> Aoife lives in Cork </html>", kind: .note),
            ],
            didWrite: { calls.append($0) }
        )

        await #expect(throws: DocumentIngester.IngestError.markupNotProse) {
            try await coordinator.distillAndStore(turns: someTurns)
        }
        #expect(calls == [1]) // the style re-read still runs for the fact that landed
        #expect(try store.allItems(kind: .memory).count == 1)
    }

    // MARK: - A style fact already filed under another kind (#699)

    @Test("an asked-for style fact whose exact text lives under another kind re-files it, and counts as written")
    func styleExactDupRefilesTheGraphNode() async throws {
        let graph = GraphSpy()
        nonisolated(unsafe) var calls: [Int] = []
        let store = try KnowledgeStore()
        let embedder = HashingEmbeddingService()
        func coordinator(_ fact: DistilledFact) -> MemoryDistillationCoordinator {
            MemoryDistillationCoordinator(
                distiller: Scripted(facts: [fact]),
                ingester: DocumentIngester(store: store, embedder: embedder),
                store: store, embedder: embedder, graph: graph,
                didWrite: { calls.append($0) }, selfNames: .none
            )
        }
        let ask = [ChatTurn(role: .user, text: "can you keep your answers short please")]
        // A pre-#699 store: the same text, filed as a preference.
        _ = try await coordinator(DistilledFact(text: "The user prefers short answers.", kind: .preference))
            .distillAndStore(turns: ask)

        let written = try await coordinator(DistilledFact(text: "The user prefers short answers.", kind: .style))
            .distillAndStore(turns: ask)

        #expect(written == 1)
        #expect(calls == [1, 1])
        #expect(await graph.refiles.map(\.kind) == [.style])
        #expect(try store.allItems(kind: .memory).count == 1) // the corpus twin already answers
    }

    @Test("an exact duplicate that is not a style fact never asks the graph to re-file, nor one the graph declines")
    func onlyStyleDupsRefile() async throws {
        let graph = GraphSpy(refileAnswer: false)
        let (first, store) = try makeFixture([DistilledFact(text: "Kev lives in Cork.")], graph: graph)
        _ = try await first.distillAndStore(turns: someTurns)
        #expect(try await first.distillAndStore(turns: someTurns) == 0)
        #expect(await graph.refiles.isEmpty)

        // A style dup the graph declines (already style): a true duplicate, nothing written.
        let ask = [ChatTurn(role: .user, text: "Kev lives in Cork, please keep that in mind")]
        let style = MemoryDistillationCoordinator(
            distiller: Scripted(facts: [DistilledFact(text: "Kev lives in Cork.", kind: .style)]),
            ingester: DocumentIngester(store: store, embedder: HashingEmbeddingService()),
            store: store, embedder: HashingEmbeddingService(), graph: graph, selfNames: .none
        )
        #expect(try await style.distillAndStore(turns: ask) == 0)
        #expect(await graph.refiles.count == 1)
    }
}
