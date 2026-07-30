//
//  MemBlockProbeStage.swift
//  M1K3App
//
//  Tier-1 dream-cycle verification (scratch/dream-cycle/SPEC.md): does the
//  dated memory block actually buy read-time contradiction resolution on the
//  live path, and does it disturb either brain's register?
//
//  Seeds an in-memory store (REAL MLX embedder, real EmbeddingText
//  composition) with a dated contradiction — "Kev lives in Dublin." learned
//  ~400 days ago vs "Kev lives in Ardmore." learned 2 days ago — plus a
//  neutral fact, then asks the production AgentRAGResponder the question the
//  pair contradicts on. The dated block is the ONLY recency signal available;
//  a correct answer must prefer Ardmore.
//
//  Scope honesty: this probes the DATED build only. The no-memory prompt is
//  byte-pinned unchanged by unit tests (MemoryGroundingTests), so the block
//  is the whole changed surface, and this stage watches it on both brains.
//  A strict same-binary undated control arm would need the private prompt
//  renderer exposed — deliberately not widened for an eval.
//
//      M1K3_SELFTEST=1 M1K3_SELFTEST_MEMBLOCK=1  (via .m1k3-selftest.json)
//      M1K3_SELFTEST_MEMBLOCK_MODELS=id,id       (optional override; default
//                                                 lil + big)
//
//  Signed: Kev + claude-fable-5, 2026-07-30, Confidence 0.8 (verify-by-launch
//  arm over unit-tested parts, same doctrine as the other stages). Prior:
//  MemStatStage (Kev + claude-fable-5).
//

import Foundation
import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import M1K3MLX

enum MemBlockProbeStage {
    static var isRequested: Bool {
        SelfTestEnv.value("M1K3_SELFTEST_MEMBLOCK") == "1"
    }

    private struct SeededFact {
        let text: String
        let daysAgo: Double
    }

    private static let facts: [SeededFact] = [
        .init(text: "Kev lives in Dublin.", daysAgo: 400),
        .init(text: "Kev lives in Ardmore.", daysAgo: 2),
        .init(text: "Kev's dog is a collie named Bran.", daysAgo: 30),
    ]

    private static let questions = [
        "Where do I live?",
        "Tell me about my dog.",
    ]

    static func run(emit: @escaping (String) -> Void) async {
        emit("• memblock: Tier-1 dated-block live-path probe…")
        let models = SelfTestEnv.value("M1K3_SELFTEST_MEMBLOCK_MODELS")
            .map { $0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) } }
            ?? [BrainTier.lil, BrainTier.big].compactMap(\.mlxModelID)
        do {
            let embedder = MLXEmbeddingService()
            let store = try await seededStore(embedder: embedder)
            for modelID in models {
                emit("• memblock brain \(modelID)…")
                let provider = MLXGemmaProvider(modelID: modelID, name: "memblock")
                let responder = AgentRAGResponder(
                    store: store, embedder: embedder, provider: provider,
                    toolsProvider: { [] }, maxIterations: 3
                )
                for question in questions {
                    let clock = ContinuousClock()
                    let start = clock.now
                    let (_, stream) = try await responder.answerStreaming(
                        question, history: [], onActivity: { _ in }
                    )
                    var answer = ""
                    for await piece in stream {
                        answer += piece
                    }
                    let elapsed = clock.now - start
                    let seconds = Double(elapsed.components.seconds)
                        + Double(elapsed.components.attoseconds) / 1e18
                    let cleaned = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                    emit(String(format: "memblock [%@] %.1fs Q: %@", modelID, seconds, question))
                    emit("memblock A: \(cleaned.prefix(400))")
                }
            }
            emit("✓ memblock: done — eyeball gate: the location answer must say "
                + "Ardmore (recent) not Dublin (stale), with no register damage")
        } catch {
            emit("✗ memblock: \(error)")
        }
    }

    /// Real composition, controlled dates: items are indexed directly (not via
    /// DocumentIngester, which stamps createdAt = now) with vectors embedded
    /// through the SAME EmbeddingText.forChunk the production ingest uses.
    private static func seededStore(embedder: MLXEmbeddingService) async throws -> KnowledgeStore {
        let store = try KnowledgeStore()
        for fact in facts {
            let item = KnowledgeItem(
                kind: .memory, title: fact.text, source: .distilled,
                createdAt: Date().addingTimeInterval(-fact.daysAgo * 86400)
            )
            let chunk = KnowledgeChunk(itemID: item.id, ordinal: 0, heading: nil, content: fact.text)
            let vector = try await embedder.embed(
                EmbeddingText.forChunk(title: fact.text, content: fact.text)
            )
            try store.index(item: item, chunks: [chunk], embeddings: [vector])
        }
        return store
    }
}
