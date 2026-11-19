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
//  Review: claude-opus-5-5, 2026-11-19 (challenger fold) — pins the three blind-set fixes on lines written here,
//  not the blind set's: a short foreign opener says nothing (and agreeing pieces keep their read), a two-line
//  paste is read by its shorter line, a CJK paste under an English question is English. Blind set 134 → 137/150,
//  0 wrong-language clauses. Confidence 0.75.
//  Review: claude-opus-5-5, 2026-11-19 (round 2, blind batch 2) — pins the reply-language allowlist (romanised text
//  read as Indonesian says nothing), the Arabizi guard and the digits it must not trip on, a native question over a
//  short English paste, the Latin opener line and the two-line weight rule that keep that from naming a wrong
//  language, and the comma split. Every line is new, none copied from a blind set. Confidence 0.75.
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
        let earlier = ["Hi there, quick question for you."]
        #expect(ReplyLanguage.clause(for: turn, earlierTurns: earlier, deviceLanguage: "de") == nil)
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
        let turn = "Wie hoch ist der höchste Berg Europas?"
        let german = try #require(ReplyLanguage.clause(for: turn, deviceLanguage: "en"))
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

    /// A short foreign opener on an English turn is a phrase being asked about, not the person's language: the
    /// pieces disagree, so the turn says nothing (challenger, 2026-11-19: a wrong "reply in X" is worse than none).
    @Test(arguments: [
        "Vielen herzlichen Dank — how do I say that properly? off to Munich soon",
        "Dankjewel allemaal — how formal is that? flying to Utrecht in June",
        "Tusen takk for hjelpen — how do I pronounce that? Bergen trip in July",
    ])
    func aShortForeignOpenerDoesNotPickTheLanguage(turn: String) {
        #expect(ReplyLanguage.detect(turn) == nil)
        #expect(ReplyLanguage.clause(for: turn, deviceLanguage: "en") == nil)
    }

    /// Every piece agreeing keeps the read: a German turn of several sentences is still German.
    @Test func aTurnWhosePiecesAgreeKeepsItsLanguage() {
        let turn = "Ich fahre im Mai nach München. Kannst du mir ein paar Museen empfehlen? Danke dir!"
        #expect(ReplyLanguage.detect(turn) == "de")
    }

    /// Two lettered lines leave no middle: the body is the longer line, so the short instruction under an English
    /// article is the one that differs (challenger, 2026-11-19).
    @Test func aTwoLinePasteIsReadByItsShorterLine() {
        let article = "The city council voted on Tuesday to expand the bike lane network across the downtown core, "
            + "citing a sharp rise in cycling commuters over the past two years and a drop in traffic injuries along "
            + "the pilot routes. Critics argued the plan would hurt local shops that rely on street parking."
        #expect(ReplyLanguage.detect(article + "\n\nPor favor, resume este artículo en tres frases.") == "es")
    }

    /// A CJK paste is long by letter weight, not by characters: under an English question it is the body, and the
    /// question is the instruction (challenger, 2026-11-19).
    @Test func aCJKPasteUnderAnEnglishQuestionIsEnglish() {
        let notice = "本大楼将于下周二上午九点至下午五点进行电梯年度检修，届时所有电梯将暂停使用。请住户提前安排出行，"
            + "如有不便敬请谅解。如需帮助，请联系物业服务中心，电话为八八六六五五四四。感谢各位业主的理解与配合，"
            + "祝大家生活愉快。另外，地下停车场的照明系统也将同步更换为节能灯具。"
        let turn = "Can you tell me what this notice from my building says?\n" + notice
        #expect(turn.count <= ReplyLanguage.pasteThreshold)
        #expect(ReplyLanguage.detect(turn) == "en")
        #expect(ReplyLanguage.clause(for: turn, deviceLanguage: "en") == nil)
    }

    /// The clause names only languages whose reads have proved reliable. Romanised Hindi, Japanese and Tagalog read
    /// as Indonesian with near certainty, so Indonesian, Malay and Tagalog are left out on purpose and an excluded
    /// read says nothing (blind batch 2, 2026-11-19).
    @Test(arguments: [
        "Bagaimana cara membuat nasi goreng yang enak di rumah?",
        "watashi wa ramen ga daisuki desu, oishii mise wo oshiete kudasai",
        "Ano ang magandang pasalubong para sa pamilya ko galing Japan?",
    ])
    func aReadOutsideTheAllowlistSaysNothing(turn: String) {
        #expect(ReplyLanguage.detect(turn) == nil)
        #expect(ReplyLanguage.clause(for: turn, deviceLanguage: "en") == nil)
    }

    @Test func theAllowlistKeepsTheMeasuredLanguages() {
        for code in ["en", "de", "fr", "es", "pt", "ja", "ar", "zh-Hans", "zh-Hant", "ko", "ru", "hi"] {
            #expect(ReplyLanguage.replyLanguages.contains(code), "\(code)")
        }
        for code in ["id", "ms", "tl", "ca"] {
            #expect(!ReplyLanguage.replyLanguages.contains(code), "\(code)")
        }
    }

    /// Arabizi writes Arabic letters as digits inside Latin words ("a3raf", "bta3y"): the recogniser reads it as
    /// Spanish or Polish, so a turn where a share of words carry a digit between letters says nothing.
    @Test func arabiziSaysNothing() {
        #expect(ReplyLanguage.detect("3ayza a3raf azay a7ot el sora 3ala el telefon bta3y") == nil)
        #expect(ReplyLanguage.detect("marhaba, 3andi so2al 3an el ta2meen el s7i") == nil)
    }

    /// Digits in an ordinary turn are not Arabizi: models, units and numeronyms keep the read.
    @Test(arguments: [
        ("Mein iPhone 15 lädt nicht mehr, was kann ich tun?", "de"),
        ("Ich habe 2 Fragen zu meinem 4K-Fernseher und der PS5.", "de"),
        ("Comment déployer k8s avec i18n dans mon projet ?", "fr"),
        ("Je cherche un job en B2B, tu peux relire mon CV ?", "fr"),
    ])
    func digitsInAnOrdinaryTurnKeepTheRead(turn: String, code: String) {
        #expect(ReplyLanguage.detect(turn) == code)
    }

    /// A native question above or below a short English paste is read by the question, not the paste: under the
    /// paste threshold the turn was read whole and the English won (blind batch 2: 14 of 15).
    @Test(arguments: [
        (
            "Что здесь написано? Это письмо от арендодателя\n\nDear tenant, the water will be shut off on Monday "
                + "from 9am to noon for pipe repairs. Please store some water in advance.",
            "ru"
        ),
        (
            "이 영어 문장 무슨 뜻이야?\n\nThe meeting has been moved to next Wednesday afternoon because the manager "
                + "is travelling.",
            "ko"
        ),
        (
            "Please return the signed form to the front office by the end of the month. Late forms cannot be "
                + "processed and will be sent back.\n\nこれはどういう意味ですか？",
            "ja"
        ),
    ])
    func aNativeQuestionOverAShortEnglishPasteIsTheQuestion(turn: String, code: String) {
        #expect(ReplyLanguage.detect(turn) == code)
    }

    /// The other way round stays English: an English question over a short foreign paste adds no clause.
    @Test func anEnglishQuestionOverAShortForeignPasteAddsNoClause() {
        let turn = "What does this German letter say?\n\nSehr geehrte Frau Murphy, wir möchten Sie darüber "
            + "informieren, dass Ihr Vertrag zum Ende des Monats ausläuft."
        #expect(ReplyLanguage.clause(for: turn, deviceLanguage: "en") == nil)
    }

    /// Two lines of similar weight could be either a question over a paste or a paste over a question, so neither
    /// wins: an English question a little heavier than the Arabic message it asks about is not Arabic (blind batch 2's
    /// round-2 fix gave such a turn "reply in Arabic"). The heavier line must at least double the other to be a paste.
    @Test func twoLinesOfSimilarWeightPickNoInstruction() {
        let turn = "my sister sent me this after the wedding, what does she mean\n\n"
            + "مبروك عليكم، الله يتمم بخير ويسعدكم يا رب"
        #expect(ReplyLanguage.clause(for: turn, deviceLanguage: "en") == nil)
    }

    /// A short Latin-script thank-you on its own line above an English question is an opener, not an instruction:
    /// the recogniser confuses Latin-script languages on a short line, so it never wins a short turn.
    @Test(arguments: [
        "Merci beaucoup!\nnow how do i export the spreadsheet as a pdf",
        "Vielen lieben Dank!\nnow can you help me write the cover letter",
        "Muchas gracias por la ayuda!\n\nnext question, how long do I rest the steak before slicing it",
    ])
    func aShortLatinOpenerLineDoesNotWin(turn: String) {
        #expect(ReplyLanguage.clause(for: turn, deviceLanguage: "en") == nil)
    }

    /// A comma splits pieces too: a foreign thank-you before a comma no longer outweighs the English after it.
    @Test(arguments: [
        "Muchas gracias por todo, can you remind me what we decided about the flights",
        "Vielen Dank nochmal, could you draft the reply to the landlord we talked about",
    ])
    func aForeignThanksBeforeACommaDoesNotPickTheLanguage(turn: String) {
        #expect(ReplyLanguage.detect(turn) == nil)
        #expect(ReplyLanguage.clause(for: turn, deviceLanguage: "en") == nil)
    }

    /// Commas inside one language keep the read.
    @Test func aTurnWithCommasInOneLanguageKeepsIt() {
        let turn = "Ich habe Hunger, aber der Kühlschrank ist leer, was soll ich heute kochen?"
        #expect(ReplyLanguage.detect(turn) == "de")
    }
}
