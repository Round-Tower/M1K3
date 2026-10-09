//
//  ChatCurveTests.swift
//  M1K3EvalTests
//
//  Red-first for the chat-curve instrument's pure half: the script, the log-line
//  parsers, and the curve summary. The stage that drives the real brain is
//  verify-by-launch (SelfTest ChatCurveStage); these pin what it reads and how.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.8 (pure arithmetic and
//  parsing; the on-device curve is the named verify-owed). Prior: none (new file).
//

import Foundation
@testable import M1K3Eval
import Testing

struct ChatCurveTests {
    @Test("the script is eight short, distinct, non-empty messages")
    func scriptShape() {
        let script = ChatCurveScript.messages
        #expect(script.count == 8)
        #expect(Set(script).count == 8)
        #expect(script.allSatisfy { !$0.isEmpty && $0.count <= 120 })
    }

    @Test("the reuse line parses reused and total")
    func parsesReuse() {
        let line = "toolTurnSession reuse: 2301/2650 tok from cache, prefilling 349, seed=persona"
        #expect(ChatCurveLogParser.reuse(in: line) == ChatCurveReuse(reused: 2301, total: 2650))
    }

    @Test("a vetoed reuse line still parses")
    func parsesVetoedReuse() {
        let line = "toolTurnSession reuse: 0/3232 tok from cache, prefilling 3232, seed=none (VETOED — cache not trimmable)"
        #expect(ChatCurveLogParser.reuse(in: line) == ChatCurveReuse(reused: 0, total: 3232))
    }

    @Test("an unrelated line yields nil, never zero")
    func unrelatedIsNil() {
        #expect(ChatCurveLogParser.reuse(in: "something else 3/4") == nil)
        #expect(ChatCurveLogParser.generation(in: "no metrics here") == nil)
    }

    @Test("the ttft line parses prompt tokens and prefill ms")
    func parsesGeneration() {
        let line = "toolTurn [mlx-community/Qwen3.5-4B]: prompt=349tok prefill=812ms decode=64tok @31tok/s"
        #expect(ChatCurveLogParser.generation(in: line) == ChatCurveGeneration(promptTokens: 349, prefillMS: 812))
    }

    @Test("folding a turn's lines: last reuse wins, generations sum")
    func foldsTurn() {
        let lines = [
            "toolTurnSession reuse: 100/400 tok from cache, prefilling 300, seed=persona",
            "x [m]: prompt=300tok prefill=500ms decode=10tok @30tok/s",
            "toolTurnSession reuse: 380/450 tok from cache, prefilling 70, seed=tail",
            "x [m]: prompt=70tok prefill=120ms decode=20tok @30tok/s",
        ]
        let folded = ChatCurveLogParser.fold(lines)
        #expect(folded.reuse == ChatCurveReuse(reused: 380, total: 450))
        #expect(folded.generations == 2)
        #expect(folded.promptTokens == 370)
        #expect(folded.prefillMS == 620)
    }

    @Test("a turn with no metric lines folds to nils, not zeros")
    func foldsEmpty() {
        let folded = ChatCurveLogParser.fold(["noise"])
        #expect(folded.reuse == nil)
        #expect(folded.promptTokens == nil)
        #expect(folded.prefillMS == nil)
        #expect(folded.generations == 0)
    }

    private func sample(_ i: Int, total: Int?, prefill: Int?) -> ChatCurveSample {
        ChatCurveSample(
            index: i, question: "q\(i)", renderedTokens: total, reusedTokens: nil,
            promptTokens: nil, prefillMS: prefill, generations: 1, peakRSSMB: 1000 + i, answerChars: 10
        )
    }

    @Test("slope is least-squares per message")
    func slope() {
        let samples = (0 ..< 4).map { sample($0, total: 1000 + 100 * $0, prefill: 200 + 50 * $0) }
        let summary = ChatCurveSummary(samples: samples)
        #expect(summary.renderedTokensPerMessage == 100)
        #expect(summary.prefillMSPerMessage == 50)
    }

    @Test("slope skips unmeasured samples and is nil under two points")
    func slopeSparse() {
        let one = ChatCurveSummary(samples: [sample(0, total: 10, prefill: 5)])
        #expect(one.renderedTokensPerMessage == nil)
        let gap = ChatCurveSummary(samples: [
            sample(0, total: 100, prefill: nil), sample(1, total: nil, prefill: nil), sample(2, total: 300, prefill: nil),
        ])
        #expect(gap.renderedTokensPerMessage == 100)
        #expect(gap.prefillMSPerMessage == nil)
    }

    @Test("reuse fraction of the last sample")
    func reuseFraction() {
        let last = ChatCurveSample(
            index: 7, question: "q", renderedTokens: 1000, reusedTokens: 900,
            promptTokens: 100, prefillMS: 90, generations: 1, peakRSSMB: 1, answerChars: 1
        )
        #expect(last.reuseFraction == 0.9)
        #expect(sample(0, total: nil, prefill: 1).reuseFraction == nil)
    }

    @Test("the report JSON round-trips with sorted keys")
    func jsonRoundTrip() throws {
        let report = ChatCurveReport(
            modelID: "m", samples: [sample(0, total: 1, prefill: 2), sample(1, total: 3, prefill: 4)]
        )
        let data = try ChatCurveReport.json(report)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.firstRange(of: "\"modelID\"") != nil)
        let back = try JSONDecoder().decode(ChatCurveReport.self, from: data)
        #expect(back.samples.count == 2)
        #expect(back.summary.renderedTokensPerMessage == 2)
    }

    @Test("the rendered table has one row per message plus the slope line")
    func rendered() {
        let report = ChatCurveReport(modelID: "m", samples: (0 ..< 3).map { sample($0, total: 100 * $0, prefill: 10 * $0) })
        let lines = report.rendered.split(separator: "\n")
        #expect(lines.contains { $0.contains("slope") })
        #expect(lines.filter { $0.hasPrefix("chatcurve #") }.count == 3)
    }

    @Test("the fence wraps the JSON on its own lines")
    func fence() {
        let text = ChatCurveReport.fenced(Data("{}".utf8))
        #expect(text == "-----BEGIN CHATCURVE JSON-----\n{}\n-----END CHATCURVE JSON-----")
    }
}
