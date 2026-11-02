//
//  ContentFreeBlindEvalTests.swift
//  M1K3ChatTests
//
//  Opt-in, deterministic (`M1K3_CONTENTFREE_BLIND=<path to a blind set>`): scores the content-free
//  follow-up fix on a blind set of one-assistant-turn follow-ups. Three schemas read the same:
//  {id, assistant, user, expect: chat|search, subject?, note?} (set 1) and
//  {id, assistant, user, expect: chat|tool, note?} (sets 2 and 3); "search" and "tool" both mean the
//  turn should reach the picker. Each row takes the phone's route through the REAL responder:
//  history is the one assistant turn, the gate is `ToolNeedRouter.decide` over Apple's sentence
//  embedding (`NLSentenceEmbedder`) on whatever the responder asks it about (the reply, and on a yes
//  the offer), no group head, no search head. No live model: the provider is scripted and the picker
//  is a recorder that always invents web_search "current weather in New York" (what Apple's picker
//  did on Kev's iPhone, 2026-11-02, after "Yes. Please." to a story offer).
//
//  Per row: the gate's p on the reply and on the offer, the reply kind, and the route: chat (a plain
//  turn) or picker(msg) (the picker read msg; New York's weather runs only here). Master's route is
//  modelled from the reply's gate verdict with master's override only (pointsBack), the picker
//  getting the user's own words. Scored against the set's own `expect`, never the code under test;
//  one invariant is the code's: a reply with content takes master's route.
//
//  Run: M1K3_CONTENTFREE_BLIND=/path/blind-followups.json tools/dev/tdd.sh M1K3ChatTests ContentFreeBlind
//
//  Signed: Kev + claude-opus-5.5, 2026-11-02, Confidence 0.8 (the gate is real, the picker is not:
//  it measures the route, not what Apple's picker would name). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-11-02 — round 3: routes are chat or picker(msg), the real gate reads the
//  offer, both p's print, and all three set schemas score against `expect`. Confidence 0.8.
//

import Foundation
import M1K3Agent
@testable import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import Synchronization
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["M1K3_CONTENTFREE_BLIND"] != nil), .serialized)
struct ContentFreeBlindEvalTests {
    struct Row: Decodable {
        let id: String
        let assistant: String
        let user: String
        let expect: String
        let subject: String?
        let note: String?

        /// "search" (set 1) and "tool" (sets 2 and 3) both want the picker.
        var wantsTool: Bool {
            expect == "search" || expect == "tool"
        }
    }

    private final class Scripted: InferenceProvider, @unchecked Sendable {
        let name = "blind-scripted"
        let isAvailable = true
        func generate(prompt _: String) async throws -> String {
            "ok"
        }

        func generateStreaming(prompt _: String) -> AsyncStream<String> {
            AsyncStream { $0.yield("ok"); $0.finish() }
        }
    }

    private final class Calls: Sendable {
        let ran = Mutex<[String]>([])
        let picks = Mutex<[String]>([])
    }

    private struct Recording: AgentTool {
        let name: String
        let calls: Calls
        var description: String {
            name
        }

        var parameters: [ToolParameter] {
            [ToolParameter(name: "query", description: "")]
        }

        func execute(input: [String: String]) async throws -> ToolResult {
            calls.ran.withLock { $0.append("\(name)(\(input["query"] ?? ""))") }
            return ToolResult(output: "result")
        }
    }

    private static let palette = [
        "datetime", "system_status", "search_knowledge", "list_documents", "web_search", "lookup_fact",
        "fetch_page", "recent_activity", "calendar_peek", "battery_status", "current_location",
    ]

    struct Outcome {
        let route: String // chat / picker(msg)
        let message: String?
        let ran: [String]
        var newYork: Bool {
            ran.contains { $0.contains("New York") }
        }
    }

    private static func run(
        _ row: Row, decide: @escaping @Sendable (String) -> ToolNeedRouter.Decision, pick: ToolPick
    ) async throws -> Outcome {
        let calls = Calls()
        let route = PlainTurnRoute(
            decide: decide,
            instructions: nil,
            pick: { @Sendable message, _ in
                calls.picks.withLock { $0.append(message) }
                return pick
            }
        )
        let tools: [any AgentTool] = palette.map { Recording(name: $0, calls: calls) }
        let responder = try AgentRAGResponder(
            store: KnowledgeStore(), embedder: HashingEmbeddingService(), provider: Scripted(),
            toolsProvider: { tools }, plainRouteProvider: { route }
        )
        let history = [ChatTurn(role: .assistant, text: row.assistant)]
        let stream = try await responder.answerStreaming(
            row.user, images: [], history: history, onActivity: { _ in }
        ).stream
        for await _ in stream {}
        let message = calls.picks.withLock { $0 }.first
        return Outcome(
            route: message.map { "picker(\($0))" } ?? "chat", message: message, ran: calls.ran.withLock { $0 }
        )
    }

    /// Master's route: the gate, overridden to chat only by pointsBack; the picker reads the user's words.
    private static func masterRoute(_ row: Row, gate: ToolNeedRouter.Decision) -> String {
        let pointsBack = gate.verdict == .tools
            && (gate.probability ?? 1) < ToolNeedRouter.pointsBackCeiling
            && ToolNeedRouter.pointsBackInChat(row.user)
        return gate.verdict == .tools && !pointsBack ? "picker(\(row.user))" : "chat"
    }

