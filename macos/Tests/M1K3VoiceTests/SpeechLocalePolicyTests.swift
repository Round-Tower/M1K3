//
//  SpeechLocalePolicyTests.swift
//  M1K3VoiceTests
//
//  Wave one of the interface translation (de, fr, es, pt-BR) must not move speech: the store
//  says "the interface and voice are in English for now", and the voice word lists, Kokoro
//  and the voice evals are English. A translated app makes `Locale.current` German for a
//  German Mac, and the recogniser follows `Locale.current`, so the policy pins it to English.
//
//  Signed: claude-opus-5-5, 2026-11-20, Confidence 0.85. Prior: none (new file).

import Foundation
@testable import M1K3Voice
import Testing

struct SpeechLocalePolicyTests {
    private let supported: Set<String> = ["en-US", "en-GB", "en-IE", "en-AU", "en-IN", "en-CA", "de-DE", "fr-FR"]

    @Test("an English locale is untouched, region and all")
    func englishUnchanged() {
        for id in ["en_IE", "en_GB", "en_US", "en_IN"] {
            let locale = SpeechLocalePolicy.recognitionLocale(current: Locale(identifier: id), supported: supported)
            #expect(locale.identifier == id)
        }
    }

    @Test("a translated app keeps listening in English: the region's English where it exists")
    func translatedAppListensInEnglish() {
        let canada = SpeechLocalePolicy.recognitionLocale(current: Locale(identifier: "fr_CA"), supported: supported)
        #expect(canada.identifier == "en_CA")
        let india = SpeechLocalePolicy.recognitionLocale(current: Locale(identifier: "es_IN"), supported: supported)
        #expect(india.identifier == "en_IN")
    }

    @Test("no English for the region: US English, never the UI language")
    func fallsBackToUSEnglish() {
        for id in ["de_DE", "fr_FR", "pt_BR", "es_MX", "de"] {
            let locale = SpeechLocalePolicy.recognitionLocale(current: Locale(identifier: id), supported: supported)
            #expect(locale.identifier == "en_US", "\(id) -> \(locale.identifier)")
        }
    }

    @Test("supported identifiers match whichever separator the system uses")
    func separatorAgnostic() {
        let locale = SpeechLocalePolicy.recognitionLocale(current: Locale(identifier: "de_IE"), supported: ["en_IE"])
        #expect(locale.identifier == "en_IE")
    }
}
