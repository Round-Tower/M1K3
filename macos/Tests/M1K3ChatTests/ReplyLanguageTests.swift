//
//  ReplyLanguageTests.swift
//  M1K3ChatTests
//
//  Pins the per-turn reply-language read (Kev, 2026-11-19: "Brains need to reply in the users language"):
//  a turn long enough to read sets the language, a short one falls back to the device's, and English
//  adds nothing, so an English prompt stays byte for byte what it was.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-19, Confidence 0.75 (the recogniser is Apple's; the floors are
//  set on these lines, and the chateval language kind is the measure). Prior: Unknown
//

import Foundation
@testable import M1K3Chat
import Testing

struct ReplyLanguageTests {
    @Test(arguments: [
        ("Wie hoch ist der höchste Berg Europas?", "de"),
        ("Peux-tu m'expliquer comment fonctionne la photosynthèse ?", "fr"),
        ("¿Cuántos días tiene un año bisiesto?", "es"),
        ("Qual é a capital da Austrália e por que não é Sydney?", "pt"),
        ("日本で一番高い山は何ですか？", "ja"),
        ("ما هي عاصمة أستراليا؟", "ar"),
        ("Can you explain how photosynthesis works?", "en"),
    ])
    func readsALongEnoughTurn(turn: String, code: String) {
        #expect(ReplyLanguage.detect(turn) == code)
    }

    /// An English turn that quotes another language is still English.
    @Test(arguments: [
        "What does Schadenfreude mean?",
        "How do I say 'good morning' in French?",
        "Translate 'Wo ist der Bahnhof?' into English please",
    ])
    func englishTurnQuotingAnotherLanguageStaysEnglish(turn: String) {
        #expect(ReplyLanguage.resolve(turn: turn, deviceLanguage: "en") == "en")
    }

    /// Too short to read: the device's language answers. "ok" on a German Mac wants German back.
    @Test(arguments: ["ok", "danke", "merci!", "👍", "42", ""])
    func shortTurnFallsBackToTheDevice(turn: String) {
        #expect(ReplyLanguage.detect(turn) == nil)
        #expect(ReplyLanguage.resolve(turn: turn, deviceLanguage: "de") == "de")
        #expect(ReplyLanguage.resolve(turn: turn, deviceLanguage: nil) == nil)
    }

    /// Apostrophes inside words are not quotes: the French elision and the English contraction stay read.
    @Test func apostrophesInsideWordsAreNotQuotes() {
        #expect(ReplyLanguage.detect("Je n'ai pas compris l'explication, tu peux recommencer ?") == "fr")
        #expect(ReplyLanguage.withoutQuotes("I don't know what 'Hallo' means") == "I don't know what   means")
    }

    /// A turn that is only a quote is still read: nothing else is there to say whose language it is.
    @Test func aTurnThatIsOnlyAQuoteIsRead() {
        #expect(ReplyLanguage.detect("„Wo ist der Bahnhof, bitte? Ich finde ihn nicht.“") == "de")
    }

    /// Code and links say nothing about the person's language: a German question about Swift is German.
    @Test func codeAndLinksAreNotRead() {
        let turn = """
        Warum stürzt dieser Code ab? https://example.com/docs
        ```swift
        let value = dictionary["key"]!
        print(value.count)
        ```
        """
        #expect(ReplyLanguage.detect(turn) == "de")
    }

    @Test func englishAddsNoClause() {
        #expect(ReplyLanguage.clause(for: "What's the tallest mountain in Europe?", deviceLanguage: "en") == nil)
        #expect(ReplyLanguage.clause(for: "ok", deviceLanguage: "en-GB") == nil)
        #expect(ReplyLanguage.clause(for: "ok", deviceLanguage: nil) == nil)
    }

    @Test func clauseNamesTheLanguageInEnglish() throws {
        let german = try #require(ReplyLanguage.clause(for: "Wie hoch ist der höchste Berg Europas?", deviceLanguage: "en"))
        #expect(german.contains("German"))
        let portuguese = try #require(ReplyLanguage.clause(for: "ok", deviceLanguage: "pt-BR"))
        #expect(portuguese.contains("Portuguese"))
        #expect(portuguese.contains("device"))
    }

    /// The turn's language beats the device's when the turn is readable: a French speaker on an English Mac.
    @Test func turnBeatsTheDevice() {
        #expect(ReplyLanguage.resolve(
            turn: "Peux-tu m'expliquer comment fonctionne la photosynthèse ?", deviceLanguage: "en"
        ) == "fr")
        #expect(ReplyLanguage.resolve(turn: "Can you explain how photosynthesis works?", deviceLanguage: "de") == "en")
    }

    /// The shells' switch: on when unset, off on NO (the A/B's argv override).
    @Test func liveClauseHonoursTheSwitch() throws {
        let suite = "ReplyLanguageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let german = "Wie hoch ist der höchste Berg Europas?"
        #expect(ReplyLanguage.liveClause(for: german, defaults: defaults)?.contains("German") == true)
        defaults.set(false, forKey: ReplyLanguage.enabledKey)
        #expect(ReplyLanguage.liveClause(for: german, defaults: defaults) == nil)
    }

    /// Region and script tags fold to the language: en-GB is English, pt-BR is Portuguese.
    @Test func deviceTagsFoldToTheLanguage() {
        #expect(ReplyLanguage.resolve(turn: "", deviceLanguage: "en-GB") == "en")
        #expect(ReplyLanguage.resolve(turn: "", deviceLanguage: "pt-BR") == "pt")
        #expect(ReplyLanguage.resolve(turn: "", deviceLanguage: "zh-Hans-CN") == "zh-Hans")
    }
}
