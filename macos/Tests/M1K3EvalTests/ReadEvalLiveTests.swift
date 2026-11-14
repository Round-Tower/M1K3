//
//  ReadEvalLiveTests.swift
//  M1K3EvalTests
//
//  Mini (Apple's on-device model) through the read seam on the blind set, live.
//  OFF unless `M1K3_READ_EVAL=1`, never in CI (no Apple Intelligence there):
//
//      M1K3_READ_EVAL=1 M1K3_READ_EVAL_ARMS=head,extractive,filled,bare \
//      M1K3_READ_EVAL_WINDOW=4096 M1K3_READ_EVAL_OUT=/path/mini.tsv \
//      swift test --disable-xctest --filter ReadEvalLiveTests
//
//  The window defaults to Mini's floor (4,096): the worst device. The bare arm
//  runs on the injection docs only (it exists to score the defences).
//
//  Signed: Kev + claude-opus-5.5, 2026-11-14, Confidence 0.8, Prior: none (new file)
//

import Foundation
import M1K3Eval
import M1K3Inference
import Testing

private let readEnvironment = ProcessInfo.processInfo.environment

@Suite(.enabled(if: readEnvironment["M1K3_READ_EVAL"] == "1"), .serialized)
struct ReadEvalLiveTests {
    private static var setURL: URL {
        if let path = readEnvironment["M1K3_READ_EVAL_SET"] { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/evals/2026-11-14-read-blind")
    }

    @Test("Mini reads the blind set")
    func miniReadsTheBlindSet() async throws {
        let provider = AppleFoundationModelsProvider()
        try #require(provider.isAvailable, "Apple Intelligence is not ready on this Mac")
        let set = try ReadEvalSet.load(from: Self.setURL)
        let arms = (readEnvironment["M1K3_READ_EVAL_ARMS"] ?? "head,extractive,filled,bare")
            .split(separator: ",").compactMap { ReadArm.named(String($0)) }
        let window = Int(readEnvironment["M1K3_READ_EVAL_WINDOW"] ?? "") ?? MiniContextWindow.floorTokens
        let only = readEnvironment["M1K3_READ_EVAL_DOCS"].map { Set($0.split(separator: ",").map(String.init)) }
        let outURL = URL(fileURLWithPath: readEnvironment["M1K3_READ_EVAL_OUT"] ?? NSTemporaryDirectory() + "read-eval-mini.tsv")
        var lines = [ReadEval.tsvHeader]
        let clock = ContinuousClock()

        for doc in set.docs where only?.contains(doc.id) ?? true {
            for arm in arms where arm != .bare || doc.injection != nil {
                for question in doc.questions {
                    let ask = ReadEval.ask(doc: doc, question: question, arm: arm, windowTokens: window)
                    let start = clock.now
                    var first: Duration?
                    var answer = ""
                    do {
                        for try await snapshot in provider.read(instructions: ask.instructions, prompt: ask.prompt) {
                            if first == nil { first = clock.now - start }
                            answer = snapshot
                        }
                    } catch {
                        answer = "ERROR: " + ReadFailureReply.reply(for: error)
                    }
                    let total = clock.now - start
                    let row = ReadEval.Row(
                        brain: "mini", arm: arm, doc: doc, question: question, ask: ask,
                        score: ReadEval.score(answer: answer, question: question, injection: doc.injection),
                        firstMillis: first.map(Self.millis), totalMillis: Self.millis(total), answer: answer
                    )
                    lines.append(row.tsv)
                    print("[read-eval] \(arm.name) \(question.id) passed=\(row.score.passed) obeyed=\(row.score.obeyed.map(String.init) ?? "-") \(Self.millis(total)) ms")
                    try (lines.joined(separator: "\n") + "\n").write(to: outURL, atomically: true, encoding: .utf8)
                }
            }
        }
        print("[read-eval] wrote \(lines.count - 1) rows to \(outURL.path)")
    }

    private static func millis(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
