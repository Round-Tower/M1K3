//
//  MiniAppStateEvalTests.swift
//  M1K3ChatTests
//
//  Live, opt-in (`M1K3_AFM_EVAL_APPSTATE=1`): with the app-state line in the ambient section, does Mini
//  answer "is it ready now?" truthfully? The first App Store review (iPhone, 2026-11-01) got a ramble.
//  Each case runs Mini's plain turn without the line (today) and with it. A rule scores each answer, and
//  every answer is printed for a hand read. Pace ≥ 20 s (the AFM daemon).
//
//  Signed: Kev + claude-opus-5.5, 2026-11-03, Confidence 0.6 (a keyword score; read the answers). Prior: Unknown.
//

import Foundation
@testable import M1K3Chat
import M1K3Inference
import Testing

private let appStateEnvironment = ProcessInfo.processInfo.environment

@Suite(.enabled(if: appStateEnvironment["M1K3_AFM_EVAL_APPSTATE"] == "1"), .serialized)
struct MiniAppStateEvalTests {
    enum Truth { case notReady, ready, failed }

    struct State {
        let id: String
        let snapshot: AppStateSnapshot
        let truth: Truth
    }

    static let now = Date()
    static let states = [
        State(id: "downloading", snapshot: AppStateSnapshot(
            brain: "Lil", load: .downloading(fraction: 0.42), answeringBrain: "Mini"
        ), truth: .notReady),
        State(id: "loading", snapshot: AppStateSnapshot(brain: "Lil", load: .preparing, answeringBrain: "Mini"),
              truth: .notReady),
        State(id: "just-ready", snapshot: AppStateSnapshot(
            brain: "Lil", load: .ready, readySince: now.addingTimeInterval(-30)
        ), truth: .ready),
        State(id: "failed", snapshot: AppStateSnapshot(
            brain: "Lil", load: .failed(message: "Not enough space on this device. Free up about 3 GB and try again.")
        ), truth: .failed),
    ]

    static let questions = ["Is it ready now?", "Is the download done yet?", "Can I use Lil yet?"]

    static func correct(_ text: String, truth: Truth) -> Bool {
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let denies = ["not ready", "isn't ready", "not yet", "still download", "still loading", "isn't quite",
                      "not quite", "42%", "42 percent", "almost"].contains { t.contains($0) }
        switch truth {
        case .notReady: return denies
        case .ready: return t.contains("ready") && !denies && !t.contains("still")
        case .failed: return ["space", "couldn't load", "could not load", "failed", "free up"].contains { t.contains($0) }
        }
    }

    @Test("truthful readiness answers per arm")
    func run() async throws {
        let budget = HistoryWindow.Budget(totalChars: 4000, perTurnChars: 1200, maxTurns: 8)
        var right = ["none": 0, "line": 0]
        var n = 0
        var paced = false
        for state in Self.states {
            for question in Self.questions {
                n += 1
                for arm in ["none", "line"] {
                    if paced { try await Task.sleep(for: .seconds(20)) }
                    paced = true
                    let line = arm == "line" ? AppStateLine.render(state.snapshot, now: Self.now) : nil
                    let brain = state.snapshot.answeringBrain ?? "Mini"
                    let prompt = AgentRAGResponder.plainTurnPrompt(
                        question: question, contextPreamble: PromptContext.identity(brainName: brain),
                        chunks: [], memories: [], history: [], historyBudget: budget, ambient: line, todos: nil
                    )
                    let provider = AppleFoundationModelsProvider(instructions: { M1K3Persona.miniSystemPrompt })
                    try #require(provider.isAvailable, "Apple Intelligence is not available to this process")
                    var answer = PlainTurnStream()
                    var text = ""
                    for await chunk in provider.generateStreaming(prompt: prompt) {
                        if let clean = answer.ingest(chunk) { text = clean }
                    }
                    let ok = Self.correct(text, truth: state.truth)
                    right[arm, default: 0] += ok ? 1 : 0
                    let flat = text.replacingOccurrences(of: "\n", with: " ")
                    print("[\(state.id) \(arm)] ok=\(ok) Q=\(question) :: \(flat)")
                }
            }
        }
        print("APPSTATE none \(right["none"] ?? 0)/\(n) · line \(right["line"] ?? 0)/\(n)")
    }
}
