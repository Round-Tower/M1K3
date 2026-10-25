//
//  ChatCurveStage.swift
//  M1K3App
//
//  THE CHAT-CURVE MEASUREMENT (M1K3_SELFTEST_CHATCURVE=1, "lil", "big" or a model id).
//
//  Drives AgentRAGResponder.answerStreaming(question, history:) with the fixed twenty-message
//  script (ChatCurveScript), accumulating [ChatTurn] as the app does, on one MLX brain (Lil by
//  default) with the production stub tool palette. Per message it reports the rendered prompt
//  length, the tool session's `reuse: X/Y`, the generation's `prompt=…tok prefill=…ms`, and the
//  process's peak RSS; the slope per message is the curve. The first step of the Qwen3.5
//  cross-turn checkpoint decision (docs/GEMMA_1_1_PLAN.md): measure before building.
//
//  The two figures are read off the app's own `.notice` log lines via OSLogStore (the parsing is
//  TDD'd in M1K3Eval's ChatCurveTests), so no inference code changes. Report: <M1K3_SELFTEST_OUT>.json,
//  or fenced on the stream with M1K3_SELFTEST_OUT=-. Needs the live app quit (two MLX processes crawl).
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.7 (app glue over TDD'd parts;
//  verify-by-launch owed: the OSLogStore read in a sandboxed build is untested until run).
//  Prior: Unknown (new file; shaped after MemBlockProbeStage).
//  Review: Kev + claude-fable-5.1, 2026-10-09 (#522 review fold) — a throw mid-script still reports the
//  samples collected so far. Follow-up: the 1 s log-flush sleep is a fixed wait; poll for the generation
//  line with a cap if a slow turn ever reads nil.
//  Review: Kev + claude-fable-5.1, 2026-10-10 (#530) — the first Big run's prefill column was the
//  running sum since launch (3071, 6294, 9891…): OSLogStore's position(date:) was trusted alone. Each
//  turn is now windowed by date and by the `chatcurve` provider label, and the store is polled (≤ 5 s)
//  for the turn's generation line instead of the fixed 1 s sleep. Re-run owed before the slope is read.
//  Review: Kev + claude-fable-5.1, 2026-10-25 — the curve could not see its own subject: the generate's
//  `prompt=` is one token in checkpoint mode and the extend was untimed (the 10-10 Lil run read
//  "prefilled=21tok"), and the ttft label is the PATH, not the provider name. Now: the reuse line's
//  `extend=`, MLX's own peak per message, the turn-label set, a `_ROUTER=dispatch` arm so the curve
//  can run the Mac's plain route, twenty messages, and the log read shared with ChatEvalStage
//  (MetricLogReader). Re-run owed on Lil and Big, Release. Confidence 0.75.
//

import Darwin
import Foundation
import M1K3Chat
import M1K3Eval
import M1K3Inference
import M1K3Knowledge
import M1K3MLX

enum ChatCurveStage {
    /// "1" is Lil; "lil"/"big" name a tier; anything else is a model id.
    static var modelID: String? {
        guard let value = SelfTestEnv.value("M1K3_SELFTEST_CHATCURVE"), !value.isEmpty, value != "0" else { return nil }
        switch value {
        case "1", "lil": return BrainTier.lil.mlxModelID
        case "big": return BrainTier.big.mlxModelID
        default: return value
        }
    }

    static var isRequested: Bool {
        SelfTestEnv.value("M1K3_SELFTEST_CHATCURVE").map { !$0.isEmpty && $0 != "0" } ?? false
    }

    /// Peak resident set of this process in whole MB (`ru_maxrss` is BYTES on macOS).
    private static func peakRSSMB() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss) / 1_048_576
    }

    /// The provider's name. NOT the generation line's label: the ttft line names the path (`stream`,
    /// `toolTurnSession`, …), so the turn's lines are read through `ChatCurveLogParser.turnLabels`
    /// (2026-10-25 — filtering on this name read no generation at all).
    static let providerLabel = "chatcurve"

    /// `M1K3_SELFTEST_CHATCURVE_ROUTER=dispatch` puts the Mac's own router in front (every tier, group head
    /// and chains on, as `ToolRouterWiring.allTiersEnabled(whenUnset: true)` ships it), so a "chat" verdict
    /// takes the seeded PLAIN route — the path the Mac runs most, and one with no conversation tail at all.
    /// Unset or `off`: no router, every message takes the agent route (the 10-10 curve's shape).
    static var routerArm: String {
        switch SelfTestEnv.value("M1K3_SELFTEST_CHATCURVE_ROUTER") {
        case "dispatch": "dispatch"
        default: "off"
        }
    }

    static func run(emit: @escaping (String) -> Void) async {
        guard let modelID else {
            emit("✗ chatcurve: no model id for that value")
            return
        }
        emit("• chatcurve: \(modelID), \(ChatCurveScript.messages.count) scripted messages, router \(routerArm)…")
        // Outside the `do` so a throw mid-script keeps the samples already measured:
        // a partial curve is still a curve, and the run cost minutes of GPU.
        var samples: [ChatCurveSample] = []
        do {
            let provider = MLXBrainProvider(modelID: modelID, name: providerLabel)
            var plainRoute: (@Sendable () -> PlainTurnRoute?)?
            if routerArm == "dispatch" {
                let route = ToolRouterWiring.route(
                    provider: provider, enabled: true, dispatch: true, groupRouter: true, allTiers: true, chain: true
                )
                plainRoute = { route }
            }
            let responder = try AgentRAGResponder(
                store: KnowledgeStore(), embedder: MLXEmbeddingService(), provider: provider,
                toolsProvider: { ChatEvalStage.toolPalette }, maxIterations: 3,
                plainRouteProvider: plainRoute
            )
            var history: [ChatTurn] = []
            for (index, question) in ChatCurveScript.messages.enumerated() {
                let started = Date()
                // `mlx=` is THIS message's MLX peak, not a running high-water mark (review fold, 2026-10-25).
                MLXMemoryBudget.resetPeak()
                let (_, stream) = try await responder.answerStreaming(
                    question, history: history, onActivity: { _ in }
                )
                var answer = ""
                for await piece in stream {
                    answer = StreamFold.fold(current: answer, chunk: piece)
                }
                let cleaned = answer.trimmingCharacters(in: .whitespacesAndNewlines)
                history.append(ChatTurn(role: .user, text: question))
                history.append(ChatTurn(role: .assistant, text: cleaned))
                let folded = await MetricLogReader.foldTurn(since: started)
                let sample = ChatCurveSample(
                    index: index, question: question, renderedTokens: folded.reuse?.total,
                    reusedTokens: folded.reuse?.reused, promptTokens: folded.promptTokens,
                    prefillMS: folded.prefillMS, generations: folded.generations,
                    peakRSSMB: peakRSSMB(), answerChars: cleaned.count,
                    extendMS: folded.extendMS, mlxPeakMB: MLXMemoryBudget.peakMB()
                )
                samples.append(sample)
                emit("chatcurve #\(index + 1) done (\(cleaned.count) chars)")
            }
            try report(ChatCurveReport(modelID: modelID, samples: samples), emit: emit)
        } catch {
            emit("✗ chatcurve: \(error)")
            guard !samples.isEmpty else { return }
            emit("• chatcurve: partial report, \(samples.count)/\(ChatCurveScript.messages.count) messages")
            do {
                try report(ChatCurveReport(modelID: modelID, samples: samples), emit: emit)
            } catch {
                emit("✗ chatcurve: partial report failed: \(error)")
            }
        }
    }

    /// The transcript table, then the JSON: fenced on stdout (`M1K3_SELFTEST_OUT=-`), else `<OUT>.json`.
    private static func report(_ report: ChatCurveReport, emit: (String) -> Void) throws {
        emit(report.rendered)
        let json = try ChatCurveReport.json(report)
        if SelfTest.writesToStandardOutput {
            emit(ChatCurveReport.fenced(json))
        } else {
            let url = URL(fileURLWithPath: SelfTest.outputPath + ".json")
            try json.write(to: url)
            emit("• chatcurve json → \(url.lastPathComponent)")
        }
        if report.samples.allSatisfy({ $0.renderedTokens == nil }) {
            emit("  – chatcurve: no reuse/prefill lines were readable (OSLogStore empty?)"
                + " — figures are nil, not zero")
        }
    }
}
