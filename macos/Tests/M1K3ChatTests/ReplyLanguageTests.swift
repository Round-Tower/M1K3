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
//  Review: claude-opus-5-5, 2026-11-19 (pre-push review fold) — pins the three closed false positives (a short
//  English turn mid-chat on a German device, a short frame beside a quote, a paste outweighing its instruction),
//  kana as Japanese, and the zh-TW / und tags.
//

import Foundation
@testable import M1K3Chat
import Testing

struct ReplyLanguageTests {
    /// The resolved code alone.
    private func code(_ turn: String, earlier: [String] = [], device: String?) -> String? {
        ReplyLanguage.resolve(turn: turn, earlierTurns: earlier, deviceLanguage: device)?.code
    }

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
        #expect(ReplyLanguage.clause(for: turn, deviceLanguage: "en") == nil)
        #expect(ReplyLanguage.clause(for: turn, earlierTurns: ["Hi there, quick question for you."], deviceLanguage: "de") == nil)
    }

    /// A short frame beside a quote is unreadable, never read as the quote (pre-push review, 2026-11-19).
    @Test func shortFrameBesideAQuoteIsNotTheQuote() {
        #expect(ReplyLanguage.detect("Translate 'Wo ist der Bahnhof, bitte?'") == nil)
        #expect(ReplyLanguage.clause(for: "Translate 'Wo ist der Bahnhof, bitte?'", deviceLanguage: "en") == nil)
        #expect(ReplyLanguage.detect("Was bedeutet eigentlich das Wort 'Hello' auf Deutsch?") == "de")
    }

    /// Too short to read, first turn of a chat: the device's language answers. "ok" on a German Mac wants German.
    @Test(arguments: ["ok", "danke", "merci!", "👍", "42", ""])
    func shortFirstTurnFallsBackToTheDevice(turn: String) {
        #expect(ReplyLanguage.detect(turn) == nil)
        #expect(code(turn, device: "de") == "de")
        #expect(code(turn, device: nil) == nil)
    }

    /// Mid-chat, a short turn keeps the person's last readable language, never the device's: an English speaker on
    /// a German Mac who types "thanks, got it" stays in English (pre-push review, 2026-11-19).
    @Test func shortTurnMidChatCarriesThePersonsLanguage() {
        let english = ["Can you explain how photosynthesis works?"]
        #expect(code("thanks, got it", earlier: english, device: "de") == "en")
        #expect(ReplyLanguage.clause(for: "thanks, got it", earlierTurns: english, deviceLanguage: "de") == nil)
        let german = ["Wie hoch ist der höchste Berg Europas?", "ok"]
        #expect(code("danke!", earlier: german, device: "en") == "de")
        // Nothing readable earlier and not the first turn: say nothing, the history speaks for itself.
        #expect(code("ok", earlier: ["hm", "ja"], device: "de") == nil)
    }

    /// A long paste is read by its instruction line, both ways round (pre-push review, 2026-11-19).
    @Test func aPasteIsReadByItsInstruction() {
        let englishBody = String(
            repeating: "The quarterly figures show steady growth across every region we operate in.\n", count: 6
        )
        let germanBody = String(
            repeating: "Die Quartalszahlen zeigen ein stetiges Wachstum in allen Regionen, in denen wir tätig sind.\n",
            count: 6
        )
        #expect(ReplyLanguage.detect("Fasse das bitte kurz zusammen:\n" + englishBody) == "de")
        #expect(ReplyLanguage.detect("Please summarise this email for me:\n" + germanBody) == "en")
        #expect(ReplyLanguage.detect(englishBody + "Kannst du das bitte übersetzen?") == "de")
    }

    /// A kanji-heavy Japanese line with kana is Japanese, whatever the recogniser leans to.
    @Test func kanaIsJapanese() {
        #expect(ReplyLanguage.detect("東京都庁の所在地は新宿区です。") == "ja")
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
        #expect(code("Peux-tu m'expliquer comment fonctionne la photosynthèse ?", device: "en") == "fr")
        #expect(code("Can you explain how photosynthesis works?", device: "de") == "en")
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
        #expect(code("", device: "en-GB") == "en")
        #expect(code("", device: "pt-BR") == "pt")
        #expect(code("", device: "zh-Hans-CN") == "zh-Hans")
        #expect(code("", device: "zh-TW") == "zh-Hant")
        #expect(code("", device: "zh-HK") == "zh-Hant")
        #expect(code("", device: "zh-CN") == "zh-Hans")
        #expect(code("", device: "und") == nil)
    }
}
