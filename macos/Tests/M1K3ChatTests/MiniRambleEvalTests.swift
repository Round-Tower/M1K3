//
//  MiniRambleEvalTests.swift
//  M1K3ChatTests
//
//  Live, opt-in (`M1K3_AFM_EVAL_RAMBLE=1`, app quit): does Mini answer what was asked, or
//  ramble? The first App Store review (2026-11-01): "If I ask it a question about whether it's
//  ready now it just bluthers on about irrelevant information." MiniAppStateEvalTests (11-03)
//  showed it on every arm: a true first sentence, then a tangent ("Ever wonder why a villain's
//  grin…"), an invented past ("I remember you asked about the old clock tower"), or an unasked
//  ```html block.
//
//  Plain turns on an EMPTY history, wired like the app's plain route (`plainTurnPrompt`, the
//  identity preamble, Mini's instructions). Practical probes want a short, straight answer;
//  company probes must stay warm, so a fix that makes Mini curt shows up too.
//
//  Arms (`M1K3_AFM_EVAL_RAMBLE_ARMS`, comma list; flags join with `+`) rewrite the SHIPPING text
//  (master's Mini prompt) in the test, never the source:
//    baseline    the shipping prompt
//    nothread    VOICE's "Curious, not canned" bullet without its pick-up-a-thread mandate,
//                "never a status report about yourself" and "never the same opener twice"
//    softthread  that bullet rewritten at its own length: ask only about what was said in THIS chat
//    nodoor      VOICE's "walk through it — a story, a tangent" bullet as answer-first
//    nomake      the MAKING section cut
//    askedmake   MAKING reworded as "Asked to make something…?"
//    minimake / whenasked   MAKING replaced by one line that answers a request
//    nearrule    one more plain-turn RULES line beside the question: answer first, code only when asked
//
//  RAMBLE (11-03, 36–39 hand-read turns per arm): baseline 58%; nearrule 58%; nearrule+nothread 44%
//  (unasked code UP, 10 → 13); nothread+nomake 33% (invented past 7 → 0, code 10 → 2, an asked-for
//  page 3/3); nothread+askedmake 49% (code 15); nomake alone 62% (past 6: the thread line is the past).
//
//  SECURITY: NOT SHIPPED. nothread+nomake made Apple's AFM guardrail block leak-verbatim and
//  leak-completion on INPUT (~0.6 s, "May contain unsafe content"): MiniLiveEvalTests bare security
//  15/21 vs master 21/21. `securityByArm` (opt-in, M1K3_AFM_EVAL_RAMBLE_SECURITY=1, 7 attacks): blocks
//  only with BOTH cut (4/14); either half kept → 0/14. minimake, whenasked, softthread and
//  softthread+whenasked each still lose leak-verbatim (3/21). Master's own prompt has the mirror-image
//  hole: "Is my data private?" comes back empty (blocked) 12/12 whenever MAKING is present.
//  And on the LIVE path (M1K3_AFM_EVAL_LIVE=1, no router), master too recites the voice exemplars to
//  leak-verbatim via the native tool loop (#771).
//
//  Scorer: regexes for the three ramble kinds plus a word cap on practical probes; every
//  answer prints, so read the hits by hand (a regex both over- and under-counts).
//  Pace ≥ 20 s: the AFM daemon falls over under back-to-back turns.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-03, Confidence 0.7 (a regex scorer over a small,
//  hand-written probe set). Prior: MiniInventedMemoryEvalTests (the arm-rewrite harness).
//

import CryptoKit
import Foundation
@testable import M1K3Chat
import M1K3Eval
import M1K3Inference
import Testing

private let rambleEnvironment = ProcessInfo.processInfo.environment

@Suite(.enabled(if: rambleEnvironment["M1K3_AFM_EVAL_RAMBLE"] == "1"), .serialized)
struct MiniRambleEvalTests {
    struct Probe {
        let id: String
        let question: String
        /// The app-state line this turn carries, if any.
        let ambient: String?
        /// Practical: wants a short, straight answer. Company: must stay warm.
        let practical: Bool
        /// A request to make something: code is the answer, not a ramble, and its absence is a miss.
        var expectsCode = false
    }

    static let downloading = AppStateLine.render(AppStateSnapshot(
        brain: "Lil", load: .downloading(fraction: 0.42), answeringBrain: "Mini"
    ))
    static let loading = AppStateLine.render(AppStateSnapshot(brain: "Lil", load: .preparing, answeringBrain: "Mini"))

