//
//  MiniReplyLanguageLiveTests.swift
//  M1K3ChatTests
//
//  Live, opt-in (`M1K3_AFM_EVAL=1`, app quit, never CI): does Mini (Apple Foundation Models) answer in the
//  person's language when the reply-language clause rides the turn? The Mac and the iPhone both send Mini the
//  clause (`ReplyLanguage.liveClause` → `turnClauses`), and until this suite no eval had run it on Mini.
//
//  Each turn is built the way `AgentRAGResponder.runPlainTurn` builds an ordinary routed chat turn on an empty
//  history: the identity line, then `turnClauses` (here the reply-language clause alone: no age, egress, style or
//  voice line applies to these asks), then the tool-free rules and the question (`plainTurnPrompt`), under Mini's
//  own instructions (`M1K3Persona.miniSystemPrompt`, the provider's default and the app's). Two arms per turn,
//  interleaved so the pair shares the daemon's state:
//    on    the clause from `ReplyLanguage.clause(for:earlierTurns:deviceLanguage:)` — two turns each in German,
//          French, Spanish, Portuguese and Japanese (the "person" form), plus two short German turns on a German
//          device, too short to read, so the DEVICE form ("This device is set to German: reply in German.") speaks
//    off   the same prompt without the clause: the paired baseline, what the clause changes
//  The reply's language is read by the chateval scorer (`ChatEvalScorer.replyLanguage(of:)`), sentence by
//  sentence and won by letters. An empty stream is re-asked once through `generate` so the thrown error can be
//  classified (`AFMFailure`: guardrail, unsupported language, daemon); the unsupported-language reply text the
//  stream yields itself is caught as UNSUPPORTED. Pace (`M1K3_AFM_EVAL_PACE_MS`, default 20 s): the daemon falls
//  over under back-to-back turns.
//
//      M1K3_AFM_EVAL=1 swift test --filter MiniReplyLanguageLiveTests
//
//  MEASURED (Mac, macOS 27, 2026-11-19, one run, an MLX eval sharing the GPU): on 12/12, off 3/12 (de 0→4 of 4
//  incl. both device turns, fr 0→2, es 2→2, pt 0→2, ja 1→2). No guardrail, unsupported-language or empty turn on
//  either arm. Without the clause Mini answers German, French, Portuguese and the short German greetings in
//  English; Spanish it already answers in Spanish.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-19, Confidence 0.7 (twelve hand-written turns, one run per arm; the
//  scorer is the chateval `language` kind's own). Prior: MiniEgressPreambleEvalTests (gating, pacing, prompt).
//

import Foundation
@testable import M1K3Chat
@testable import M1K3Eval
import M1K3Inference
import Testing

private let replyLanguageEnvironment = ProcessInfo.processInfo.environment

@Suite(.enabled(if: replyLanguageEnvironment["M1K3_AFM_EVAL"] == "1"), .serialized)
struct MiniReplyLanguageLiveTests {
    struct Turn {
        let id: String
        let question: String
        /// The language the reply should come back in.
        let expected: String
        /// The device's preferred language; only a turn too short to read reaches it.
        let device: String
        /// The clause `ReplyLanguage` must give this turn (pinned before Mini is asked).
        let clause: String
    }

    static let turns: [Turn] = [
        Turn(
            id: "de-egg", question: "Wie lange muss ich ein Ei kochen, damit es weich bleibt?", expected: "de",
            device: "en-US", clause: "The person is writing in German: reply in German."
        ),
        Turn(
            id: "de-sleep", question: "Kannst du mir drei Tipps geben, wie ich besser schlafe?", expected: "de",
            device: "en-US", clause: "The person is writing in German: reply in German."
        ),
        Turn(
            id: "fr-croc", question: "Quelle est la différence entre un crocodile et un alligator ?",
            expected: "fr", device: "en-US", clause: "The person is writing in French: reply in French."
        ),
        Turn(
            id: "fr-sky", question: "Peux-tu m'expliquer pourquoi le ciel est bleu ?", expected: "fr",
            device: "en-US", clause: "The person is writing in French: reply in French."
        ),
        Turn(
            id: "es-guitar", question: "¿Cuál es la mejor manera de aprender a tocar la guitarra?",
            expected: "es", device: "en-US", clause: "The person is writing in Spanish: reply in Spanish."
        ),
        Turn(
            id: "es-book", question: "¿Me puedes recomendar un buen libro para leer este verano?",
            expected: "es", device: "en-US", clause: "The person is writing in Spanish: reply in Spanish."
        ),
        Turn(
            id: "pt-basil", question: "Qual é a melhor forma de conservar manjericão fresco em casa?",
            expected: "pt", device: "en-US", clause: "The person is writing in Portuguese: reply in Portuguese."
        ),
        Turn(
            id: "pt-photo", question: "Você pode me explicar como funciona a fotossíntese?",
            expected: "pt", device: "en-US", clause: "The person is writing in Portuguese: reply in Portuguese."
        ),
        Turn(
            id: "ja-fuji", question: "日本で一番高い山は何ですか？", expected: "ja",
            device: "en-US", clause: "The person is writing in Japanese: reply in Japanese."
        ),
        Turn(
            id: "ja-curry", question: "簡単なカレーの作り方を教えてください。", expected: "ja",
            device: "en-US", clause: "The person is writing in Japanese: reply in Japanese."
        ),
        Turn(
            id: "device-morning", question: "Guten Morgen!", expected: "de",
            device: "de-DE", clause: "This device is set to German: reply in German."
        ),
        Turn(
            id: "device-thanks", question: "Danke dir!", expected: "de",
            device: "de-DE", clause: "This device is set to German: reply in German."
        ),
    ]

