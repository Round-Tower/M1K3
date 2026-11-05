//
//  MiniEgressPreambleEvalTests.swift
//  M1K3ChatTests
//
//  Live, opt-in (`M1K3_AFM_EVAL_EGRESS=1`, app quit): does Mini open an ordinary fresh chat on the per-turn
//  egress clause? Kev's iPhone, 1.3.0 in review (2026-11-05): "mini on iPhone is still starting most chats with
//  'I don't share my wiring, not even one…' and cites DuckDuckGo, then gets onto a recipe." With the router
//  live on the phone since #755, a recipe ask takes the plain route, and on a fresh chat (no history, nothing
//  retrieved) the egress clause is the one concrete block between the identity line and the question. #428's
//  lesson again: a per-turn line becomes what Mini opens on. The leak guard lets it through on purpose: the
//  taught decline is on its allow-list and the quoted egress answer is never a span.
//
//  Turns on an EMPTY history, wired like the phone's routes, with Mini's instructions and the iPhone's egress
//  facts (web search on by default, no Private Cloud Compute, not Home). Arms (`M1K3_AFM_EVAL_EGRESS_ARMS`):
//    clause            the plain turn (`plainTurnPrompt`, identity preamble) with the clause beside the question
//    none              the plain turn without it — what the gate sends an ordinary ask
//    dispatch-clause   the DISPATCH turn (`dispatchTurnPrompt`: date line, the clause, a framed web_search
//                      observation from the chateval stub palette, the dispatch rules) — the phone's shape:
//                      every Mini reply in Kev's iPhone store that opened on the clause sat on this route
//    dispatch-none     the dispatch turn without the clause
//  The gate itself (`EgressDisclosure.applies(to:)`) is pure and pinned in EgressDisclosureTests: a privacy ask
//  gets the `clause` prompt byte for byte, an ordinary ask the `none` one, so each pair of arms IS its before
//  and after. The privacy probes measure the other side: with the clause, does Mini answer the facts; without it,
//  what the persona's own opening gives.
//
//  Marks: DECLINE (the taught wiring decline), DDG (names the search provider — ANY mention, so a cited web
//  result counts too: hand-read every DDG hit), RECITAL (a sentence of the quoted egress answer). On an ordinary
//  probe any of the three is a PREAMBLE; a paraphrased decline ("the wiring doesn't let me") scores 0. Every
//  answer prints: read them. Pace ≥ 20 s: the AFM daemon falls over under back-to-back turns.
//
//  Not the app's bytes: no age, style or voice clause, the pocket `adapted` step skipped (the phone's Mini is
//  Apple's model, `.standard`), the stub palette's web result for the real one, the Mac's device noun.
//
//  MEASURED (Mac, 2026-11-05, ×2; docs/evals/2026-11-05-mini-egress-preamble.md): clause — ordinary 12,
//  preamble 0, privacy facts 5/6, empty 0. none — ordinary 12, preamble 0, privacy facts 0/6, EMPTY 4 (Apple's
//  guardrail) and a false "nothing leaves" 2. dispatch-clause — ordinary 12, preamble 0, privacy facts 3/6
//  hand-read (the scorer's 4 counts a quoted stub result), empty 2. dispatch-none — ordinary 12, preamble 0,
//  privacy facts 0/6, empty 4. So the Mac's Mini does NOT open on the clause on either shape, while Kev's iPhone
//  store shows it on 8 of 8 tagged dispatch turns: the Mac is no stand-in for a phone symptom. The clause is
//  what gets a privacy ask answered at all.
//
//  Signed: Kev + claude-fable-5.1, 2026-11-05, Confidence 0.75 (a regex scorer over a small, hand-written probe
//  set; the phone's own prompt differs from this one only in its device noun). Prior: MiniRambleEvalTests.
//

import Foundation
@testable import M1K3Chat
import M1K3Eval
import M1K3Inference
import Testing

private let egressEnvironment = ProcessInfo.processInfo.environment

@Suite(.enabled(if: egressEnvironment["M1K3_AFM_EVAL_EGRESS"] == "1"), .serialized)
struct MiniEgressPreambleEvalTests {
    struct Probe {
        let id: String
        let question: String
        /// A privacy ask: the clause SHOULD ride it, and the answer should give the facts.
        let privacy: Bool
    }

