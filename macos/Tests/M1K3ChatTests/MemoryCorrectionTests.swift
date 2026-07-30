//
//  MemoryCorrectionTests.swift
//  M1K3ChatTests
//
//  Tier 2 (scratch/dream-cycle/SPEC.md): write-time repair. The MEMSTAT
//  census proved the old behaviour eats 3/10 corrections (a ≥ 0.90 twin
//  silently `continue`d) and that no cosine bar separates correction from
//  restatement — so at the dedupe bar the coordinator now SUPERSEDES the
//  twin instead of discarding the new fact. A misclassified restatement
//  supersede is a harmless refresh (same meaning, newer date); an eaten
//  correction was a lost truth. Compatibles never reach the bar (measured
//  max 0.768), so they still plain-insert.
//
//  Hashing-embedder cosines are engineered exactly: k shared tokens of n
//  gives k/n, so 19-of-20 = 0.95 (twin) and 10-of-20 = 0.5 (compatible).
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.9 (mechanism
//  pinned against engineered cosines; the live regime is MEMSTAT-verified
//  on-device). Prior: MemoryDistillationCoordinatorTests (Kev +
//  claude-fable-5).
//

import Foundation
@testable import M1K3Chat
@testable import M1K3Knowledge
import Testing

/// 20 shared filler tokens so one substituted word stays above the 0.90 bar.
private let filler = "alpha beta gamma delta epsilon zeta eta theta iota kappa "
    + "lambda mu nu xi omicron rho sigma tau upsilon"
private let priorFact = "\(filler) dublin"
private let correctionFact = "\(filler) ardmore"
private let compatibleFact = "alpha beta gamma delta epsilon zeta eta theta iota kappa "
    + "one two three four five six seven eight nine ten"

private struct ScriptedDistiller: MemoryDistilling {
    let texts: [String]
    func distill(turns _: [ChatTurn]) async throws -> [DistilledFact] {
        texts.map { DistilledFact(text: $0) }
    }
}

/// Records supersede/revive traffic across the graph seam.
private actor SpyGraphWriter: DistilledFactGraphWriting {
    private(set) var plainWrites: [String] = []
    private(set) var supersedeWrites: [(text: String, superseding: String)] = []
    private(set) var revives: [String] = []
    /// What reviveFact reports as the supplanted live head.
    let supplantedText: String?

    init(supplantedText: String? = nil) {
        self.supplantedText = supplantedText
    }

    func writeDistilledFact(
        _ text: String, kind _: DistilledFactKind, embedding _: [Float], superseding oldFactText: String?
    ) async throws {
        if let oldFactText {
            supersedeWrites.append((text, oldFactText))
        } else {
            plainWrites.append(text)
        }
    }

    func reviveFact(_ text: String, kind _: DistilledFactKind, embedding _: [Float]) async throws -> String? {
        revives.append(text)
        return supplantedText
    }

    func supersededTexts() -> [String] {
        supersedeWrites.map(\.superseding)
    }

    func plainTexts() -> [String] {
        plainWrites
    }

    func revivedTexts() -> [String] {
        revives
    }
}

private struct Fixture {
    let store: KnowledgeStore
    let embedder = HashingEmbeddingService()
    let graph: SpyGraphWriter?

    init(graph: SpyGraphWriter?) throws {
        store = try KnowledgeStore()
        self.graph = graph
    }

    func coordinator(
        _ texts: [String],
        rekind: (@Sendable (UUID, KnowledgeKind) throws -> Bool)? = nil,
        auditSink: (@Sendable (String) -> Void)? = nil
    ) -> MemoryDistillationCoordinator {
        MemoryDistillationCoordinator(
            distiller: ScriptedDistiller(texts: texts),
            ingester: DocumentIngester(store: store, embedder: embedder),
            store: store,
            embedder: embedder,
            graph: graph,
            rekind: rekind,
            auditSink: auditSink
        )
    }

    func distill(_ texts: [String]) async throws -> Int {
        try await coordinator(texts).distillAndStore(turns: [ChatTurn(role: .user, text: "t")])
    }

    func kind(ofItemContaining text: String) throws -> KnowledgeKind? {
        try store.allItems(kind: nil, limit: 100).first { $0.title.contains(textPrefix(text)) }?.kind
            ?? store.allItems(kind: .memorySuperseded, limit: 100)
            .first { $0.title.contains(textPrefix(text)) }?.kind
    }

    private func textPrefix(_ text: String) -> String {
        String(text.suffix(6)) // the discriminating tail token
    }
}

struct MemoryCorrectionTests {
    @Test("a ≥0.90 twin is superseded, not eaten — the correction lands")
    func correctionSupersedes() async throws {
        let f = try Fixture(graph: SpyGraphWriter())
        #expect(try await f.distill([priorFact]) == 1)

        let written = try await f.distill([correctionFact])

        #expect(written == 1)
        // Graph seam saw a supersede naming the prior's text.
        #expect(await f.graph?.supersededTexts() == [priorFact])
        // Corpus: prior re-kinded out of retrieval, correction live.
        #expect(try f.store.searchFTS(query: "ardmore", kinds: [.memory]).count == 1)
        #expect(try f.store.searchFTS(query: "dublin", kinds: [.memory]).isEmpty)
        #expect(try f.store.allItems(kind: .memorySuperseded).count == 1)
    }

    @Test("a sub-bar same-subject fact plain-inserts — compatibles never supersede")
    func compatibleInsertsPlain() async throws {
        let f = try Fixture(graph: SpyGraphWriter())
        _ = try await f.distill([priorFact])

        let written = try await f.distill([compatibleFact])

        #expect(written == 1)
        #expect(await f.graph?.supersededTexts().isEmpty == true)
        // Both facts live.
        #expect(try f.store.allItems(kind: .memory).count == 2)
        #expect(try f.store.allItems(kind: .memorySuperseded).isEmpty)
    }

    @Test("an exact re-assertion of a LIVE fact is still eaten (idempotence)")
    func exactLiveStillEaten() async throws {
        let f = try Fixture(graph: SpyGraphWriter())
        _ = try await f.distill([priorFact])

        let written = try await f.distill([priorFact])

        #expect(written == 0)
        #expect(await f.graph?.supersededTexts().isEmpty == true)
        #expect(await f.graph?.revivedTexts().isEmpty == true)
    }

    @Test("re-asserting a superseded fact REVIVES it instead of vanishing")
    func reassertRevives() async throws {
        let f = try Fixture(graph: SpyGraphWriter(supplantedText: correctionFact))
        _ = try await f.distill([priorFact])
        _ = try await f.distill([correctionFact]) // prior now superseded

        let written = try await f.distill([priorFact]) // the user repair

        #expect(written == 1)
        #expect(await f.graph?.revivedTexts() == [priorFact])
        // Corpus: prior back in retrieval, the supplanted corrector re-kinded out.
        #expect(try f.store.searchFTS(query: "dublin", kinds: [.memory]).count == 1)
        #expect(try f.store.searchFTS(query: "ardmore", kinds: [.memory]).isEmpty)
    }

    @Test("graph-less callers still get the corpus half of the repair")
    func graphlessCorpusRepair() async throws {
        let f = try Fixture(graph: nil)
        _ = try await f.distill([priorFact])

        let written = try await f.distill([correctionFact])

        #expect(written == 1)
        #expect(try f.store.searchFTS(query: "dublin", kinds: [.memory]).isEmpty)
        #expect(try f.store.searchFTS(query: "ardmore", kinds: [.memory]).count == 1)
    }

    @Test("a corpus re-kind failure after the graph commit fires the audit, never throws")
    func corpusDivergenceAudited() async throws {
        let f = try Fixture(graph: SpyGraphWriter())
        _ = try await f.distill([priorFact])

        nonisolated(unsafe) var audits: [String] = []
        let coordinator = f.coordinator(
            [correctionFact],
            rekind: { _, _ in false }, // the transition fails after the graph write
            auditSink: { audits.append($0) }
        )
        let written = try await coordinator.distillAndStore(
            turns: [ChatTurn(role: .user, text: "t")]
        )

        #expect(written == 1) // the correction itself still landed
        #expect(await f.graph?.supersededTexts() == [priorFact]) // graph committed
        #expect(audits.count == 1)
        #expect(audits[0].contains("divergence"))
    }
}
