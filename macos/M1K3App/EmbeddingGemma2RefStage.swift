//
//  EmbeddingGemma2RefStage.swift
//  M1K3App
//
//  The numeric proof of the EmbeddingGemma 2 port (GEMMA_1_1_PLAN Stream C,
//  slice 2): inside the app (the metallib wall), tokenise and embed every case
//  of Tests/M1K3MLXTests/Fixtures/embeddinggemma2-reference.json through the
//  Swift text core and compare with mlx-vlm's ids and vectors — at 768, at the
//  MRL-512 width the store uses, and through the production `embed` /
//  `embedQuery` composition. The fixture arrives on STDIN: the sandbox cannot
//  read the repo, and the direct-exec route inherits the pipe.
//
//      cat Tests/M1K3MLXTests/Fixtures/embeddinggemma2-reference.json \
//        | M1K3_SELFTEST=1 M1K3_SELFTEST_EG2REF=1 M1K3_SELFTEST_OUT=- \
//          <Debug M1K3.app>/Contents/MacOS/M1K3
//
//  `M1K3_SELFTEST_EG2REF=1` (or true/yes) loads the Hub preset (downloads on
//  first use); any other value is a model directory (reachable only outside the sandbox),
//  routed to the port explicitly whatever it is named.
//  Pass: every id sequence equal, every cosine ≥ 0.999 (mlx-community's own
//  validation of the conversion sits at 0.9998 against fp32), and the
//  fixture's relevance checks hold with OUR vectors.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-10, Confidence 0.8, Prior: none
//  (new file). Fold (review): a terminal on stdin is refused instead of hanging
//  the SelfTest; one load at 768 with the 512 column derived by the same
//  `MatryoshkaTruncation` the service uses; ranking pairs come from the
//  fixture; the RSS figure is labelled as the whole process's.
//  Review: Kev + claude-fable-5.1, 2026-10-10 (#545 bot pass) — true/yes count as the preset.
//  Review: Kev + claude-fable-5.1, 2026-10-10 (#545 pass 2) — a NaN cosine can no longer read as PASS.

import Foundation
import M1K3Knowledge
import M1K3MLX
import MLXLMCommon

enum EmbeddingGemma2RefStage {
    static let threshold: Float = 0.999
    static let storeWidth = 512

    static var isRequested: Bool {
        SelfTestEnv.value("M1K3_SELFTEST_EG2REF").map { !$0.isEmpty && $0 != "0" } ?? false
    }

    struct Reference: Decodable {
        struct Case: Decodable {
            let id: String
            let role: String
            let text: String
            let prompted: String
            let inputIDs: [Int]
            let embedding768: [Float]
            let embedding512: [Float]
        }

        struct Ranking: Decodable {
            let query: String
            let relevant: String
            let irrelevant: String
        }

        let model: String
        let modelRevision: String
        let cases: [Case]
        let rankingChecks: [Ranking]
    }

    /// One case's three comparisons against the reference.
    struct CaseResult {
        let tokensOK: Bool
        let cos768: Float
        let cos512: Float
        let pipeline: Float
        let vector512: [Float]
        let embedMillis: Double
    }

    static func run(emit: @escaping (String) -> Void) async {
        let value = SelfTestEnv.value("M1K3_SELFTEST_EG2REF") ?? "1"
        let configuration = ["1", "true", "yes"].contains(value.lowercased())
            ? MLXEmbeddingService.embeddingGemma2
            : ModelConfiguration(directory: URL(fileURLWithPath: value))
        guard isatty(STDIN_FILENO) == 0 else {
            emit("✗ eg2ref: stdin is a terminal — pipe the reference fixture in")
            return
        }
        emit("• eg2ref: \(configuration.name) — reading the reference fixture from stdin…")
        let reference: Reference
        do {
            reference = try JSONDecoder().decode(Reference.self, from: FileHandle.standardInput.readDataToEndOfFile())
        } catch {
            emit("✗ eg2ref: no fixture on stdin (\(error))")
            return
        }
        let revision = String(reference.modelRevision.prefix(8))
        emit("• eg2ref: \(reference.cases.count) cases from \(reference.model)@\(revision)")

        let service = MLXEmbeddingService(configuration: configuration, dimension: 768, prompting: .embeddingGemma2)
        let clock = ContinuousClock()
        do {
            let loadStart = clock.now
            _ = try await service.tokenize("warm")
            emit(String(format: "eg2ref load: %.1f s", seconds(clock.now - loadStart)))

            var results: [String: CaseResult] = [:]
            for item in reference.cases {
                let result = try await check(item, with: service, clock: clock)
                results[item.id] = result
                let tokenNote = result.tokensOK ? "ok" : "MISMATCH"
                emit(String(
                    format: "eg2ref %@ tokens %@ (%d) cos768 %.5f cos512 %.5f pipeline %.5f",
                    item.id, tokenNote, item.inputIDs.count, result.cos768, result.cos512, result.pipeline
                ))
            }
            let rankingOK = rank(reference.rankingChecks, results: results, emit: emit)
            emit(summary(results: results, rankingOK: rankingOK, total: reference.cases.count))
        } catch {
            emit("✗ eg2ref: \(error)")
        }
    }