    private static func pct(_ hit: Int, _ total: Int) -> String {
        total == 0 ? "n/a" : String(format: "%d/%d (%.0f%%)", hit, total, 100 * Double(hit) / Double(total))
    }

    private static func score(_ decision: ToolNeedRouter.Decision?) -> String {
        guard let decision else { return "-" }
        let p = decision.probability.map { String(format: "%.3f", $0) } ?? "none"
        return "\(p) \(decision.verdict == .tools ? "tools" : "chat")"
    }

    @Test("blind content-free follow-ups: the phone's route, branch vs master")
    func blind() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["M1K3_CONTENTFREE_BLIND"])
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let embedder = NLSentenceEmbedder()
        try #require(embedder.vector("what's the weather in Cork?") != nil, "Apple's sentence embedding is missing")
        let decide: @Sendable (String) -> ToolNeedRouter.Decision = { text in
            ToolNeedRouter.decide(for: text, embed: embedder.vector)
        }
        let inventing = ToolPick(tool: "web_search", query: "current weather in New York")

        var lines: [String] = []
        var misses: [String] = []
        var branchHit = 0, baselineHit = 0
        var chatHit = 0, chatTotal = 0, toolHit = 0, toolTotal = 0
        var freeChatHit = 0, freeChatTotal = 0, freeToolHit = 0, freeToolTotal = 0
        var contentSame = 0, contentTotal = 0
        var subjectHit = 0, subjectTotal = 0
        var blindPicks: [String] = []
        for row in rows {
            let gate = decide(row.user)
            let reply = ToolNeedRouter.contentFreeReply(row.user)
            let offer = ToolNeedRouter.offerText(in: [ChatTurn(role: .assistant, text: row.assistant)])
            let offerGate = reply == .affirmative ? offer.map(decide) : nil
            let branch = try await Self.run(row, decide: decide, pick: inventing)
            let master = Self.masterRoute(row, gate: gate)
            let wantsPicker = row.wantsTool
            let branchRight = (branch.message != nil) == wantsPicker
            let baselineRight = master.hasPrefix("picker") == wantsPicker
            if branchRight { branchHit += 1 }
            if baselineRight { baselineHit += 1 }
            if wantsPicker {
                toolTotal += 1
                if branchRight { toolHit += 1 }
            } else {
                chatTotal += 1
                if branchRight { chatHit += 1 }
            }
            if let reply {
                if wantsPicker {
                    freeToolTotal += 1
                    if branchRight { freeToolHit += 1 }
                } else {
                    freeChatTotal += 1
                    if branchRight { freeChatHit += 1 }
                }
                // A picker handed a content-free message invents (New York's weather).
                if let message = branch.message, ToolNeedRouter.contentFreeReply(message) != nil {
                    blindPicks.append("\(row.id) (\(reply)): \(message)")
                }
            } else {
                contentTotal += 1
                if branch.route == master { contentSame += 1 } else {
                    misses.append("(content) \(row.id) route changed: master=\(master) branch=\(branch.route)")
                }
            }
            var subjectNote = ""
            if wantsPicker, let subject = row.subject, !subject.isEmpty {
                subjectTotal += 1
                let seen = branch.message?.localizedCaseInsensitiveContains(subject) == true
                if seen { subjectHit += 1 }
                subjectNote = " subject=\(seen ? "in-msg" : "missing")"
            }
            if !branchRight {
                misses.append(
                    "\(row.id) expect=\(row.expect) route=\(branch.route) reply=\(reply.map { "\($0)" } ?? "-") "
                        + "p(reply)=\(Self.score(gate)) p(offer)=\(Self.score(offerGate)): \(row.user)"
                )
            }
            lines.append(
                """
                \(row.id) expect=\(row.expect) \(branchRight ? "OK" : "MISS") p(reply)=\(Self.score(gate)) \
                p(offer)=\(Self.score(offerGate)) reply=\(reply.map { "\($0)" } ?? "-") \
                | route=\(branch.route) NY=\(branch.newYork ? "RUNS" : "-")\(subjectNote) \
                | master=\(master) \(baselineRight ? "OK" : "MISS") | user=\(row.user)
                """
            )
        }
        print("=== content-free blind eval: \(rows.count) rows ===")
        lines.forEach { print($0) }
        print("--- bars (against the set's own expect) ---")
        print("all rows, branch: \(Self.pct(branchHit, rows.count)) | master: \(Self.pct(baselineHit, rows.count))")
        print("expect chat → chat: \(Self.pct(chatHit, chatTotal))")
        print("expect tool/search → picker: \(Self.pct(toolHit, toolTotal))")
        print("content-free, expect chat → chat: \(Self.pct(freeChatHit, freeChatTotal))")
        print("content-free, expect tool/search → picker (on the offer): \(Self.pct(freeToolHit, freeToolTotal))")
        print("reply with content, route unchanged vs master: \(Self.pct(contentSame, contentTotal)) [bar 100%]")
        if subjectTotal > 0 { print("picker message names the subject: \(Self.pct(subjectHit, subjectTotal))") }
        print("picker handed a content-free message: \(blindPicks.count) [bar 0]")
        blindPicks.forEach { print("  \($0)") }
        print("--- misses ---")
        misses.forEach { print($0) }
    }
}
