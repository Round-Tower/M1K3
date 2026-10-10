//
//  MemGraphEvalStage.swift
//  M1K3App
//
//  The on-device half of the temporal-memory-graph integration eval. The PURE
//  harness lives in M1K3Memory (MemoryGraphEval + MemoryGraphFixtures, unit-
//  tested off-device against the keyword-only HashingEmbeddingService); this
//  stage runs the SAME scenario from INSIDE the .app bundle against the REAL MLX
//  embedder — the only place the `semantic` probes mean anything. A paraphrase
//  like "Who is Kev's sibling?" shares no surface tokens with "Kev's sister is
//  Aoife", so the hashing fake scores zero on it by design; a real embedder must
//  bridge the meaning gap. That gap is the difference between "the SQL is right"
//  and "the memory is useful", and it can only be proven here. Same harness
//  shape as CHATEVAL/MEMEVAL/ABSEP.
//
//      M1K3_SELFTEST=1 M1K3_SELFTEST_MEMGRAPH=1 M1K3.app/Contents/MacOS/M1K3
//      # report streams to M1K3_SELFTEST_OUT (default /tmp/m1k3_selftest.log),
//      # plus M1K3_SELFTEST_MEMGRAPH_OUT if set.
//
//  The embedder is constructed the SAME way ChatEvalStage's grounded path does
//  (bare `MLXEmbeddingService()` = the production default, EmbeddingGemma 2 since 2026-10-10) so this measures
//  the production retrieval stack, not a test double.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-16, Confidence 0.8 (the runner is
//  verify-by-launch — its logic core is the unit-tested MemoryGraphEval and the
//  production MLXEmbeddingService; the wiring itself can only be confirmed
//  on-device, where the semantic probes finally have a real embedder to satisfy
//  them). Prior: ChatEvalStage (Kev + claude-opus-4-8).
//  Review: Kev + claude-fable-5.1, 2026-10-10 (one embedder: EmbeddingGemma 2) — comment only — the bare `MLXEmbeddingService()` default is now EmbeddingGemma 2.

import Foundation
import M1K3Memory
import M1K3MLX

enum MemGraphEvalStage {
    static var isRequested: Bool {
        SelfTestEnv.value("M1K3_SELFTEST_MEMGRAPH") == "1"
    }

    /// Run the life-graph scenario against the real MLX embedder, demanding the
    /// semantic probes (the whole reason this runs on-device), and stream the
    /// summary table. Each line goes through `emit` (the standard OUT file) and,
    /// if set, is also appended to M1K3_SELFTEST_MEMGRAPH_OUT — matching how the
    /// other stages let a focused run capture its own log.
    static func run(emit: @escaping (String) -> Void) async {
        let dedicatedOut = SelfTestEnv.value("M1K3_SELFTEST_MEMGRAPH_OUT")
        if let dedicatedOut { try? Data().write(to: URL(fileURLWithPath: dedicatedOut)) }
        func line(_ text: String) {
            emit(text)
            guard let dedicatedOut else { return }
            let data = Data((text + "\n").utf8)
            if let handle = FileHandle(forWritingAtPath: dedicatedOut) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                try? data.write(to: URL(fileURLWithPath: dedicatedOut))
            }
        }

        line("• memgraph: running life-graph scenario against MLX embedder (semantic probes ON)…")
        do {
            let embedder = MLXEmbeddingService() // the production default — same as the grounded RAG path
            let report = try await MemoryGraphEval.run(
                MemoryGraphFixtures.lifeGraph,
                embedder: embedder,
                includeSemantic: true
            )
            line(report.summary())
            line(report.allPassed ? "✓ memgraph: all probes passed" : "✗ memgraph: \(report.failed) probe(s) failed")
        } catch {
            line("✗ memgraph: \(error)")
        }
    }
}