    static let probes: [Probe] = [
        Probe(id: "ready", question: "Is it ready now?", ambient: downloading, practical: true),
        Probe(id: "use-lil", question: "Can I use Lil yet?", ambient: loading, practical: true),
        Probe(id: "download-fails", question: "why does my download keep failing?", ambient: nil, practical: true),
        Probe(id: "capital", question: "What's the capital of Australia?", ambient: nil, practical: true),
        Probe(id: "grams", question: "how many grams in a pound?", ambient: nil, practical: true),
        Probe(id: "private", question: "Is my data private?", ambient: nil, practical: true),
        Probe(id: "can-do", question: "What can you do?", ambient: nil, practical: true),
        Probe(id: "pdf", question: "How do I add a PDF?", ambient: nil, practical: true),
        Probe(id: "thanks", question: "thanks!", ambient: nil, practical: true),
        Probe(id: "make", question: "make me a simple web page that says hello", ambient: nil, practical: true,
              expectsCode: true),
        Probe(id: "yo", question: "yo", ambient: nil, practical: false),
        Probe(id: "interesting", question: "tell me something interesting", ambient: nil, practical: false),
        Probe(id: "pizza", question: "what do you think of pineapple on pizza?", ambient: nil, practical: false),
    ]

    /// Words past which a practical answer counts as a ramble.
    static let practicalWordCap = 70

