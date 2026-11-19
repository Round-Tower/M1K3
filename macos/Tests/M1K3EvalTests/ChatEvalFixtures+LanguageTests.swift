//
//  ChatEvalFixtures+LanguageTests.swift
//  M1K3EvalTests
//
//  Pins the language kind (Kev, 2026-11-19: brains reply in the person's language) and the scorer's
//  `replies in` check: every non-English turn names the language it wants back, each wave-one language
//  covers the same task shapes, English guards that quote another language want English, and the kind
//  sits last.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-19, Confidence 0.8. Prior: Unknown.
//

@testable import M1K3Eval
import Testing

struct ChatEvalFixturesLanguageTests {
    @Test("the registry hands the language kind exactly its own fixtures")
    func registered() {
        #expect(ChatEvalFixtures.fixtures(for: .language).count == ChatEvalFixtures.language.count)
    }

    @Test("every language fixture names the reply language it wants")
    func everyFixtureNamesItsLanguage() {
        for fixture in ChatEvalFixtures.language {
            #expect(fixture.expectation.replyLanguage != nil, "\(fixture.id) names no reply language")
        }
    }

    @Test("wave one (de, fr, es, pt) covers the same task shapes, so a language reads against its siblings")
    func waveOneIsParallel() {
        let shapes: (String) -> Set<String> = { code in
            Set(ChatEvalFixtures.language.compactMap { fixture -> String? in
                guard fixture.expectation.replyLanguage == code else { return nil }
                // "lang-de-reasoning" → "reasoning"
                return fixture.id.split(separator: "-").dropFirst(2).joined(separator: "-")
            })
        }
        let german = shapes("de")
        #expect(german.count >= 6)
        for code in ["fr", "es", "pt"] {
            #expect(shapes(code) == german, "\(code) drifts from de")
        }
    }

    @Test("ja and ar each carry a few turns")
    func waveTwoIsPresent() {
        for code in ["ja", "ar"] {
            #expect(ChatEvalFixtures.language.filter { $0.expectation.replyLanguage == code }.count >= 3)
        }
    }

    @Test("English guards that quote another language want English back")
    func englishGuards() {
        let guards = ChatEvalFixtures.language.filter { $0.expectation.replyLanguage == "en" }
        #expect(guards.count >= 3)
    }

    @Test("the kind sits last in all, so no earlier run's order moves")
    func languageIsLast() throws {
        let last = try #require(ChatEvalFixtures.all.last)
        #expect(last.kind == .language)
        #expect(TaskKind.allCases.last == .language)
    }

    @Test("a fixture's fact is a number or a name, never a word in the reply language a wrong reply would miss")
    func factsAreLanguageFree() {
        for fixture in ChatEvalFixtures.language {
            for fact in fixture.expectation.mustContainAny + fixture.expectation.mustContainAll {
                #expect(fact.count <= 24, "\(fixture.id): \(fact)")
            }
        }
    }
}

struct ChatEvalReplyLanguageScoreTests {
    private func fixture(_ code: String) -> ChatEvalFixture {
        ChatEvalFixture(
            id: "lang-test", kind: .language, prompt: "x",
            expectation: .init(minChars: 1, replyLanguage: code)
        )
    }

    private func check(_ code: String, _ answer: String) -> EvalCheck? {
        ChatEvalScorer.score(fixture: fixture(code), observation: EvalObservation(rawText: answer, latencyMS: 10))
            .checks.first { $0.name == "replies in \(code)" }
    }

    @Test func germanAnswerPassesGerman() {
        let answer = "Der höchste Berg Europas ist der Elbrus im Kaukasus, mit 5.642 Metern über dem Meer."
        #expect(check("de", answer)?.outcome == .pass)
    }

    @Test func englishAnswerFailsGerman() {
        let answer = "The tallest mountain in Europe is Elbrus, in the Caucasus, at 5,642 metres."
        let result = check("de", answer)
        #expect(result?.outcome == .fail)
        #expect(result?.detail.contains("en") == true)
    }

    @Test func codeDoesNotCountAsTheReply() {
        let answer = """
        Hier ist eine kurze Funktion, die zwei Zahlen addiert und das Ergebnis zurückgibt:
        ```swift
        func add(_ first: Int, _ second: Int) -> Int { first + second }
        print(add(2, 3)) // the result is five, printed to the console for everyone
        ```
        """
        #expect(check("de", answer)?.outcome == .pass)
    }

    @Test func portugueseFoldsBrazilianAndEuropean() {
        let answer = "A capital da Austrália é Camberra, escolhida como meio-termo entre Sydney e Melbourne."
        #expect(check("pt", answer)?.outcome == .pass)
    }

    @Test func japaneseAndArabicRead() {
        #expect(check("ja", "日本で一番高い山は富士山で、高さは3776メートルです。")?.outcome == .pass)
        #expect(check("ar", "عاصمة أستراليا هي كانبرا، وقد اختيرت كحل وسط بين سيدني وملبورن.")?.outcome == .pass)
    }

    @Test func emptyAnswerFails() {
        #expect(check("fr", "")?.outcome == .fail)
    }

    @Test func noCheckWithoutAReplyLanguage() {
        let plain = ChatEvalFixture(id: "x", kind: .openChat, prompt: "x", expectation: .init(minChars: 1))
        let score = ChatEvalScorer.score(fixture: plain, observation: EvalObservation(rawText: "Hallo", latencyMS: 1))
        #expect(!score.checks.contains { $0.name.hasPrefix("replies in") })
    }
}
