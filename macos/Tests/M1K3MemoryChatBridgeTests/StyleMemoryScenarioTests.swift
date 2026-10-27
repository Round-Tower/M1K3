//
//  StyleMemoryScenarioTests.swift
//  M1K3MemoryChatBridgeTests
//
//  #699 Phase 1, the gates as scenarios over the REAL stores: the distillation
//  coordinator (a fake distiller, the hashing embedder) writes through the real
//  DistilledFactGraphAdapter into a real MemoryStore, and the app's read
//  (`liveStyleTexts`) is what the persona's style line renders from. Pinned here:
//  an asked-for style lands and renders newest first, an unasked one never lands,
//  a correction at the embedder's twin bar (`EmbedderFloors.hashing.dedupe`)
//  supersedes the old ask with its lineage kept, and all of it survives the store
//  being reopened at the same path (a relaunch).
//
//  The hashing embedder's cosine is k shared tokens of n: 19 of 20 is 0.95, over
//  hashing's 0.90 bar, the same engineering MemoryCorrectionTests uses. Whether a
//  REAL style correction reaches EmbeddingGemma's 0.95 bar is the on-device half,
//  the MEMSTAT style-correction class.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85, Prior: none (new file)
//  Review: Kev + claude-opus-5.5, 2026-10-27 — the stored rows also render through the real
//  UserStyleBlock, so the scenario ends at the text the persona carries. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — the kind-blind dedupe, both ways: a store
//  from before #699 that filed the same text as a preference gets its node re-filed as style when the user asks
//  (it vanished as a duplicate before), and a later fact of another kind at the twin bar still supersedes a live
//  style row (pinned as it is: the named cost Kev rules on). Confidence 0.85.
//

import Foundation
@testable import M1K3Chat
import M1K3Inference
@testable import M1K3Knowledge
import M1K3Memory
@testable import M1K3MemoryChatBridge
import Testing

/// 19 shared tokens, so one substituted word lands at 19/20 = 0.95 on the hashing embedder.
private let filler = "alpha beta gamma delta epsilon zeta eta theta iota kappa "
    + "lambda mu nu xi omicron rho sigma tau upsilon"

private struct FakeDistiller: MemoryDistilling {
    let facts: [DistilledFact]

    func distill(turns _: [ChatTurn]) async throws -> [DistilledFact] {
        facts
    }
}

/// The corpus and the graph the app wires, behind one distill call per user turn.
private struct Harness {
    let corpus: KnowledgeStore
    let graph: MemoryStore
    let embedder = HashingEmbeddingService()

    func distill(_ fact: DistilledFact, saying turn: String) async throws -> Int {
        try await MemoryDistillationCoordinator(
            distiller: FakeDistiller(facts: [fact]),
            ingester: DocumentIngester(store: corpus, embedder: embedder),
            store: corpus,
            embedder: embedder,
            graph: DistilledFactGraphAdapter(store: graph),
            selfNames: .none
        ).distillAndStore(turns: [
            ChatTurn(role: .user, text: turn),
            ChatTurn(role: .assistant, text: "Noted."),
        ])
    }
}

struct StyleMemoryScenarioTests {
    @Test("asked-for styles land in the graph and read back newest first; an unasked one never lands")
    func askedStylesReadNewestFirst() async throws {
        let harness = try Harness(corpus: KnowledgeStore(), graph: MemoryStore(path: nil))

        #expect(try await harness.distill(
            DistilledFact(text: "The user prefers short answers.", kind: .style), saying: "short answers please"
        ) == 1)
        #expect(try await harness.distill(
            DistilledFact(text: "The user wants no bullet lists.", kind: .style), saying: "no bullet lists"
        ) == 1)
        #expect(try await harness.distill(
            DistilledFact(text: "The user prefers formal replies.", kind: .style),
            saying: "formal replies are what my boss sends"
        ) == 0)

        #expect(try harness.graph.liveStyleTexts() == [
            "The user wants no bullet lists.",
            "The user prefers short answers.",
        ])
        // …and that is the order the persona's style line reads them in.
        #expect(try UserStyleBlock.render(
            newestFirst: harness.graph.liveStyleTexts(), cap: M1K3Persona.styleCharacterCap
        ) == "The user wants no bullet lists. The user prefers short answers.")
    }

    @Test("a correction at the hashing twin bar supersedes the old ask, keeps its lineage, and survives a reopen")
    func correctionSupersedesAndSurvivesAReopen() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m1k3-style-scenario-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("memory.sqlite").path

        let prior = "\(filler) short"
        let correction = "\(filler) long"
        let embedder = HashingEmbeddingService()
        let bar = MemoryDistillationCoordinator.semanticDedupeThreshold(for: embedder)
        #expect(bar == EmbedderFloors.hashing.dedupe)
        let cosine = try await VectorMath.cosineSimilarity(embedder.embed(prior), embedder.embed(correction))
        #expect(cosine >= bar, "the engineered twin sits at \(cosine), the bar at \(bar)")

        do {
            let harness = try Harness(corpus: KnowledgeStore(), graph: MemoryStore(path: path))
            #expect(try await harness.distill(
                DistilledFact(text: prior, kind: .style), saying: "please keep it \(filler) short"
            ) == 1)
            #expect(try await harness.distill(
                DistilledFact(text: correction, kind: .style), saying: "actually, make it \(filler) long please"
            ) == 1)

            #expect(try harness.graph.liveStyleTexts() == [correction])
            let all = try harness.graph.allMemories(includeSuperseded: true)
            let head = try #require(all.first { $0.text == correction })
            let lineage = SupersessionChain.history(endingAt: head, in: all)
            #expect(lineage.map(\.text) == [prior, correction])
            #expect(lineage.allSatisfy { $0.kind == .style })
        }

        let reopened = try MemoryStore(path: path)
        #expect(try reopened.liveStyleTexts() == [correction])
    }

    @Test("a store from before #699 that filed the ask as a preference gets it re-filed as style when the user asks")
    func preferenceRowIsRefiledByAnAsk() async throws {
        let harness = try Harness(corpus: KnowledgeStore(), graph: MemoryStore(path: nil))
        // Before #699 the distiller had no style kind: the same words landed as a preference.
        #expect(try await harness.distill(
            DistilledFact(text: "The user prefers short answers.", kind: .preference),
            saying: "I prefer short answers, honestly"
        ) == 1)
        #expect(try harness.graph.liveStyleTexts().isEmpty)

        #expect(try await harness.distill(
            DistilledFact(text: "The user prefers short answers.", kind: .style), saying: "short answers please"
        ) == 1)

        #expect(try harness.graph.liveStyleTexts() == ["The user prefers short answers."])
        #expect(try harness.graph.allMemories().count == 1)
        #expect(try harness.corpus.allItems(kind: .memory).count == 1)
    }

    @Test("known cost, Kev's call: a later fact of another kind at the twin bar supersedes a live style row")
    func crossKindTwinSupersedesAStyleRow() async throws {
        let harness = try Harness(corpus: KnowledgeStore(), graph: MemoryStore(path: nil))
        #expect(try await harness.distill(
            DistilledFact(text: "\(filler) short", kind: .style), saying: "please keep it \(filler) short"
        ) == 1)

        // The coordinator's twin search ignores kind, and the adapter supersedes by text.
        #expect(try await harness.distill(
            DistilledFact(text: "\(filler) long", kind: .note), saying: "\(filler) long"
        ) == 1)

        #expect(try harness.graph.liveStyleTexts().isEmpty) // the style line has lost the ask
        #expect(try harness.graph.allMemories().map(\.kind) == [.note])
    }
}
