//
//  CallSummaryLiveEvalTests.swift
//  M1K3CallsTests
//
//  The live half of CallSummaryEval: the real SummarizationPipeline over the
//  synthetic calls in CallSummaryFixtures, scored by CallSummaryScorer. Mini
//  (AFM) is the only brain `swift test` can run (MLX needs the .app bundle),
//  so it serves BOTH tiers here; in the app the deep tier is the active brain.
//  OFF unless `M1K3_CALLS_EVAL=1`, never in CI (no Apple Intelligence there):
//
//      M1K3_CALLS_EVAL=1 M1K3_CALLS_EVAL_ARM=neutral|persona \
//        M1K3_CALLS_EVAL_OUT=/path/run.json swift test --filter CallSummaryLiveEvalTests
//
//  `neutral` (the default) is what the app ships since 2026-09-26: the AFM
//  session carries `SummarizationPipeline.neutralInstructions`. `persona` is
//  the session before it, kept as the A/B arm. No leak check runs here, so a
//  recital shows up as a trap-free but polluted overview in the JSON.
//
//  It reports, it doesn't gate: the numbers are the baseline a prompt or
//  chunking change has to beat. Pace matters (memory: AFM daemon falls over
//  under rapid turns), so cases run serially.
//
//  Signed: Kev + claude-opus-5-5, 2026-09-26, Confidence 0.8. Prior: MiniLiveEvalTests.
//

import Foundation
import M1K3Calls
import M1K3Eval
import M1K3Inference
import Testing

private let evalEnvironment = ProcessInfo.processInfo.environment

@Suite(.enabled(if: evalEnvironment["M1K3_CALLS_EVAL"] == "1"), .serialized)
struct CallSummaryLiveEvalTests {
    private struct CaseReport: Codable {
        let score: CallSummaryScore
        let recitedPrompt: Bool
        let passed: Bool
        let output: CallSummaryOutput
        let transcriptCharacters: Int
        let seconds: Double
    }

    @Test("Mini summarises the synthetic calls")
    func miniBaseline() async throws {
        let arm = evalEnvironment["M1K3_CALLS_EVAL_ARM"] ?? "neutral"
        let afm = arm == "persona"
            ? AppleFoundationModelsProvider()
            : AppleFoundationModelsProvider(instructions: { SummarizationPipeline.neutralInstructions })
        try #require(afm.isAvailable, "Apple Intelligence isn't available in this process")
        let pipeline = SummarizationPipeline(quickProvider: afm, deepProvider: afm)

        var reports: [CaseReport] = []
        for fixture in CallSummaryFixtures.all {
            let clock = ContinuousClock.now
            let out = await pipeline.summarize(transcript: fixture.transcript)
            let seconds = Double((ContinuousClock.now - clock).components.seconds)
            let output = CallSummaryOutput(
                quick: out.quick?.overview,
                overview: out.full?.overview,
                keyPoints: out.full?.keyPoints ?? [],
                actionItems: out.full?.actionItems ?? []
            )
            let score = CallSummaryScorer.score(output, against: fixture)
            reports.append(CaseReport(
                score: score,
                recitedPrompt: [output.quick, output.overview].compactMap { $0 }
                    .contains { $0.contains("ABSOLUTE RULES") || $0.contains("Today's date is") },
                passed: score.passed, output: output,
                transcriptCharacters: fixture.transcript.count, seconds: seconds
            ))
            print("""
            [calls-eval] \(fixture.id): \(score.passed ? "PASS" : "FAIL") \
            quick=\(score.quickPresent) deep=\(score.deepPresent) \
            facts=\(score.factRecall) actions=\(score.actionRecall) \
            traps=\(score.trapsHit) invented=\(score.inventedActions) \
            recited=\(reports.last?.recitedPrompt ?? false) \(seconds)s
            """)
        }
        let passed = reports.count { $0.passed }
        print("[calls-eval] mini (\(arm)): \(passed)/\(reports.count) passed")

        if let path = evalEnvironment["M1K3_CALLS_EVAL_OUT"] {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(reports).write(to: URL(fileURLWithPath: path))
        }
    }
}
