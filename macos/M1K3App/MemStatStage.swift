//
//  MemStatStage.swift
//  M1K3App
//
//  Tier 0 of the dream-cycle plan (scratch/dream-cycle/SPEC.md): the
//  measurement arm that decides every later tier. Three passes, all
//  read-only against the REAL container stores (SelfTest mode never
//  constructs AppEnvironment, so this process is the only reader):
//
//    1. CENSUS — live node/per-kind/superseded counts from the real memory
//       graph, corpus-twin counts from knowledge.sqlite, and the full
//       pairwise cosine histogram over the live graph vectors (n² over a
//       personal graph = seconds). Settles whether the ≥ 0.90 band is
//       populated at all (challenger #3) and whether [0.75, 0.90) has a
//       mineable population (challenger #4).
//    2. PAIR PROBES — the hand-authored contradiction / compatible /
//       restatement pairs embedded with the production embedder. Settles
//       which cosine regime the Dublin/Ardmore correction shape lives in
//       (challenger #2): if contradictions land ≥ 0.90 the ingest dedupe
//       EATS corrections and Tier 2's repair is mandatory.
//    3. INGEST PROBE — every pair driven through the REAL
//       MemoryDistillationCoordinator (scripted distiller, in-memory store,
//       production embedder): seed the prior, distill the revision, report
//       survived/EATEN. The end-to-end answer to "are corrections eaten at
//       write time?", not a proxy.
//
//      M1K3_SELFTEST=1 M1K3_SELFTEST_MEMSTAT=1  (via .m1k3-selftest.json)
//
//  Fact text in this report renders ONLY into the SelfTest OUT file
//  (spec §1: logs carry counts + IDs; SelfTest reports may carry text).
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.8 (logic cores are
//  the unit-tested MemoryCosineStats / ContradictionEvalReport / coordinator;
//  the wiring is verify-by-launch like every SelfTest arm). Prior:
//  MemGraphEvalStage (Kev + claude-opus-4-8).
//

import Foundation
import M1K3Chat
import M1K3Knowledge
import M1K3Memory
import M1K3MLX

enum MemStatStage {
    static var isRequested: Bool {
        SelfTestEnv.value("M1K3_SELFTEST_MEMSTAT") == "1"
    }

    static func run(emit: @escaping (String) -> Void) async {
        emit("• memstat: Tier-0 dream-cycle census (scratch/dream-cycle/SPEC.md)…")
        await censusRealGraph(emit: emit)
        await probePairs(emit: emit)
        emit("✓ memstat: done")
    }

    // MARK: - Pass 1: the real-graph census

    private static func censusRealGraph(emit: (String) -> Void) async {
        do {
            // storeURL is MainActor-isolated (it lives on AppEnvironment); the
            // hop is for the PATH only — the n² census below stays off main.
            let knowledgeURL = try await MainActor.run { try AppEnvironment.storeURL() }
            let memoryURL = knowledgeURL.deletingLastPathComponent()
                .appendingPathComponent("memory.sqlite")
            guard FileManager.default.fileExists(atPath: memoryURL.path) else {
                emit("✗ memstat census: no memory.sqlite in container — graph census skipped")
                return
            }
            let store = try MemoryStore(path: memoryURL.path)
            let live = try store.liveCount()
            let total = try store.allMemories(includeSuperseded: true, limit: 100_000).count
            let revision = try store.revision()
            emit("memstat graph: \(live) live, \(total - live) superseded, "
                + "\(revision.edgeCount) edge(s)")
            for (kind, count) in try store.liveCountsByKind().sorted(by: { $0.key < $1.key }) {
                emit("memstat kind \(kind): \(count)")
            }
            let vectors = try store.liveEmbeddingVectors()
            emit(MemoryCosineStats.render(MemoryCosineStats.pairwise(vectors)))

            // Corpus twins: the store that actually feeds chat (spec finding #1).
            let corpus = try KnowledgeStore(path: knowledgeURL.path)
            let corpusMemories = try corpus.allItems(kind: .memory, limit: 100_000).count
            let quarantined = try corpus.allItems(kind: .quarantined, limit: 100_000).count
            emit("memstat corpus: \(corpusMemories) memory item(s), \(quarantined) quarantined, "
                + "graph/corpus divergence \(corpusMemories - live)")
        } catch {
            emit("✗ memstat census: \(error)")
        }
    }

    // MARK: - Pass 2 + 3: the probe pairs

    private static let probeClasses: [(label: String, pairs: [ContradictionEvalFixtures.Pair])] = [
        ("contradiction", ContradictionEvalFixtures.contradictions),
        ("compatible", ContradictionEvalFixtures.compatibles),
        ("restatement", ContradictionEvalFixtures.restatements),
    ]

    private static func probePairs(emit: (String) -> Void) async {
        do {
            let embedder = MLXEmbeddingService() // production default — qwen3-embed-512
            let bar = MemoryDistillationCoordinator.semanticDedupeThreshold

            // Pass 2: raw pair cosines, per class.
            var scoresByLabel: [String: [Float]] = [:]
            for cls in probeClasses {
                let priors = try await embedder.embedBatch(cls.pairs.map(\.prior))
                let revisions = try await embedder.embedBatch(cls.pairs.map(\.revision))
                var scores: [Float] = []
                for (index, pair) in cls.pairs.enumerated() {
                    let cosine = VectorMath.cosineSimilarity(priors[index], revisions[index])
                    scores.append(cosine)
                    emit(String(
                        format: "memstat %@ %.3f [%@ → %@]",
                        cls.label, cosine,
                        String(pair.prior.prefix(36)), String(pair.revision.prefix(36))
                    ))
                }
                scoresByLabel[cls.label] = scores
            }
            emit(ContradictionEvalReport.render(
                contradictions: scoresByLabel["contradiction"] ?? [],
                compatibles: scoresByLabel["compatible"] ?? [],
                restatements: scoresByLabel["restatement"] ?? [],
                dedupeBar: bar
            ))

            // Pass 3: the end-to-end ingest probe through the real coordinator.
            for cls in probeClasses {
                var eaten = 0
                var seedFailures = 0
                for pair in cls.pairs {
                    switch try await ingestOutcome(pair, embedder: embedder) {
                    case .eaten:
                        eaten += 1
                        emit("memstat ingest \(cls.label): EATEN [\(pair.revision.prefix(36))]")
                    case .survived:
                        emit("memstat ingest \(cls.label): survived [\(pair.revision.prefix(36))]")
                    case .seedFailed:
                        seedFailures += 1
                        emit("✗ memstat ingest \(cls.label): SEED FAILED [\(pair.prior.prefix(36))]")
                    }
                }
                var summary = "memstat ingest \(cls.label): \(eaten)/\(cls.pairs.count) eaten"
                if seedFailures > 0 { summary += " (\(seedFailures) seed failure(s))" }
                emit(summary)
            }
        } catch {
            emit("✗ memstat probes: \(error)")
        }
    }

    private enum IngestOutcome {
        case survived, eaten, seedFailed
    }

    /// Seed the prior fact through the REAL distillation path (fresh in-memory
    /// store), then distill the revision: did it write, or did the semantic
    /// dedupe eat it? This measures the production mechanism end to end —
    /// including the title/EmbeddingText composition the raw pair cosine
    /// can't see.
    private static func ingestOutcome(
        _ pair: ContradictionEvalFixtures.Pair,
        embedder: MLXEmbeddingService
    ) async throws -> IngestOutcome {
        let store = try KnowledgeStore() // in-memory, discarded per pair
        let ingester = DocumentIngester(store: store, embedder: embedder)
        func coordinator(_ fact: String) -> MemoryDistillationCoordinator {
            MemoryDistillationCoordinator(
                distiller: ScriptedDistiller(facts: [DistilledFact(text: fact)]),
                ingester: ingester,
                store: store,
                embedder: embedder
            )
        }
        let turns = [ChatTurn(role: .user, text: pair.revision)]
        guard try await coordinator(pair.prior).distillAndStore(turns: turns) == 1 else {
            return .seedFailed
        }
        let written = try await coordinator(pair.revision).distillAndStore(turns: turns)
        return written == 1 ? .survived : .eaten
    }
}

/// Returns a fixed fact list, ignoring the transcript — the probe scripts the
/// distiller's OUTPUT so it measures the dedupe/ingest half in isolation.
private struct ScriptedDistiller: MemoryDistilling {
    let facts: [DistilledFact]

    func distill(turns _: [ChatTurn]) async throws -> [DistilledFact] {
        facts
    }
}
