//
//  SpeechLocalePolicy.swift
//  M1K3Voice
//
//  Which language the Apple recogniser listens in. `AppleSpeechTranscriber` defaults to
//  `Locale.current`, and `Locale.current` follows the app's language: while M1K3 shipped in
//  English only, a German Mac read `en_DE`; once the interface ships in German it reads `de_DE`.
//  Voice is still English end to end (the store says "the interface and voice are in English
//  for now"; Kokoro, the barge-in / endpoint / completeness word lists and the voice evals are
//  English), so a translated interface must not move the ear. English locales pass through
//  untouched; any other language listens in the region's English when the recogniser has one,
//  else US English.
//
//  Lifting this is the plan's Phase 2 speech work (2026-11-18 §3): reserve the speech
//  locale, gate the word lists by language, send non-English replies to the Built-in voice.
//
//  Signed: claude-opus-5-5, 2026-11-20, Confidence 0.85 (pure and pinned; the region-English
//  match leans on `SFSpeechRecognizer.supportedLocales`, which SpeechAnalyzer's own
//  `supportedLocale(equivalentTo:)` then narrows). Prior: none (new file, localisation wave one).

import Foundation
import Speech

public enum SpeechLocalePolicy {
    /// The locale the recogniser listens in, from the app's `current` locale and the
    /// recogniser's `supported` identifiers (either separator).
    public static func recognitionLocale(current: Locale, supported: Set<String>) -> Locale {
        if current.language.languageCode == .english { return current }
        let normalised = Set(supported.map { $0.replacingOccurrences(of: "-", with: "_") })
        if let region = current.region?.identifier, normalised.contains("en_\(region)") {
            return Locale(identifier: "en_\(region)")
        }
        return Locale(identifier: "en_US")
    }

    /// `recognitionLocale` for this process: the app's locale and the system recogniser's list.
    public static var forThisApp: Locale {
        recognitionLocale(
            current: .current,
            supported: Set(SFSpeechRecognizer.supportedLocales().map(\.identifier))
        )
    }
}
