//
//  ContentFreeBlindEvalTests.swift
//  M1K3ChatTests
//
//  Opt-in, deterministic (`M1K3_CONTENTFREE_BLIND=<path to blind-followups.json>`): scores the
//  content-free follow-up fix on a blind set of one-assistant-turn follow-ups
//  ({id, assistant, user, expect: chat|search, subject, note}). Each row takes the phone's route
//  through the REAL responder: history is the one assistant turn, the gate is
//  `ToolNeedRouter.decide` over Apple's sentence embedding (`NLSentenceEmbedder`), no group head,
//  no search head, and the picker is a recorder. No live model: the provider is scripted.
//
//  Two pickers run per row:
//  - inventing: always web_search "current weather in New York" (what Apple's picker did on Kev's
//    iPhone, 2026-11-02, after "Yes. Please." to a story offer);
//  - faithful: names the row's subject (search_knowledge for a notes subject, else web_search),
//    so an offer's correct pick can be seen to survive `keptOfferPick`.
//  Master's route is modelled from the same gate verdict with master's override only (pointsBack),
//  the picker getting the user's own words: the branch changes nothing else before the picker.
//
//  Classes are the blind set's own labels, fixed by id below (never the code under test):
//  (a) chat, no content; (b) search after a lookup offer + content-free yes; (c) reply carries
//  content; (d) non-English.
//
//  Run: M1K3_CONTENTFREE_BLIND=/path/blind-followups.json tools/dev/tdd.sh M1K3ChatTests ContentFreeBlind
//
//  Signed: Kev + claude-opus-5.5, 2026-11-02, Confidence 0.8 (the gate is real, the picker is not:
//  it measures the route and the offer filter, not what Apple's picker would name). Prior: none (new file).
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
        let route: String // chat / picker(plain msg) / offer-picker(msg)
        let pickerMessage: String?
        let ran: [String]
        var toolRan: Bool {
            !ran.isEmpty
        }

        var final: String {
            ran.isEmpty ? "plain" : ran.joined(separator: " → ")
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
        let responder = try AgentRAGResponder(
            store: KnowledgeStore(), embedder: HashingEmbeddingService(), provider: Scripted(),
            toolsProvider: { tools }, plainRouteProvider: { route }
        )
        let history = [ChatTurn(role: .assistant, text: row.assistant)]
        let stream = try await responder.answerStreaming(
            row.user, images: [], history: history, onActivity: { _ in }
        ).stream
        for await _ in stream {}
        let messages = calls.picks.withLock { $0 }
        let routeName: String
        if let message = messages.first {
            routeName = message == row.user ? "picker(plain msg)" : "offer-picker(msg)"
        } else {
            routeName = "chat"
        }
        return Outcome(route: routeName, pickerMessage: messages.first, ran: calls.ran.withLock { $0 })
    }

    /// Master's route: the gate, overridden to chat only by pointsBack; the picker reads the user's words.
    private static func masterRoute(_ row: Row, gate: ToolNeedRouter.Decision) -> String {
        let pointsBack = gate.verdict == .tools
            && (gate.probability ?? 1) < ToolNeedRouter.pointsBackCeiling
            && ToolNeedRouter.pointsBackInChat(row.user)
        return gate.verdict == .tools && !pointsBack ? "picker(plain msg)" : "chat"
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
        var aHit = 0, aTotal = 0
        var bHit = 0, bTotal = 0, bKeptInvented = 0, bKeptFaithful = 0
        var cHit = 0, cTotal = 0
        for row in rows {
            let gate = ToolNeedRouter.decide(for: row.user, embed: embedder.vector)
            let kind = ToolNeedRouter.contentFreeReply(row.user).map { "\($0)" } ?? "-"
            let offer = ToolNeedRouter.lookupOffer(in: [ChatTurn(role: .assistant, text: row.assistant)])
            let branch = try await Self.run(row, gate: gate, pick: inventing)
            let subject = row.subject ?? row.user
            let faithfulPick = ToolPick(
                tool: subject.lowercased().contains("notes") ? "search_knowledge" : "web_search", query: subject
            )
            let faithful = try await Self.run(row, gate: gate, pick: faithfulPick)
            let master = Self.masterRoute(row, gate: gate)
            let p = gate.probability.map { String(format: "%.3f", $0) } ?? "none"
            let msg = branch.pickerMessage.map { $0.replacingOccurrences(of: "\n", with: " ⏎ ") } ?? ""
            lines.append(
                """
                \(row.id) \(row.expect) p=\(p) \(gate.verdict == .tools ? "tools" : "chat") cf=\(kind) \
                offer=\(offer == nil ? "-" : "yes") | branch=\(branch.route) ran=\(branch.toolRan) \
                final=\(branch.final) | faithful=\(faithful.final) | master=\(master) | user=\(row.user) \
                \(msg.isEmpty ? "" : "| msg=\(msg)")
                """
            )

            if Self.nonEnglish.contains(row.id) { continue }
            if Self.chatNoContent.contains(row.id) {
                aTotal += 1
                if branch.route == "chat" { aHit += 1 } else {
                    misses.append("(a) \(row.id) reached the picker (\(branch.route), cf=\(kind), p=\(p)): \(row.user)")
                }
            } else if Self.offerYes.contains(row.id) {
                bTotal += 1
                // The offer sentence, as the branch frames it, is the picker's whole message.
                let routed = branch.route == "offer-picker(msg)"
                    && offer.map { branch.pickerMessage == ToolNeedRouter.offerPickMessage(offer: $0, reply: row.user) }
                    == true
                if routed { bHit += 1 } else {
                    misses.append(
                        "(b) \(row.id) not offer-routed (route=\(branch.route), cf=\(kind), offer=\(offer ?? "nil"), p=\(p)): \(row.user)"
                    )
                }
                if branch.toolRan { bKeptInvented += 1 }
                if faithful.toolRan { bKeptFaithful += 1 }
                if routed, !faithful.toolRan {
                    misses.append("(b) \(row.id) faithful pick \(faithfulPick.query) dropped by keptOfferPick")
                }
            } else {
                cTotal += 1
                let unchanged = branch.route == master
                if unchanged { cHit += 1 } else {
                    misses.append("(c) \(row.id) route changed: master=\(master) branch=\(branch.route): \(row.user)")
                }
            }
        }
        print("=== content-free blind eval: \(rows.count) rows ===")
        lines.forEach { print($0) }
        print("--- bars ---")
        print("(a) chat, no content, never reach the picker: \(Self.pct(aHit, aTotal)) [bar 100%]")
        print("(b) lookup offer + yes, offer-picker with the offer: \(Self.pct(bHit, bTotal))")
        print("    inventing NY pick kept (tool ran): \(bKeptInvented)/\(bTotal); faithful pick ran: \(bKeptFaithful)/\(bTotal)")
        print("(c) reply with content, route unchanged vs master: \(Self.pct(cHit, cTotal)) [bar 100%]")
        print("(d) non-English: see rows \(Self.nonEnglish.sorted().joined(separator: ", "))")
        print("--- misses ---")
        misses.forEach { print($0) }
    }
}
