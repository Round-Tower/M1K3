//
//  ChatCurveTests.swift
//  M1K3EvalTests
//
//  Red-first for the chat-curve instrument's pure half: the script, the log-line
//  parsers, and the curve summary. The stage that drives the real brain is
//  verify-by-launch (SelfTest ChatCurveStage); these pin what it reads and how.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.8 (pure arithmetic and
//  parsing; the on-device curve is the named verify-owed). Prior: Unknown (new file).
//

import Foundation
@testable import M1K3Eval
import Testing

struct ChatCurveTests {
    @Test("the script is thirty short, distinct, non-empty messages")
    func scriptShape() {
        // Twenty, not eight (2026-10-25): HistoryWindow keeps 16 turns (8 exchanges), so from about
        // message 10 the oldest line drops every turn and the shared prefix collapses. An 8-message
        // curve cannot see that cliff; the cross-turn reuse decision needs the far side of it.
        let script = ChatCurveScript.messages
        #expect(script.count == 30)
        #expect(Set(script).count == 30)
        #expect(script.allSatisfy { !$0.isEmpty && $0.count <= 120 })
    }

    @Test("the reuse line parses reused and total")
    func parsesReuse() {
        let line = "toolTurnSession reuse: 2301/2650 tok from cache, prefilling 349, seed=persona"
        #expect(ChatCurveLogParser.reuse(in: line) == ChatCurveReuse(reused: 2301, total: 2650))
    }

    @Test("the reuse line's extend figure parses when present and is nil on an older line")
    func parsesExtend() {
        // The checkpoint extend (prefillExactly) was untimed until 2026-10-25: the ttft line reported the
        // one-token generate, so the 10-10 curve read "prefilled=21tok" while ~800–2,400 tokens were
        // prefilled per message. The reuse line now carries it; a line without it still parses.
        let timed = "toolTurnSession reuse: 2467/3289 tok from cache, prefilling 822, seed=persona extend=2140ms"
        #expect(ChatCurveLogParser.reuse(in: timed) == ChatCurveReuse(reused: 2467, total: 3289, extendMS: 2140))
        let older = "toolTurnSession reuse: 2301/2650 tok from cache, prefilling 349, seed=persona"
        #expect(ChatCurveLogParser.reuse(in: older)?.extendMS == nil)
    }