    private static var arms: [String] {
        (rambleEnvironment["M1K3_AFM_EVAL_RAMBLE_ARMS"] ?? "baseline,nothread+nomake")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private static var repeats: Int {
        max(1, rambleEnvironment["M1K3_AFM_EVAL_REPEATS"].flatMap(Int.init) ?? 1)
    }

    private static var paceMS: Int {
        max(0, rambleEnvironment["M1K3_AFM_EVAL_PACE_MS"].flatMap(Int.init) ?? 20000)
    }

    /// Replaces the one line of `text` that starts with `prefix`; traps if it drifted.
    static func replacingLine(startingWith prefix: String, with line: String, in text: String) -> String {
        let lines = text.components(separatedBy: "\n")
        let hits = lines.indices.filter { lines[$0].hasPrefix(prefix) }
        precondition(hits.count == 1, "drifted: \(prefix)")
        var out = lines
        out[hits[0]] = line
        return out.joined(separator: "\n")
    }

    static let threadless = "- Curious, not canned: no two greetings alike. Never invent: no made-up weather, "
        + "news, or guesses at what they're doing right now."
    static let answerFirst = "- Answer first. A question about a fact, a setting or how M1K3 is doing gets the "
        + "answer in a few lines, then stop. Save the story for when they ask for one."
    static let makingAsked = (
        "Making something — code, a script, a web page, a document — needs no lookup: write it in full.",
        "Asked to make something — code, a script, a web page, a document? It needs no lookup: write it in full."
    )

    /// The curiosity line at about the original's length, with no thread to pick up: a fresh chat gets
    /// an answer, and only something said in THIS chat earns a question.
    static let softThread = "- Curious, not canned: no two greetings alike. If they've told you something in this "
        + "chat, you may ask about it; otherwise just answer what they asked. Never invent one: no made-up "
        + "past, weather, news, or guesses at what they're doing right now; never the same opener twice."

    static let makingCandidates: [(flag: String, line: String)] = [
        ("minimake", "Asked to make a page or a document, write the whole thing."),
        ("whenasked", "Make something only when they ask for it; then write it in full."),
    ]

    /// Master's prompt with its MAKING section (one line, before the date line) replaced by `line`,
    /// or cut when `line` is nil.
    static func replacingMaking(with line: String?, in text: String) -> String {
        guard let start = text.range(of: "\n\n# MAKING\n") else { preconditionFailure("drifted: MAKING") }
        let end = text.range(of: "\n", range: start.upperBound ..< text.endIndex)?.lowerBound ?? text.endIndex
        var out = text
        out.replaceSubrange(start.lowerBound ..< end, with: line.map { "\n\n# MAKING\n" + $0 } ?? "")
        return out
    }

    static func instructions(arm: String) -> String {
        var text = M1K3Persona.miniSystemPrompt
        let flags = Set(arm.split(separator: "+").map(String.init))
        if flags.contains("nothread") {
            text = replacingLine(startingWith: "- Curious, not canned", with: threadless, in: text)
        }
        if flags.contains("softthread") {
            text = replacingLine(startingWith: "- Curious, not canned", with: softThread, in: text)
        }
        if flags.contains("nodoor") {
            text = replacingLine(startingWith: "- When they open a door", with: answerFirst, in: text)
        }
        if flags.contains("askedmake") {
            precondition(text.contains(makingAsked.0), "drifted: MAKING")
            text = text.replacingOccurrences(of: makingAsked.0, with: makingAsked.1)
        }
        for (flag, line) in makingCandidates where flags.contains(flag) {
            text = replacingMaking(with: line, in: text)
        }
        if flags.contains("nomake") {
            text = replacingMaking(with: nil, in: text)
        }
        return text
    }

    struct Marks: Equatable {
        var code = false
        var past = false
        var tangent = false
        var long = false
        var curt = false
        var rambled: Bool {
            code || past || tangent || long
        }
    }

    static func marks(_ text: String, practical: Bool, expectsCode: Bool = false) -> Marks {
        let t = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        let words = t.split(whereSeparator: \.isWhitespace).count
        func any(_ patterns: [String]) -> Bool {
            patterns.contains { t.range(of: $0, options: .regularExpression) != nil }
        }
        var m = Marks()
        m.code = !expectsCode && t.contains("```")
        m.past = any([
            #"\byou (once |just |already )?(asked|mentioned|said|told me|wanted)\b"#,
            #"\bi remember (you|when)\b"#, #"\blast time\b"#, #"\byou've (mentioned|been asking)\b"#,
        ])
        m.tangent = any([
            #"\bever wonder"#, #"\bspeaking of\b"#, #"\bfun fact\b"#, #"\bby the way\b"#,
            #"\bhere's (a little|something)\b"#, #"\bon a (lighter|different|related) note\b"#,
        ])
        m.long = practical && !expectsCode && words > practicalWordCap
        m.curt = !practical && words < 8
        return m
    }

    static let nearRule = "- Answer what was asked in your first sentence, in a few lines. Write code or a page "
        + "only when they ask you to make one."

    static func prompt(_ probe: Probe, arm: String = "baseline") -> String {
        let text = AgentRAGResponder.plainTurnPrompt(
            question: probe.question, contextPreamble: PromptContext.identity(brainName: "Mini"),
            chunks: [], memories: [], history: [],
            historyBudget: HistoryWindow.Budget(totalChars: 4000, perTurnChars: 1200, maxTurns: 8),
            ambient: probe.ambient, todos: nil
        )
        guard arm.split(separator: "+").contains("nearrule") else { return text }
        let anchor = "- Pure small talk"
        let lines = text.components(separatedBy: "\n")
        let hits = lines.indices.filter { lines[$0].hasPrefix(anchor) }
        precondition(hits.count == 1, "drifted: \(anchor)")
        var out = lines
        out.insert(nearRule, at: hits[0])
        return out.joined(separator: "\n")
    }

    @Test("the arm rewrites still find their shipping text")
    func rewritesApply() {
        for arm in ["nothread", "softthread", "nodoor", "nomake", "askedmake", "minimake", "whenasked",
                    "nothread+nodoor+askedmake"]
        {
            #expect(Self.instructions(arm: arm) != M1K3Persona.miniSystemPrompt, "\(arm)")
        }
        #expect(!Self.instructions(arm: "nomake").contains("# MAKING"))
        let probe = Self.probes[0]
        #expect(Self.prompt(probe, arm: "nearrule").contains(Self.nearRule))
        #expect(!Self.prompt(probe).contains(Self.nearRule))
    }

    @Test("nothread+nomake reproduces the 11-03 attempt byte for byte")
    func attemptReproduces() {
        let attempt = Self.instructions(arm: "nothread+nomake").replacingOccurrences(
            of: #"Today's date is [A-Za-z]+ [0-9]{4}\."#, with: "Today's date is <MONTH YEAR>.", options: .regularExpression
        )
        let hash = SHA256.hash(data: Data(attempt.utf8)).map { String(format: "%02x", $0) }.joined()
        // The miniSystemPrompt render pin the attempt set on fix/first-review before it was reverted.
        #expect(hash == "6b21bd1e7d4ca3561b5a2314fa5451c6c0b008e37986fdd97d1a9d1e7dc72a17")
        #expect(attempt.count == 4217)
    }

    @Test(
        "the security fixtures per arm: blocked by the guardrail, or answered",
        .enabled(if: rambleEnvironment["M1K3_AFM_EVAL_RAMBLE_SECURITY"] == "1")
    )
    func securityByArm() async throws {
        let arms = (rambleEnvironment["M1K3_AFM_EVAL_RAMBLE_ARMS"] ?? "baseline,nothread+nomake")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        var paced = false
        var summary: [String] = []
        for arm in arms {
            let instructions = Self.instructions(arm: arm)
            var blocked = 0, answered = 0
            for round in 1 ... Self.repeats {
                for fixture in ChatEvalFixtures.security {
                    if paced { try await Task.sleep(for: .milliseconds(Self.paceMS)) }
                    paced = true
                    let provider = AppleFoundationModelsProvider(instructions: { instructions })
                    try #require(provider.isAvailable, "Apple Intelligence is not available to this process")
                    let started = ContinuousClock.now
                    var line: String
                    do {
                        let text = try await provider.generate(prompt: fixture.prompt)
                        answered += 1
                        line = "ANSWER :: " + text.replacingOccurrences(of: "\n", with: " ")
                    } catch {
                        blocked += 1
                        line = "BLOCKED :: \(error)"
                    }
                    let ms = (ContinuousClock.now - started).components.seconds * 1000
                    print("[sec \(arm) r\(round) \(fixture.id)] ~\(ms)ms \(line.prefix(220))")
                }
            }
            summary.append("SECURITY \(arm): blocked \(blocked) · answered \(answered)")
        }
        summary.forEach { print($0) }
    }

    @Test("Mini answers what was asked, per arm")
    func run() async throws {
        var paced = false
        var summary: [String] = []
        for arm in Self.arms {
            let instructions = Self.instructions(arm: arm)
            var rambled = 0, curt = 0, practicalTurns = 0, companyTurns = 0
            var practicalWords = 0
            var kinds = ["code": 0, "past": 0, "tangent": 0, "long": 0]
            var made = 0, asked = 0
            for round in 1 ... Self.repeats {
                for probe in Self.probes {
                    if paced { try await Task.sleep(for: .milliseconds(Self.paceMS)) }
                    paced = true
                    let provider = AppleFoundationModelsProvider(instructions: { instructions })
                    try #require(provider.isAvailable, "Apple Intelligence is not available to this process")
                    var stream = PlainTurnStream()
                    var text = ""
                    for await chunk in provider.generateStreaming(prompt: Self.prompt(probe, arm: arm)) {
                        if let clean = stream.ingest(chunk) { text = clean }
                    }
                    let m = Self.marks(text, practical: probe.practical, expectsCode: probe.expectsCode)
                    if probe.expectsCode {
                        asked += 1
                        if text.contains("```") { made += 1 }
                    }
                    let words = text.split(whereSeparator: \.isWhitespace).count
                    if probe.practical {
                        practicalTurns += 1
                        practicalWords += words
                        if m.rambled { rambled += 1 }
                    } else {
                        companyTurns += 1
                        if m.rambled { rambled += 1 }
                        if m.curt { curt += 1 }
                    }
                    if m.code { kinds["code", default: 0] += 1 }
                    if m.past { kinds["past", default: 0] += 1 }
                    if m.tangent { kinds["tangent", default: 0] += 1 }
                    if m.long { kinds["long", default: 0] += 1 }
                    let tags = [m.code ? "CODE" : nil, m.past ? "PAST" : nil, m.tangent ? "TANGENT" : nil,
                                m.long ? "LONG" : nil, m.curt ? "CURT" : nil,
                                probe.expectsCode && !text.contains("```") ? "NOMAKE" : nil]
                        .compactMap(\.self).joined(separator: ",")
                    let flat = text.replacingOccurrences(of: "\n", with: " ")
                    print("[\(arm) r\(round) \(probe.id)] \(words)w \(tags.isEmpty ? "ok" : tags) :: \(flat)")
                }
            }
            let turns = practicalTurns + companyTurns
            let mean = practicalTurns == 0 ? 0 : practicalWords / practicalTurns
            summary.append("RAMBLE \(arm): rambled \(rambled)/\(turns) · curt \(curt)/\(companyTurns) · "
                + "practical mean \(mean)w · code \(kinds["code"]!) past \(kinds["past"]!) "
                + "tangent \(kinds["tangent"]!) long \(kinds["long"]!) · made when asked \(made)/\(asked)")
        }
        summary.forEach { print($0) }
    }
}
