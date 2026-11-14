//
//  ReadEvalStage.swift
//  M1K3App
//
//  The read eval on an MLX brain (Lil by default), inside the built app because
//  `swift test` cannot reach the metallib. The same arms and scorer as Mini's
//  `ReadEvalLiveTests` (M1K3Eval's `ReadEval`). The sandbox cannot open the repo,
//  so the set arrives on STDIN, and the rows leave on stdout:
//
//      M1K3_SELFTEST=1 M1K3_SELFTEST_OUT=- M1K3_SELFTEST_READEVAL=1 \
//      M1K3_SELFTEST_MODEL=mlx-community/Qwen3.5-4B-MLX-4bit \
//      M1K3_SELFTEST_READEVAL_ARMS=head,extractive,filled,bare  (optional) \
//      M1K3_SELFTEST_READEVAL_WINDOW=8192                     (optional; the brain's read window by default) \
//      M1K3.app/Contents/MacOS/M1K3 < blind-set.json | grep '^READEVAL' | cut -f2-
//
//  The provider is built as the app builds Lil (thinking ON at construction); the
//  read turns thinking off per session, as it does in the app. The weights load and
//  one throwaway read happen before the first timed row. Quit the live app first:
//  two MLX processes crawl.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-14, Confidence 0.7 (compiles in the app
//  shell; the first launch is the run itself). Prior: none (new file; EnergyProbeStage's shape).
//

import Foundation
import M1K3Eval
import M1K3Inference
import M1K3MLX

enum ReadEvalStage {
    static var isRequested: Bool {
        SelfTestEnv.value("M1K3_SELFTEST_READEVAL") == "1"
    }

    static func run(emit: @escaping (String) -> Void) async {
        let set: ReadEvalSet
        do {
            set = try JSONDecoder().decode(ReadEvalSet.self, from: FileHandle.standardInput.readDataToEndOfFile())
        } catch {
            emit("✗ readeval: no set on stdin (\(error))")
            return
        }
        guard let modelID = SelfTestEnv.value("M1K3_SELFTEST_READEVAL_MODEL") ?? BrainTier.lil.mlxModelID else {
            emit("✗ readeval: no model id")
            return
        }
        let arms = (SelfTestEnv.value("M1K3_SELFTEST_READEVAL_ARMS") ?? "head,extractive,filled,bare")
            .split(separator: ",").compactMap { ReadArm.named(String($0)) }
        let provider = MLXBrainProvider(modelID: modelID, name: "read-eval", thinkingEnabled: true)
        let window = SelfTestEnv.value("M1K3_SELFTEST_READEVAL_WINDOW").flatMap(Int.init) ?? provider.readContextTokens
        let brain = BrainTier(generatingModelID: modelID).map { "\($0)" } ?? modelID
        emit("• readeval: \(set.docs.count) docs, arms \(arms.map(\.name)), window \(window), \(modelID)")
        do {
            try await provider.prepare(progress: { _ in })
            for try await _ in provider.read(instructions: ReadPrompt.instructions, prompt: "Say OK.") {}
        } catch {
            emit("✗ readeval: warm-up failed (\(error))")
            return
        }
        emit("READEVAL\t" + ReadEval.tsvHeader)
        let clock = ContinuousClock()
        for doc in set.docs {
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
                    let row = ReadEval.Row(
                        brain: brain, arm: arm, doc: doc, question: question, ask: ask,
                        score: ReadEval.score(answer: answer, question: question, injection: doc.injection),
                        firstMillis: first.map(millis), totalMillis: millis(clock.now - start), answer: answer
                    )
                    emit("READEVAL\t" + row.tsv)
                }
            }
        }
        emit("✓ readeval: done")
    }

    private static func millis(_ duration: Duration) -> Int {
        Int(duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