    @Test("a vetoed reuse line still parses")
    func parsesVetoedReuse() {
        let line = "toolTurnSession reuse: 0/3232 tok from cache, prefilling 3232, seed=none"
            + " (VETOED — cache not trimmable: wrapped window or recurrent layer)"
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
        // Decode tokens and throughput ride the same line; the eval score folds them per trial.
        #expect(ChatCurveLogParser.generation(in: line)
            == ChatCurveGeneration(promptTokens: 349, prefillMS: 812, decodeTokens: 64, tokensPerSecond: 31))
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
        #expect(folded.extendMS == nil, "no send carried an extend figure")
        #expect(folded.decodeTokens == 30)
        // Throughput is total tokens over total decode time, not a mean of the per-line figures (a
        // 2-token send at 60 tok/s must not pull a 200-token send at 30 tok/s up to 45).
        #expect(abs((folded.tokensPerSecond ?? 0) - 30) < 0.01)
    }

    @Test("a line whose rate rounded to zero lends neither its seconds nor its tokens to the rate")
    func zeroRateLineStaysOutOfTheRate() {
        let lines = [
            "x [m]: prompt=1tok prefill=40ms decode=100tok @30tok/s",
            "x [m]: prompt=1tok prefill=40ms decode=3tok @0tok/s", // a slow decode, integer-truncated
        ]
        let folded = ChatCurveLogParser.fold(lines)
        #expect(folded.decodeTokens == 103, "the tokens were still decoded")
        #expect(abs((folded.tokensPerSecond ?? 0) - 30) < 0.01, "the rate reads over the timed lines only")
        #expect(ChatCurveLogParser.fold(["x [m]: prompt=1tok prefill=40ms decode=3tok @0tok/s"]).tokensPerSecond == nil)
    }

    @Test("the send-phase line is neither a reuse nor a generation line")
    func sendPhaseLineIsIgnored() {
        let line = "toolTurnSession send 2: wait=12ms render=340ms (3289 tok)"
        #expect(ChatCurveLogParser.reuse(in: line) == nil)
        #expect(ChatCurveLogParser.generation(in: line) == nil)
    }

    @Test("folding sums the extend figure over the turn's sends")
    func foldsExtend() throws {
        let lines = [
            "toolTurnSession reuse: 2467/3289 tok from cache, prefilling 822, seed=persona extend=2140ms",
            "x [m]: prompt=1tok prefill=40ms decode=100tok @30tok/s",
            "toolTurnSession reuse: 3300/3400 tok from cache, prefilling 100, seed=checkpoint extend=260ms",
            "x [m]: prompt=1tok prefill=38ms decode=50tok @60tok/s",
        ]
        let folded = ChatCurveLogParser.fold(lines)
        #expect(folded.extendMS == 2400)
        #expect(folded.decodeTokens == 150)
        // 100 tok in 3.33 s + 50 tok in 0.83 s = 150 tok in 4.17 s = 36 tok/s (a per-line mean would say 45).
        #expect(abs((folded.tokensPerSecond ?? 0) - 36) < 0.01)
        let figures = try #require(folded.figures(firstChunkMS: 2300))
        #expect(figures.extendMS == 2400 && figures.generations == 2 && figures.firstChunkMS == 2300)
        #expect(figures.totalPrefillMS == 2478)
        #expect(ChatCurveLogParser.fold(["noise"]).figures(firstChunkMS: 5) == nil, "nothing logged, no figures")
    }

    @Test("a turn's window keeps only entries dated at or after the turn started")
    func windowDropsEarlierTurns() {
        let t0 = Date(timeIntervalSinceReferenceDate: 1000)
        let entries = [
            ChatCurveLogEntry(
                date: t0.addingTimeInterval(-5),
                message: "chatcurve [m]: prompt=3071tok prefill=900ms decode=10tok @30tok/s"
            ),
            ChatCurveLogEntry(
                date: t0.addingTimeInterval(-1),
                message: "toolTurnSession reuse: 0/3071 tok from cache, prefilling 3071, seed=persona"
            ),
            ChatCurveLogEntry(
                date: t0,
                message: "toolTurnSession reuse: 3000/3223 tok from cache, prefilling 223, seed=tail"
            ),
            ChatCurveLogEntry(
                date: t0.addingTimeInterval(2),
                message: "chatcurve [m]: prompt=223tok prefill=80ms decode=10tok @30tok/s"
            ),
        ]
        let folded = ChatCurveLogParser.fold(ChatCurveLogParser.turnLines(entries, since: t0, label: "chatcurve"))
        // The 2026-10-10 run read 3071, 6294, 9891…: every message summed the generations since
        // launch. A per-message window reads this turn's 223, not the running total.
        #expect(folded.generations == 1)
        #expect(folded.promptTokens == 223)
        #expect(folded.reuse == ChatCurveReuse(reused: 3000, total: 3223))
    }

    @Test("another provider's generation in the window is not this turn's prefill")
    func windowKeepsOnlyTheLabelledProvider() {
        let t0 = Date(timeIntervalSinceReferenceDate: 2000)
        let entries = [
            ChatCurveLogEntry(
                date: t0.addingTimeInterval(1),
                message: "chatcurve [m]: prompt=200tok prefill=70ms decode=10tok @30tok/s"
            ),
            ChatCurveLogEntry(
                date: t0.addingTimeInterval(2),
                message: "title [m]: prompt=900tok prefill=400ms decode=5tok @30tok/s"
            ),
        ]
        let folded = ChatCurveLogParser.fold(ChatCurveLogParser.turnLines(entries, since: t0, label: "chatcurve"))
        #expect(folded.generations == 1)
        #expect(folded.promptTokens == 200)
        #expect(folded.prefillMS == 70)
    }

    @Test("the tool session's own generation lines belong to the turn too")
    func windowKeepsTheToolSessionsGenerations() {
        // The tool session logs as `toolTurnSession [model]`, not under the provider's name, so until
        // 2026-10-25 the curve counted only the synthesis generation: its decode tokens and tok/s were
        // missing from every tool turn. A background title or caption still carries its own label.
        let t0 = Date(timeIntervalSinceReferenceDate: 3000)
        let entries = [
            ChatCurveLogEntry(
                date: t0.addingTimeInterval(1),
                message: "toolTurnSession [m]: prompt=1tok prefill=40ms decode=120tok @30tok/s"
            ),
            ChatCurveLogEntry(
                date: t0.addingTimeInterval(2),
                message: "chatcurve [m]: prompt=200tok prefill=70ms decode=80tok @30tok/s"
            ),
            ChatCurveLogEntry(
                date: t0.addingTimeInterval(3),
                message: "caption [m]: prompt=900tok prefill=400ms decode=5tok @30tok/s"
            ),
        ]
        let folded = ChatCurveLogParser.fold(ChatCurveLogParser.turnLines(entries, since: t0, label: "chatcurve"))
        #expect(folded.generations == 2)
        #expect(folded.decodeTokens == 200)
    }

    @Test("the turn-label set keeps every chat path and leaves a caption outside")
    func turnLabelsKeepEveryChatPath() {
        // The ttft line names the PATH (`stream`, `generate`, `toolTurn`, `toolTurnSession`), never the
        // provider — so a stage filtering on its provider's name read no generation at all (2026-10-25).
        let t0 = Date(timeIntervalSinceReferenceDate: 4000)
        let entries = ["stream", "generate", "toolTurn", "toolTurnSession", "caption"].enumerated().map { i, label in
            ChatCurveLogEntry(
                date: t0.addingTimeInterval(Double(i)),
                message: "\(label) [m]: prompt=10tok prefill=5ms decode=\(10 * (i + 1))tok @30tok/s"
            )
        }
        let folded = ChatCurveLogParser.fold(
            ChatCurveLogParser.turnLines(entries, since: t0, labels: ChatCurveLogParser.turnLabels)
        )
        #expect(folded.generations == 4)
        #expect(folded.decodeTokens == 100, "10 + 20 + 30 + 40; the 50-token caption is not the turn's")
    }

    @Test("a turn with no metric lines folds to nils, not zeros")
    func foldsEmpty() {
        let folded = ChatCurveLogParser.fold(["noise"])
        #expect(folded.reuse == nil)
        #expect(folded.promptTokens == nil)
        #expect(folded.prefillMS == nil)
        #expect(folded.extendMS == nil)
        #expect(folded.generations == 0)
    }

    private func sample(_ i: Int, total: Int?, prefill: Int?, extend: Int? = nil) -> ChatCurveSample {
        ChatCurveSample(
            index: i, question: "q\(i)", renderedTokens: total, reusedTokens: nil,
            promptTokens: nil, prefillMS: prefill, generations: 1, peakRSSMB: 1000 + i, answerChars: 10,
            extendMS: extend, mlxPeakMB: 3000 + i
        )
    }

    @Test("a message's real prefill is the generate's prefill plus the checkpoint extend")
    func totalPrefill() {
        #expect(sample(0, total: 1, prefill: 40, extend: 2100).totalPrefillMS == 2140)
        #expect(sample(0, total: 1, prefill: 40).totalPrefillMS == 40)
        #expect(sample(0, total: 1, prefill: nil, extend: 2100).totalPrefillMS == 2100)
        #expect(sample(0, total: 1, prefill: nil).totalPrefillMS == nil)
    }

    @Test("the slope the decision reads is over the TOTAL prefill, and the row shows both figures")
    func totalPrefillSlope() {
        let samples = (0 ..< 4).map { sample($0, total: 1000, prefill: 40, extend: 500 + 250 * $0) }
        let summary = ChatCurveSummary(samples: samples)
        #expect(summary.prefillMSPerMessage == 0)
        #expect(summary.totalPrefillMSPerMessage == 250)
        let row = ChatCurveReport(modelID: "m", samples: samples).rendered
        #expect(row.contains("extend=500ms"))
        #expect(row.contains("mlx=3000MB"))
        #expect(row.contains("total prefill ms/msg"))
    }

    @Test("a report written before the total-prefill slope still decodes")
    func decodesOlderReport() throws {
        let older = """
        {"modelID":"m","samples":[],"summary":{"renderedTokensPerMessage":208.3,"prefillMSPerMessage":27.3}}
        """
        let report = try JSONDecoder().decode(ChatCurveReport.self, from: Data(older.utf8))
        #expect(report.summary.totalPrefillMSPerMessage == nil)
        #expect(report.summary.prefillMSPerMessage == 27.3)
    }

    @Test("a curve written before the extend and MLX-peak columns still decodes")
    func decodesOlderSample() throws {
        let older = """
        {"answerChars":1,"generations":1,"index":0,"peakRSSMB":1,"prefillMS":48,"promptTokens":21,
         "question":"q","renderedTokens":3289,"reusedTokens":2467}
        """
        let sample = try JSONDecoder().decode(ChatCurveSample.self, from: Data(older.utf8))
        #expect(sample.extendMS == nil)
        #expect(sample.mlxPeakMB == nil)
        #expect(sample.totalPrefillMS == 48)
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
            sample(0, total: 100, prefill: nil),
            sample(1, total: nil, prefill: nil),
            sample(2, total: 300, prefill: nil),
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
        let text = try #require(String(bytes: data, encoding: .utf8))
        #expect(text.firstRange(of: "\"modelID\"") != nil)
        let back = try JSONDecoder().decode(ChatCurveReport.self, from: data)
        #expect(back.samples.count == 2)
        #expect(back.summary.renderedTokensPerMessage == 2)
    }

    @Test("the rendered table has one row per message plus the slope line")
    func rendered() {
        let report = ChatCurveReport(
            modelID: "m", samples: (0 ..< 3).map { sample($0, total: 100 * $0, prefill: 10 * $0) }
        )
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
