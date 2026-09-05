//
//  ChatEvalJSONTests.swift
//  M1K3EvalTests
//
//  The published scorecard needs a machine-readable primary artifact, not a
//  regex reshaping of the text transcript. These pin the JSON document: it
//  round-trips, it carries provenance (hardware, OS, app commit, runtime pin,
//  power mode, live-path, repeats) beside the runs, and its keys are stable and
//  sorted so two runs diff cleanly.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-05, Confidence 0.9. Prior: Unknown

import Foundation
@testable import M1K3Eval
import Testing

struct ChatEvalJSONTests {
    private func score(_ id: String, _ kind: TaskKind, passed: Bool, latency: Int, repeatIndex: Int = 0) -> ChatEvalScore {
        ChatEvalScore(
            fixtureID: id, kind: kind,
            checks: [EvalCheck(name: "c", outcome: passed ? .pass : .fail, detail: "d")],
            latencyMS: latency, answerPreview: "hello", repeatIndex: repeatIndex
        )
    }

    private var provenance: EvalProvenance {
        EvalProvenance(
            date: "2026-09-05T12:00:00Z", hardware: "Apple M1 Max · 64 GB", osVersion: "macOS 26.4",
            appCommit: "6d41624c", mlxSwiftLMRevision: "c97539da", powerMode: 2, powerSource: "ac", livePath: true,
            repeats: 2, notes: "machine quiet"
        )
    }

    @Test("the document round-trips through Codable with every field intact")
    func roundTrip() throws {
        let run = ChatEvalReport.BrainRun(brainID: "big", modelID: "mlx-community/Qwen3.8-27B-4bit", scores: [
            score("o1", .openChat, passed: true, latency: 500),
            score("o1", .openChat, passed: false, latency: 700, repeatIndex: 1),
        ])
        let doc = ChatEvalDocument(provenance: provenance, runs: [run])
        let data = try ChatEvalReport.json(doc)
        let back = try JSONDecoder().decode(ChatEvalDocument.self, from: data)
        #expect(back == doc)
        #expect(back.schemaVersion == 1)
        #expect(back.runs[0].modelID == "mlx-community/Qwen3.8-27B-4bit")
        #expect(back.runs[0].scores[1].repeatIndex == 1)
        #expect(back.runs[0].scores[0].checks[0].outcome == .pass)
    }

    @Test("keys are sorted and outcomes are readable strings, so two runs diff cleanly")
    func stableShape() throws {
        let run = ChatEvalReport.BrainRun(brainID: "lil", scores: [score("t1", .toolUse, passed: true, latency: 10)])
        let text = try #require(String(data: ChatEvalReport.json(ChatEvalDocument(provenance: provenance, runs: [run])), encoding: .utf8))
        #expect(text.contains("\"outcome\" : \"pass\""))
        #expect(text.contains("\"kind\" : \"tool-use\""))
        #expect(text.contains("\"schemaVersion\" : 1"))
        #expect(text.contains("\"mlxSwiftLMRevision\" : \"c97539da\""))
        // sortedKeys: "appCommit" precedes "date" precedes "hardware".
        let a = try #require(text.range(of: "\"appCommit\""))
        let d = try #require(text.range(of: "\"date\""))
        let h = try #require(text.range(of: "\"hardware\""))
        #expect(a.lowerBound < d.lowerBound && d.lowerBound < h.lowerBound)
    }

    @Test("repeats: the matrix counts every repeat as a trial, so n is visible in passed/total")
    func repeatsCount() {
        let run = ChatEvalReport.BrainRun(brainID: "lil", scores: [
            score("s1", .security, passed: true, latency: 10, repeatIndex: 0),
            score("s1", .security, passed: false, latency: 10, repeatIndex: 1),
            score("s1", .security, passed: true, latency: 10, repeatIndex: 2),
        ])
        #expect(run.passedCount == 2)
        #expect(run.total == 3)
        #expect(ChatEvalReport.matrix([run]).contains("2/3"))
    }

    @Test("withRepeatIndex stamps the trial and changes nothing else")
    func stampRepeat() {
        let base = score("s1", .security, passed: true, latency: 10)
        let stamped = base.withRepeatIndex(2)
        #expect(stamped.repeatIndex == 2)
        #expect(stamped.fixtureID == base.fixtureID && stamped.checks == base.checks && stamped.latencyMS == 10)
    }

    @Test("a scorecard written before powerSource existed still decodes, with the source unknown")
    func decodesWithoutPowerSource() throws {
        let legacy = """
        {"date":"2026-09-05T12:00:00Z","hardware":"h","osVersion":"o","powerMode":0,"livePath":true,"repeats":1}
        """
        let p = try JSONDecoder().decode(EvalProvenance.self, from: Data(legacy.utf8))
        #expect(p.powerSource == nil)
        #expect(p.rendered.contains("power unknown · powermode 0"))
    }

    @Test("provenance renders as a header block the text transcript carries too")
    func provenanceHeader() {
        let header = provenance.rendered
        #expect(header.contains("Apple M1 Max"))
        // 2026-09-05: a day of tok/s was measured on battery under Adaptive Power while "powermode 0" read as
        // normal — the SOURCE is the fact that moved the numbers 2×, so it rides beside the mode.
        #expect(header.contains("power ac · powermode 2"))
        #expect(header.contains("live-path yes"))
        #expect(header.contains("repeats 2"))
        #expect(header.contains("mlx-swift-lm c97539da"))
    }
}
