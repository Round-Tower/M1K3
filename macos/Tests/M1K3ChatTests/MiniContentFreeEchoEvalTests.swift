//
//  MiniContentFreeEchoEvalTests.swift
//  M1K3ChatTests
//
//  Live, opt-in (`M1K3_AFM_EVAL_ECHO=1`): does a content-free reply ("Please.", "go on", "ok thanks")
//  make Mini write its last reply out again? Kev's iPhone, 2026-11-02: Lil did, word for word, after a
//  story that ended on a question. Each case runs Mini's plain turn without and with
//  `AgentRAGResponder.contentFreeReplyNote`. An echo is a reply whose first 80 characters (folded) match
//  the previous reply's. Every answer is printed for a hand read. Pace ≥ 20 s (the AFM daemon).
//
//  Signed: Kev + claude-opus-5.5, 2026-11-02, Confidence 0.6 (Mini stands in for Lil, which needs the
//  app). Prior: Unknown.
//

import Foundation
@testable import M1K3Chat
import M1K3Inference
import Testing

private let echoEnvironment = ProcessInfo.processInfo.environment

@Suite(.enabled(if: echoEnvironment["M1K3_AFM_EVAL_ECHO"] == "1"), .serialized)
struct MiniContentFreeEchoEvalTests {
    struct Case {
        let id: String
        let history: [ChatTurn]
        let reply: String
    }

    static let story = """
    Alright then. Imagine a house where the temperature drops as if a heavy door slammed, but there is no \
    draft. Whisper a name there and the shadows stretch toward the sound: the name itself becomes the ghost. \
    So... what do you think? Should the story end with someone trying to erase the name, or does the ghost \
    want them to keep saying it forever?
    """

    static let cases = [
        Case(id: "phone", history: [
            ChatTurn(role: .user, text: "Tell me a story about one."),
            ChatTurn(role: .assistant, text: story),
        ], reply: "Please."),
        Case(id: "goon", history: [
            ChatTurn(role: .user, text: "Start me a short story about a lighthouse keeper."),
            ChatTurn(role: .assistant, text: "The keeper climbed the ninety steps at dusk, as he had for thirty years. "
                + "Tonight the lamp was already lit. Want me to keep going?"),
        ], reply: "go on"),
        Case(id: "thanks", history: [
            ChatTurn(role: .user, text: "What's the weather in Cork?"),
            ChatTurn(role: .assistant, text: "Cork: 12°C, light rain clearing by evening, a breeze off the harbour."),
        ], reply: "ok thanks"),
        Case(id: "lookup", history: [
            ChatTurn(role: .user, text: "Who won the Ballon d'Or this year?"),
            ChatTurn(role: .assistant, text: "I'm not sure off-hand. Want me to look it up?"),
        ], reply: "yes please"),
        Case(id: "timer", history: [
            ChatTurn(role: .user, text: "How long do I boil dried pasta?"),
            ChatTurn(role: .assistant, text: "About 11 minutes for most dried pasta. Want me to set a timer?"),
        ], reply: "yes"),
        Case(id: "yes", history: [
            ChatTurn(role: .user, text: "I can't sleep."),
            ChatTurn(role: .assistant, text: "Rough one. Want a short, slow story to wind down to?"),
        ], reply: "yes"),
    ]

    static let repeats = Int(echoEnvironment["M1K3_AFM_EVAL_ECHO_REPEATS"] ?? "") ?? 3

    /// Claiming a lookup or an action that never ran (no tools on this turn).
    static let claimCues = [
        "timer set", "timer is set", "timer's set", "timer is running", "timer started", "i've set", "i have set",
        "i set a", "i set the", "i set your", "set a timer for you", "i looked it up", "i looked up", "i've looked",
        "i have looked", "according to my search", "according to the search", "according to the results",
        "the winner is", "the winner was",
    ]

    static func claims(_ text: String) -> Bool {
        let folded = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return claimCues.contains { folded.contains($0) }
    }

    static func fold(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber }.prefix(80))
    }

    @Test("echoes per arm")
    func run() async throws {
        let budget = HistoryWindow.Budget(totalChars: 4000, perTurnChars: 1200, maxTurns: 8)
        var echoes = ["none": 0, "note": 0]
        var claims = ["none": 0, "note": 0]
        var n = 0
        var paced = false
        for trial in 0 ..< Self.repeats {
            for item in Self.cases {
                n += 1
                for arm in ["none", "note"] {
                    if paced { try await Task.sleep(for: .seconds(20)) }
                    paced = true
                    var prompt = AgentRAGResponder.plainTurnPrompt(
                        question: item.reply, contextPreamble: PromptContext.identity(brainName: "Mini"),
                        chunks: [], memories: [], history: item.history, historyBudget: budget, ambient: nil, todos: nil
                    )
                    if arm == "none" {
                        let note = "\n" + AgentRAGResponder.contentFreeReplyNote
                        prompt = prompt.replacingOccurrences(of: note, with: "")
                    }
                    let provider = AppleFoundationModelsProvider(instructions: { M1K3Persona.miniSystemPrompt })
                    try #require(provider.isAvailable, "Apple Intelligence is not available to this process")
                    var answer = PlainTurnStream()
                    var text = ""
                    for await chunk in provider.generateStreaming(prompt: prompt) {
                        if let clean = answer.ingest(chunk) { text = clean }
                    }
                    let previous = item.history.last?.text ?? ""
                    let echo = !text.isEmpty && Self.fold(text) == Self.fold(previous)
                    let claim = Self.claims(text)
                    echoes[arm, default: 0] += echo ? 1 : 0
                    claims[arm, default: 0] += claim ? 1 : 0
                    let flat = text.replacingOccurrences(of: "\n", with: " ")
                    print("[t\(trial + 1) \(item.id) \(arm)] echo=\(echo) claim=\(claim) :: \(flat)")
                }
            }
        }
        print("ECHO none \(echoes["none"] ?? 0)/\(n) · note \(echoes["note"] ?? 0)/\(n)")
        print("CLAIM none \(claims["none"] ?? 0)/\(n) · note \(claims["note"] ?? 0)/\(n) "
            + "(hand-read the lookup/timer rows)")
    }
}
