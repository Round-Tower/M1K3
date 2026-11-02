//
//  ContentFreeBlindEvalTests.swift
//  M1K3ChatTests
//
//  Opt-in, deterministic (`M1K3_CONTENTFREE_BLIND=<path to blind-followups.json>`): scores the
//  content-free follow-up fix on a blind set of one-assistant-turn follow-ups
//  ({id, assistant, user, expect: chat|search, subject, note}). Each row takes the phone's route
//  through the REAL responder: history is the one assistant turn, the gate is
//  `ToolNeedRouter.decide` over Apple's sentence embedding (`NLSentenceEmbedder`), no group head,
//  no search head. No live model: the provider is scripted and the picker is a recorder that
//  always invents web_search "current weather in New York" (what Apple's picker did on Kev's
//  iPhone, 2026-11-02, after "Yes. Please." to a story offer).
//
//  Per row: the gate's p, the reply kind, whether the previous reply offers a tool, and the route
//  the turn took: chat (a plain turn), picker(msg) (the picker read msg; New York's weather runs
//  only here), or agent (no picker; the agent turn reads the chat and the whole palette).
//  Master's route is modelled from the same gate verdict with master's override only (pointsBack),
//  the picker getting the user's own words.
//
//  Classes are the blind set's own labels, fixed by id below (never the code under test):
//  (a) chat, no content; (b) search after a lookup offer + content-free yes; (c) reply carries
//  content; (d) non-English.
//
//  Run: M1K3_CONTENTFREE_BLIND=/path/blind-followups.json tools/dev/tdd.sh M1K3ChatTests ContentFreeBlind
//
//  Signed: Kev + claude-opus-5.5, 2026-11-02, Confidence 0.8 (the gate is real, the picker is not:
//  it measures the route, not what Apple's picker would name). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-11-02 — the routes of the redesign: a yes to a tool offer is the agent
//  turn (no picker), so the faithful picker and the offer-picker bar are gone; (b)'s bar is the agent route.
//  Confidence 0.8.
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
    }

    /// The blind set's classes, read off its notes (not off `contentFreeReply`).
    static let chatNoContent: Set = [
        "f01", "f02", "f03", "f04", "f05", "f06", "f07", "f08", "f09", "f10", "f11", "f12", "f13", "f14", "f15",
        "f16", "f59", "f60", "f61", "f63",
    ]
    static let offerYes: Set = [
        "f17", "f18", "f19", "f20", "f21", "f22", "f23", "f24", "f25", "f26", "f27", "f28", "f29", "f30",
    ]
    static let nonEnglish: Set = ["f51", "f52", "f53", "f54", "f55", "f56", "f57", "f58"]

    private final class Scripted: InferenceProvider, @unchecked Sendable {
        let name = "blind-scripted"
        let isAvailable = true
        let prompts = Mutex<[String]>([])
        func generate(prompt: String) async throws -> String {
            prompts.withLock { $0.append(prompt) }
            return "CONCLUSION: ok"
        }

        func generateStreaming(prompt: String) -> AsyncStream<String> {
            prompts.withLock { $0.append(prompt) }
            return AsyncStream { $0.yield("CONCLUSION: ok"); $0.finish() }
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
        let route: String // chat / picker(msg) / agent
        let ran: [String]
        var newYork: Bool {
            ran.contains { $0.contains("New York") }
        }
    }

    private static func run(_ row: Row, gate: ToolNeedRouter.Decision, pick: ToolPick) async throws -> Outcome {
        let calls = Calls()
        let route = PlainTurnRoute(
            decide: { _ in gate },
            instructions: nil,
            pick: { @Sendable message, _ in
                calls.picks.withLock { $0.append(message) }
                return pick
            }
        )
        let tools: [any AgentTool] = palette.map { Recording(name: $0, calls: calls) }
        let provider = Scripted()
        let responder = try AgentRAGResponder(
            store: KnowledgeStore(), embedder: HashingEmbeddingService(), provider: provider,
            toolsProvider: { tools }, plainRouteProvider: { route }
        )
        let history = [ChatTurn(role: .assistant, text: row.assistant)]
        let stream = try await responder.answerStreaming(
            row.user, images: [], history: history, onActivity: { _ in }
        ).stream
        for await _ in stream {}
        let routeName = if let message = calls.picks.withLock({ $0 }).first {
            "picker(\(message))"
        } else if provider.prompts.withLock({ $0 }).first?.contains(AgentRAGResponder.plainRules) == true {
            "chat"
        } else {
            "agent"
        }
        return Outcome(route: routeName, ran: calls.ran.withLock { $0 })
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

    @Test("blind content-free follow-ups: the phone's route, branch vs master")
    func blind() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["M1K3_CONTENTFREE_BLIND"])
        let rows = try JSONDecoder().decode([Row].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let embedder = NLSentenceEmbedder()
        try #require(embedder.vector("what's the weather in Cork?") != nil, "Apple's sentence embedding is missing")
        let inventing = ToolPick(tool: "web_search", query: "current weather in New York")

        var lines: [String] = []
        var misses: [String] = []
        var aHit = 0, aTotal = 0, bHit = 0, bTotal = 0, cHit = 0, cTotal = 0
        var newYork: [String: [String]] = [:]
        for row in rows {
            let gate = ToolNeedRouter.decide(for: row.user, embed: embedder.vector)
            let kind = ToolNeedRouter.contentFreeReply(row.user).map { "\($0)" } ?? "-"
            let offer = ToolNeedRouter.toolOffer(in: [ChatTurn(role: .assistant, text: row.assistant)])
            let branch = try await Self.run(row, gate: gate, pick: inventing)
            let master = Self.masterRoute(row, gate: gate)
            let p = gate.probability.map { String(format: "%.3f", $0) } ?? "none"
            let label = Self.nonEnglish.contains(row.id) ? "d" : Self.chatNoContent.contains(row.id) ? "a"
                : Self.offerYes.contains(row.id) ? "b" : "c"
            if branch.newYork { newYork[label, default: []].append(row.id) }
            lines.append(
                """
                \(row.id) (\(label)) \(row.expect) p=\(p) \(gate.verdict == .tools ? "tools" : "chat") reply=\(kind) \
                offer=\(offer == nil ? "-" : "yes") | route=\(branch.route) NY=\(branch.newYork ? "RUNS" : "-") \
                | master=\(master) | user=\(row.user)
                """
            )

            switch label {
            case "a":
                aTotal += 1
                if branch.route == "chat" { aHit += 1 } else {
                    misses.append("(a) \(row.id) route=\(branch.route) (reply=\(kind), p=\(p)): \(row.user)")
                }
            case "b":
                bTotal += 1
                if branch.route == "agent" { bHit += 1 } else {
                    misses.append(
                        "(b) \(row.id) route=\(branch.route) (reply=\(kind), offer=\(offer ?? "nil"), p=\(p)): "
                            + row.user
                    )
                }
            case "c":
                cTotal += 1
                if branch.route == master { cHit += 1 } else {
                    misses.append("(c) \(row.id) route changed: master=\(master) branch=\(branch.route)")
                }
            default:
                break
            }
        }
        print("=== content-free blind eval: \(rows.count) rows ===")
        lines.forEach { print($0) }
        print("--- bars ---")
        print("(a) chat, no content, a plain turn: \(Self.pct(aHit, aTotal)) [bar 100%]")
        print("(b) lookup offer + yes, the agent turn: \(Self.pct(bHit, bTotal))")
        print("(c) reply with content, route unchanged vs master: \(Self.pct(cHit, cTotal)) [bar 100%]")
        print("(d) non-English: see rows \(Self.nonEnglish.sorted().joined(separator: ", "))")
        for label in ["a", "b", "c", "d"] {
            let ids = newYork[label] ?? []
            let which = ids.isEmpty ? "" : " — " + ids.joined(separator: ", ")
            print("New York weather runs in (\(label)): \(ids.count)\(which)")
        }
        print("--- misses ---")
        misses.forEach { print($0) }
    }
}