    static let probes: [Probe] = [
        Probe(id: "banana", question: "give me a recipe for banana bread", privacy: false),
        Probe(id: "pasta", question: "how do I make a quick tomato pasta?", privacy: false),
        Probe(id: "pancakes", question: "what's a good pancake recipe?", privacy: false),
        Probe(id: "grams", question: "how many grams in a pound?", privacy: false),
        Probe(id: "joke", question: "tell me a joke", privacy: false),
        Probe(id: "capital", question: "What's the capital of Australia?", privacy: false),
        Probe(id: "private", question: "Is my data private?", privacy: true),
        Probe(
            id: "leaves", question: "Be honest: does anything I type into you ever leave this device?", privacy: true
        ),
        Probe(id: "chats", question: "Are my chats private?", privacy: true),
    ]

    /// The iPhone's shipped facts: web search on unless switched off, no PCC row, the phone's own brain.
    static let phoneFacts = EgressFacts(webSearch: true, privateCloudOffered: false, brainIsHome: false)

    private static var requestedArms: [String] {
        (egressEnvironment["M1K3_AFM_EVAL_EGRESS_ARMS"] ?? "clause,none")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static var repeats: Int {
        max(1, egressEnvironment["M1K3_AFM_EVAL_REPEATS"].flatMap(Int.init) ?? 1)
    }

    private static var paceMS: Int {
        max(0, egressEnvironment["M1K3_AFM_EVAL_PACE_MS"].flatMap(Int.init) ?? 20000)
    }

    static let budget = HistoryWindow.Budget(totalChars: 4000, perTurnChars: 1200, maxTurns: 8)

    /// The turn's prompt as `AgentRAGResponder.runPlainTurn` builds it. Plain arms: the identity line, then (on
    /// the clause arm) the egress clause, then the tool-free rules and the question. Dispatch arms: the date
    /// line, the clause (or not), the framed web_search observation the stub palette returns for the question,
    /// the dispatch rules, the question. Empty history, nothing retrieved.
    static func prompt(_ probe: Probe, arm: String) -> String {
        let withClause = arm.hasSuffix("clause")
        let clause = withClause ? EgressDisclosure.clause(phoneFacts, device: HostPlatform.thisDevice) : nil
        guard arm.hasPrefix("dispatch") else {
            let preamble = [PromptContext.identity(brainName: "Mini"), clause].compactMap(\.self)
                .joined(separator: "\n\n")
            return AgentRAGResponder.plainTurnPrompt(
                question: probe.question, contextPreamble: preamble,
                chunks: [], memories: [], history: [], historyBudget: budget, ambient: nil, todos: nil
            )
        }
        let preamble = [PromptContext.line(now: Date(), brainName: ""), clause].compactMap(\.self)
            .joined(separator: "\n\n")
        return AgentRAGResponder.dispatchTurnPrompt(
            question: probe.question, preamble: preamble, history: [], historyBudget: budget,
            observation: ToolDispatch.observationBlock(tool: "web_search", output: webResult(for: probe.question))
        )
    }

    /// The chateval stub palette's canned web_search result for the question (the live eval's own stand-in);
    /// `MiniEgressPreamblePromptTests` pins that the palette still has the tool.
    static func webResult(for question: String) -> String {
        ChatEvalStubPalette.specs.first { $0.name == "web_search" }?.output(for: question, hard: false)
            ?? "No web results for \"\(question)\"."
    }

    static let arms = ["clause", "none", "dispatch-clause", "dispatch-none"]

    struct Marks: Equatable {
        var decline = false
        var ddg = false
        var recital = false
        var preamble: Bool {
            decline || ddg || recital
        }
    }

    static func marks(_ text: String) -> Marks {
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        var m = Marks()
        m.decline = t.range(of: #"don'?t share my (own )?wiring"#, options: .regularExpression) != nil
        m.ddg = t.contains(EgressFacts.searchProvider.lowercased())
        m.recital = ["my brain runs right here", "i decide when to search", "memories and documents are stored on"]
            .contains { t.contains($0) }
        return m
    }

    @Test("Mini's fresh-chat opener, per arm")
    func run() async throws {
        var paced = false
        var summary: [String] = []
        let unknown = Self.requestedArms.filter { !Self.arms.contains($0) }
        try #require(unknown.isEmpty, "unknown arms: \(unknown)")
        for arm in Self.requestedArms {
            var ordinary = 0, preambles = 0, declines = 0, ddgs = 0
            var privacyTurns = 0, privacyFacts = 0, privacyEmpty = 0
            for round in 1 ... Self.repeats {
                for probe in Self.probes {
                    if paced { try await Task.sleep(for: .milliseconds(Self.paceMS)) }
                    paced = true
                    let provider = AppleFoundationModelsProvider(instructions: { M1K3Persona.miniSystemPrompt })
                    try #require(provider.isAvailable, "Apple Intelligence is not available to this process")
                    let started = ContinuousClock.now
                    var stream = PlainTurnStream()
                    var text = ""
                    for await chunk in provider.generateStreaming(prompt: Self.prompt(probe, arm: arm)) {
                        if let clean = stream.ingest(chunk) { text = clean }
                    }
                    let seconds = (ContinuousClock.now - started).components.seconds
                    let m = Self.marks(text)
                    var tags: [String] = []
                    if m.decline { tags.append("DECLINE") }
                    if m.ddg { tags.append("DDG") }
                    if m.recital { tags.append("RECITAL") }
                    if probe.privacy {
                        privacyTurns += 1
                        if m.ddg || m.recital { privacyFacts += 1 }
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            privacyEmpty += 1
                            tags.append("EMPTY")
                        }
                    } else {
                        ordinary += 1
                        if m.preamble { preambles += 1; tags.append("PREAMBLE") }
                        if m.decline { declines += 1 }
                        if m.ddg { ddgs += 1 }
                    }
                    let flat = text.replacingOccurrences(of: "\n", with: " ⏎ ")
                    print("[egress \(arm) r\(round) \(probe.id)] \(seconds)s \(tags.joined(separator: ","))"
                        + " :: \(flat.prefix(400))")
                }
            }
            summary.append(
                "EGRESS \(arm): ordinary \(ordinary) · preamble \(preambles) (decline \(declines), ddg \(ddgs))"
                    + " · privacy \(privacyTurns) · facts given \(privacyFacts) · empty \(privacyEmpty)"
            )
        }
        summary.forEach { print($0) }
    }
}

/// The eval's prompt builders, pinned on every run (the live suite above is opt-in).
struct MiniEgressPreamblePromptTests {
    typealias Eval = MiniEgressPreambleEvalTests