    private static func check(
        _ item: Reference.Case, with service: MLXEmbeddingService, clock: ContinuousClock
    ) async throws -> CaseResult {
        let ids = try await service.tokenize(item.prompted)
        let embedStart = clock.now
        let v768 = try await service.embedPrompted(item.prompted)
        let millis = seconds(clock.now - embedStart) * 1000
        let v512 = try MatryoshkaTruncation.truncateValidated(v768, to: storeWidth)
        // The production composition: `embed` prefixes a document, `embedQuery` a query.
        let composed = item.role == "query"
            ? try await service.embedQuery(item.text)
            : try await service.embed(item.text)
        let pipeline = try MatryoshkaTruncation.truncateValidated(composed, to: storeWidth)
        return CaseResult(
            tokensOK: ids == item.inputIDs,
            cos768: VectorMath.cosineSimilarity(v768, item.embedding768),
            cos512: VectorMath.cosineSimilarity(v512, item.embedding512),
            pipeline: VectorMath.cosineSimilarity(pipeline, item.embedding512),
            vector512: v512,
            embedMillis: millis
        )
    }

    /// The fixture's relevance pairs, scored with OUR vectors; a missing id fails.
    private static func rank(
        _ checks: [Reference.Ranking], results: [String: CaseResult], emit: (String) -> Void
    ) -> Bool {
        var allOK = !checks.isEmpty
        for check in checks {
            guard let q = results[check.query]?.vector512, let d = results[check.relevant]?.vector512,
                  let off = results[check.irrelevant]?.vector512
            else {
                emit("eg2ref rank \(check.query): a fixture id is missing — FAIL")
                allOK = false
                continue
            }
            let own = VectorMath.cosineSimilarity(q, d)
            let other = VectorMath.cosineSimilarity(q, off)
            let ok = own > other
            allOK = allOK && ok
            emit(String(
                format: "eg2ref rank %@→%@ %.3f vs %@ %.3f %@",
                check.query, check.relevant, own, check.irrelevant, other, ok ? "ok" : "WRONG"
            ))
        }
        return allOK
    }

    private static func summary(results: [String: CaseResult], rankingOK: Bool, total: Int) -> String {
        let values = Array(results.values)
        let tokenMatches = values.filter(\.tokensOK).count
        let minCos768 = values.map(\.cos768).min() ?? 0
        let minCos512 = values.map(\.cos512).min() ?? 0
        let minPipeline = values.map(\.pipeline).min() ?? 0
        let sorted = values.map(\.embedMillis).sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        // `min()` skips a NaN that isn't first, so finiteness is required explicitly.
        let finite = values.allSatisfy { $0.cos768.isFinite && $0.cos512.isFinite && $0.pipeline.isFinite }
        let pass = tokenMatches == total && total > 0 && finite
            && minCos768 >= threshold && minCos512 >= threshold && minPipeline >= threshold && rankingOK
        return String(
            format: "eg2ref summary: tokens %d/%d · min cos768 %.5f · min cos512 %.5f · min pipeline %.5f · "
                + "ranking %@ · embed median %.0f ms · process peak RSS %d MB (earlier stages included) · %@",
            tokenMatches, total, minCos768, minCos512, minPipeline,
            rankingOK ? "ok" : "WRONG", median, peakRSSMB(), pass ? "PASS" : "FAIL"
        )
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// Peak resident set of this process in whole MB (`ru_maxrss` is BYTES on macOS).
    private static func peakRSSMB() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss) / 1_048_576
    }
}
