//
//  SpokenLanguageTests.swift
//  M1K3VoiceTests
//
//  The language an answer is SPOKEN in (2026-11-20): brains now reply in the person's language (#870) and Kokoro's
//  G2P is English, so a non-English answer is routed to the on-device synth. English is sticky (a quoted foreign
//  phrase stays on Kokoro), the call is made once per answer, and the English path is byte-identical.
//
//  Signed: claude-opus-5-5, 2026-11-20, Confidence 0.7 (the recogniser is Apple's; the 40-letter / 0.8 bar is
//  pinned on these lines, not yet measured on a blind set). Prior: Unknown
//

import Foundation
@testable import M1K3Voice
import Testing

struct SpokenLanguageTests {
    static let german = "Die Hauptstadt von Frankreich ist Paris, und sie liegt an der Seine im Norden des Landes."
    static let english = "The capital of France is Paris, and it sits on the Seine in the north of the country."

    @Test("English stays English")
    func englishStays() {
        #expect(SpokenLanguage.decide(text: Self.english) == "en")
    }

    @Test("a long confident German answer switches an English seed")
    func germanSwitches() {
        #expect(SpokenLanguage.decide(text: Self.german) == "de")
    }

    @Test("an English answer quoting 'Guten Morgen' stays English")
    func quotedPhraseStays() {
        let text = "In German you greet someone in the morning by saying 'Guten Morgen', which means good morning."
        #expect(SpokenLanguage.decide(text: text) == "en")
    }

    @Test("short text stays on the seed")
    func shortStays() {
        #expect(SpokenLanguage.decide(text: "Danke schön, bis bald.") == "en")
        #expect(SpokenLanguage.decide(text: "") == "en")
    }

    @Test("the latch decides once per answer and never flips mid-answer")
    func latchHolds() {
        let latch = SpokenAnswerLanguage()
        #expect(latch.current == "en")
        latch.observe("Kurz.")
        #expect(latch.current == "en")
        latch.observe(Self.german)
        #expect(latch.current == "de")
        latch.observe(Self.english + " " + Self.english + " " + Self.english)
        #expect(latch.current == "de")
        latch.begin()
        #expect(latch.current == "en")
        latch.observe(Self.english)
        latch.observe(Self.german + Self.german + Self.german)
        #expect(latch.current == "en")
    }

    /// Review fold (2026-11-20): a German answer opens "Klar!" and the 40-letter latch had not decided, so the first
    /// sentence went out in Kokoro's English. The person's own language seeds the answer.
    @Test("a German seed starts the answer German from its first, short sentence")
    func seededAnswerStartsInItsLanguage() {
        let latch = SpokenAnswerLanguage()
        latch.begin(seed: "de")
        #expect(latch.current == "de")
        latch.observe("Klar!")
        #expect(latch.current == "de")
        latch.observe(Self.german)
        #expect(latch.current == "de")
    }

    @Test("a German seed yields to an answer that is clearly English, then holds")
    func seedYieldsToAClearlyEnglishAnswer() {
        let latch = SpokenAnswerLanguage()
        latch.begin(seed: "de")
        latch.observe(Self.english)
        #expect(latch.current == "en")
        latch.observe(Self.german + " " + Self.german)
        #expect(latch.current == "en")
    }

    @Test("a non-English seed decides on the seed's floors; English tags are English")
    func nonEnglishSeedDecides() {
        #expect(SpokenLanguage.decide(seed: "de", text: Self.english) == "en")
        #expect(SpokenLanguage.decide(seed: "de", text: "Ok.") == "de")
        #expect(SpokenLanguage.isEnglish("en-GB"))
        #expect(SpokenLanguage.isEnglish("EN_us"))
        #expect(!SpokenLanguage.isEnglish("de-DE"))
    }

    @Test("voice choice prefers the language's own region: pt-BR for pt, mainland Mandarin for zh-Hans")
    func voiceChoiceByRegion() {
        let voices = [
            SystemVoiceCandidate(identifier: "pt.pt.premium", language: "pt-PT", quality: .premium),
            SystemVoiceCandidate(identifier: "pt.br.compact", language: "pt-BR", quality: .compact),
            SystemVoiceCandidate(identifier: "zh.hk.premium", language: "zh-HK", quality: .premium),
            SystemVoiceCandidate(identifier: "zh.cn.enhanced", language: "zh-CN", quality: .enhanced),
            SystemVoiceCandidate(identifier: "zh.tw.compact", language: "zh-TW", quality: .compact),
        ]
        #expect(BestSystemVoice.voice(forLanguage: "pt", voices: voices) == "pt.br.compact")
        #expect(BestSystemVoice.voice(forLanguage: "pt-BR", voices: voices) == "pt.br.compact")
        #expect(BestSystemVoice.voice(forLanguage: "zh-Hans", voices: voices) == "zh.cn.enhanced")
        #expect(BestSystemVoice.voice(forLanguage: "zh-Hant", voices: voices) == "zh.tw.compact")
        // No voice in the preferred region: the language's best voice.
        let europeanOnly = [SystemVoiceCandidate(identifier: "pt.pt.premium", language: "pt-PT", quality: .premium)]
        #expect(BestSystemVoice.voice(forLanguage: "pt", voices: europeanOnly) == "pt.pt.premium")
    }

