//
//  ChatCurveStage.swift
//  M1K3App
//
//  THE CHAT-CURVE MEASUREMENT (M1K3_SELFTEST_CHATCURVE=1, "lil", "big" or a model id).
//
//  Drives AgentRAGResponder.answerStreaming(question, history:) with the fixed eight-message
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
//  Prior: none (new file); shaped after MemBlockProbeStage.
//

import Darwin
import Foundation
import M1K3Chat
import M1K3Eval
import M1K3Inference
import M1K3Knowledge
import M1K3MLX
import OSLog

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

    /// The app's metric lines since `date`: the tool session's reuse line (category mlx-load)
    /// and the generation line (ttft), oldest first.
    private static func metricLines(since date: Date) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries(at: store.position(date: date))
        else { return [] }
        return entries.compactMap { $0 as? OSLogEntryLog }
            .filter { $0.subsystem == "app.m1k3" && ($0.category == "ttft" || $0.category == "mlx-load") }
            .map(\.composedMessage)
    }

    static func run(emit: @escaping (String) -> Void) async {
        guard let modelID else {
            emit("✗ chatcurve: no model id for that value")
            return
        }
        emit("• chatcurve: \(modelID), \(ChatCurveScript.messages.count) scripted messages…")
        do {
            let provider = MLXBrainProvider(modelID: modelID, name: "chatcurve")
            let responder = try AgentRAGResponder(
                store: KnowledgeStore(), embedder: MLXEmbeddingService(), provider: provider,
                toolsProvider: { ChatEvalStage.toolPalette }, maxIterations: 3
            )
            var history: [ChatTurn] = []
            var samples: [ChatCurveSample] = []
            for (index, question) in ChatCurveScript.messages.enumerated() {
                let started = Date()
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
                // Log entries land in the store a beat after the call.
                try? await Task.sleep(for: .seconds(1))
                let folded = ChatCurveLogParser.fold(metricLines(since: started))
                let sample = ChatCurveSample(
                    index: index, question: question, renderedTokens: folded.reuse?.total,
                    reusedTokens: folded.reuse?.reused, promptTokens: folded.promptTokens,
                    prefillMS: folded.prefillMS, generations: folded.generations,
                    peakRSSMB: peakRSSMB(), answerChars: cleaned.count
                )
                samples.append(sample)
                emit("chatcurve #\(index + 1) done (\(cleaned.count) chars)")
            }
            let report = ChatCurveReport(modelID: modelID, samples: samples)
            emit(report.rendered)
            let json = try ChatCurveReport.json(report)
            if SelfTest.writesToStandardOutput {
                emit(ChatCurveReport.fenced(json))
            } else {
                let url = URL(fileURLWithPath: SelfTest.outputPath + ".json")
                try json.write(to: url)
                emit("• chatcurve json → \(url.lastPathComponent)")
            }
            if samples.allSatisfy({ $0.renderedTokens == nil }) {
                emit("  – chatcurve: no reuse/prefill lines were readable (OSLogStore empty?) — figures are nil, not zero")
            }
        } catch {
            emit("✗ chatcurve: \(error)")
        }
    }
}