    /// PROVISIONAL bar (2026-11-19, first run): the clause arm reads right on at least 80% of turns. Set before
    /// any measurement, to be moved by the record, not by one bad run.
    static let passBar = 0.8

    private static var paceMS: Int {
        max(0, replyLanguageEnvironment["M1K3_AFM_EVAL_PACE_MS"].flatMap(Int.init) ?? 20000)
    }

    static let budget = HistoryWindow.Budget(totalChars: 4000, perTurnChars: 1200, maxTurns: 8)

    /// The plain turn as `runPlainTurn` builds it on an empty history: identity, then the turn's clauses (the
    /// reply-language one last, nearest the question), then `plainTurnPrompt`.
    static func prompt(_ turn: Turn, withClause: Bool) -> String {
        let clause = withClause
            ? ReplyLanguage.clause(for: turn.question, earlierTurns: [], deviceLanguage: turn.device) : nil
        let preamble = [PromptContext.identity(brainName: "Mini"), clause].compactMap(\.self)
            .filter { !$0.isEmpty }.joined(separator: "\n\n")
        return AgentRAGResponder.plainTurnPrompt(
            question: turn.question, contextPreamble: preamble,
            chunks: [], memories: [], history: [], historyBudget: budget, ambient: nil, todos: nil
        )
    }

    struct Outcome {
        let text: String
        let read: String?
        let failure: AFMFailure?
        var unsupported: Bool {
            failure == .unsupportedLanguage
        }
    }

    /// One streamed turn, as the app streams it; an empty one is re-asked through `generate` for its error class.
    static func ask(_ prompt: String) async throws -> Outcome {
        let provider = AppleFoundationModelsProvider(instructions: { M1K3Persona.miniSystemPrompt })
        try #require(provider.isAvailable, "Apple Intelligence is not available to this process (modelNotReady?)")
        var stream = PlainTurnStream()
        var text = ""
        for await chunk in provider.generateStreaming(prompt: prompt) {
            if let clean = stream.ingest(chunk) { text = clean }
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines) == AFMFailure.unsupportedLanguageReply {
            return Outcome(text: text, read: nil, failure: .unsupportedLanguage)
        }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Outcome(text: text, read: ChatEvalScorer.replyLanguage(of: text), failure: nil)
        }
        try await Task.sleep(for: .milliseconds(paceMS))
        do {
            let again = try await provider.generate(prompt: prompt)
            return Outcome(text: again, read: ChatEvalScorer.replyLanguage(of: again), failure: nil)
        } catch {
            return Outcome(text: String(describing: error), read: nil, failure: AFMFailure.classify(error: error))
        }
    }

    @Test("ReplyLanguage gives each turn the clause it is meant to carry")
    func clausesAreTheAppsOwn() {
        for turn in Self.turns {
            #expect(
                ReplyLanguage.clause(for: turn.question, earlierTurns: [], deviceLanguage: turn.device)
                    == turn.clause, "\(turn.id)"
            )
        }
    }

    @Test("Mini answers in the person's language with the clause, paired against no clause")
    func pairedClauseOnOff() async throws {
        var paced = false
        var rightOn: [String: Int] = [:]
        var rightOff: [String: Int] = [:]
        var failures: [String] = []
        var misses: [String] = []
        for turn in Self.turns {
            for withClause in [true, false] {
                if paced { try await Task.sleep(for: .milliseconds(Self.paceMS)) }
                paced = true
                let arm = withClause ? "on" : "off"
                let started = ContinuousClock.now
                let outcome = try await Self.ask(Self.prompt(turn, withClause: withClause))
                let seconds = (ContinuousClock.now - started).components.seconds
                let pass = outcome.read == turn.expected
                if pass, withClause { rightOn[turn.expected, default: 0] += 1 }
                if pass, !withClause { rightOff[turn.expected, default: 0] += 1 }
                let flat = outcome.text.replacingOccurrences(of: "\n", with: " ⏎ ")
                let mark = outcome.failure.map { "FAIL(\($0.rawValue))" } ?? (pass ? "PASS" : "MISS")
                print("[replylang \(arm) \(turn.id)] \(seconds)s want=\(turn.expected) read=\(outcome.read ?? "nil")"
                    + " \(mark) :: \(flat.prefix(400))")
                if let failure = outcome.failure {
                    failures.append("\(arm) \(turn.id): \(failure.rawValue) :: \(flat.prefix(150))")
                } else if !pass {
                    misses.append("\(arm) \(turn.id) read=\(outcome.read ?? "nil") :: \(flat.prefix(150))")
                }
            }
        }
        let languages = ["de", "fr", "es", "pt", "ja"]
        for language in languages {
            let personTurns = Self.turns.filter { $0.expected == language && !$0.id.hasPrefix("device") }.count
            let device = Self.turns.filter { $0.expected == language && $0.id.hasPrefix("device") }
            let deviceOn = device.isEmpty ? "" : " (incl. \(device.count) device turns)"
            print("REPLYLANG \(language): off \(rightOff[language] ?? 0) · on \(rightOn[language] ?? 0)"
                + " of \(personTurns + device.count)\(deviceOn)")
        }
        let onTotal = rightOn.values.reduce(0, +)
        let offTotal = rightOff.values.reduce(0, +)
        print("REPLYLANG total: off \(offTotal)/\(Self.turns.count) · on \(onTotal)/\(Self.turns.count)")
        misses.forEach { print("REPLYLANG miss \($0)") }
        failures.forEach { print("REPLYLANG failure \($0)") }
        #expect(
            Double(onTotal) >= Self.passBar * Double(Self.turns.count),
            "clause arm \(onTotal)/\(Self.turns.count) is under the provisional \(Self.passBar) bar"
        )
    }
}