    @Test("the person's own region first when a voice exists for it, else the language's home region")
    func voiceChoiceByPersonsRegion() {
        let voices = [
            SystemVoiceCandidate(identifier: "fr.ca", language: "fr-CA", quality: .compact),
            SystemVoiceCandidate(identifier: "fr.fr", language: "fr-FR", quality: .compact),
            SystemVoiceCandidate(identifier: "es.es", language: "es-ES", quality: .compact),
            SystemVoiceCandidate(identifier: "es.mx", language: "es-MX", quality: .compact),
        ]
        #expect(BestSystemVoice.voice(forLanguage: "fr", voices: voices, personRegion: "CA") == "fr.ca")
        #expect(BestSystemVoice.voice(forLanguage: "fr", voices: voices, personRegion: "IE") == "fr.fr")
        #expect(BestSystemVoice.voice(forLanguage: "es", voices: voices, personRegion: "MX") == "es.mx")
        #expect(BestSystemVoice.voice(forLanguage: "es", voices: voices, personRegion: nil) == "es.es")
    }

    @Test("the utterance carries the language and the best installed voice")
    func utteranceCarriesVoice() {
        let voices = [
            SystemVoiceCandidate(identifier: "de.compact", language: "de-DE", quality: .compact),
            SystemVoiceCandidate(identifier: "de.premium", language: "de-DE", quality: .premium),
            SystemVoiceCandidate(identifier: "de.enhanced", language: "de-DE", quality: .enhanced),
        ]
        let utterance = SpokenVoice.utterance(text: "Hallo", mood: .neutral, language: "de", voices: voices)
        #expect(utterance.language == "de")
        #expect(utterance.voiceIdentifier == "de.premium")
    }

    @Test("quality ranks premium > enhanced > compact, never eloquence, never another language")
    func voiceByQuality() {
        let voices = [
            SystemVoiceCandidate(identifier: "com.apple.eloquence.de-DE.Eddy", language: "de-DE", quality: .compact),
            SystemVoiceCandidate(identifier: "fr.premium", language: "fr-FR", quality: .premium),
            SystemVoiceCandidate(identifier: "de.compact", language: "de-DE", quality: .compact),
        ]
        #expect(BestSystemVoice.voice(forLanguage: "de", voices: voices) == "de.compact")
        #expect(BestSystemVoice.voice(forLanguage: "es", voices: voices) == nil)
        #expect(BestSystemVoice.voice(forLanguage: "zh-Hans", voices: voices) == nil)
    }

    @Test("English, nil, or no installed voice: the utterance is byte-identical to today's")
    func englishUnchanged() {
        let voices = [SystemVoiceCandidate(identifier: "de.premium", language: "de-DE", quality: .premium)]
        let today = SpeechUtterance(text: "Hello", mood: .happy)
        #expect(SpokenVoice.utterance(text: "Hello", mood: .happy, language: "en", voices: voices) == today)
        #expect(SpokenVoice.utterance(text: "Hello", mood: .happy, language: nil, voices: voices) == today)
        #expect(SpokenVoice.utterance(text: "Bonjour", mood: .happy, language: "fr", voices: voices)
            == SpeechUtterance(text: "Bonjour", mood: .happy))
    }
}

/// Review fold (2026-11-20): tool narration and the persona refusal ride the same speak lane as the answer, and the
/// lane read the answer's language at speak time, so "Checking the web." after a German answer had latched came out
/// in the German voice. A fixed English line is spoken in English whatever the answer's language.
struct SpokenChunkLanguageTests {
    @Test("tool narration is English whatever the answer latched")
    func narrationStaysEnglish() {
        for tool in ["web_search", "datetime", "recent_activity"] {
            let line = ToolNarration.phrase(forTool: tool)
            #expect(SpokenLanguage.language(forChunk: line, answerLanguage: "de") == SpokenLanguage.seed, "\(line)")
        }
    }

    @Test("a caller's fixed English line (the persona refusal) is English")
    func fixedLinesStayEnglish() {
        let refusal = "I keep my wiring to myself."
        #expect(SpokenLanguage.language(forChunk: refusal, answerLanguage: "fr", fixedEnglish: [refusal]) == "en")
    }

    @Test("an answer sentence follows the answer's language")
    func answerFollowsTheLatch() {
        #expect(SpokenLanguage.language(forChunk: "Die Dichtung ist ausgefallen.", answerLanguage: "de") == "de")
        #expect(SpokenLanguage.language(forChunk: "Checking the web, as asked.", answerLanguage: "de") == "de")
    }

    @Test("a page-command reply comes from the catalog, so it speaks the interface's language")
    func pageRepliesSpeakTheInterfaceLanguage() {
        #expect(SpokenLanguage.interfaceLanguage(["de"]) == "de")
        #expect(SpokenLanguage.interfaceLanguage(["pt-BR", "en"]) == "pt-BR")
        #expect(SpokenLanguage.interfaceLanguage(["en-GB"]) == SpokenLanguage.seed)
        #expect(SpokenLanguage.interfaceLanguage(["Base"]) == SpokenLanguage.seed)
        #expect(SpokenLanguage.interfaceLanguage([]) == SpokenLanguage.seed)
    }

    @Test("narration is recognised exactly, never by a prefix inside an answer")
    func narrationIsExact() {
        #expect(ToolNarration.isNarration("Checking the web."))
        // An unknown tool's humanised "Using x." can't be told from an answer sentence, so it is not claimed.
        #expect(!ToolNarration.isNarration("Using some new tool."))
        #expect(!ToolNarration.isNarration("Checking the web. Then I found it."))
        #expect(!ToolNarration.isNarration("Using a ladder is safer."))
    }
}