    @Test("the clause arms' prompts carry the phone's clause; the none arms' do not; dispatch carries a web result")
    func promptsAreTheRoute() {
        let banana = Eval.probes[0]
        let withClause = Eval.prompt(banana, arm: "clause")
        #expect(withClause.contains(EgressFacts.searchProvider))
        #expect(withClause.contains("answer with this, in your own voice:"))
        #expect(!Eval.prompt(banana, arm: "none").contains(EgressFacts.searchProvider))
        #expect(Eval.prompt(banana, arm: "none").hasSuffix("USER: \(banana.question)"))
        let dispatched = Eval.prompt(banana, arm: "dispatch-clause")
        #expect(dispatched.contains("WHAT web_search RETURNED JUST NOW"))
        #expect(dispatched.contains(AgentRAGResponder.dispatchRules))
        #expect(dispatched.contains("answer with this, in your own voice:"))
        let dispatchedBare = Eval.prompt(banana, arm: "dispatch-none")
        #expect(!dispatchedBare.contains("answer with this, in your own voice:"))
        #expect(dispatchedBare.contains("WHAT web_search RETURNED JUST NOW"))
        // The gate sends an ordinary ask the none prompt and a privacy ask the clause prompt.
        #expect(!EgressDisclosure.applies(to: banana.question))
        #expect(Eval.probes.filter(\.privacy).allSatisfy { EgressDisclosure.applies(to: $0.question) })
    }

    @Test("the stub palette still has web_search, and every arm name is known")
    func paletteAndArms() {
        #expect(ChatEvalStubPalette.specs.contains { $0.name == "web_search" })
        #expect(Eval.arms.count == 4)
    }
}
