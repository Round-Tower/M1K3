//
//  PoliteEndpoint.swift
//  M1K3Voice
//
//  "Please" is the spoken submit button (Kev, 2026-08-13): instead of an
//  "over and out" protocol, ending your turn on the word please tells M1K3
//  you're done, and the endpointer takes its turn on the short polite window
//  rather than the conversational silence/hold/learned-cadence waits.
//
//  An ACCELERATOR, never a requirement — silence endpointing works exactly as
//  before when the word is absent (the 2026-07-29 hot-word verdict, now
//  Kev-requested). Whole-word, trailing-position only: a mid-sentence please
//  ("please tell me…") is ordinary politeness, and "pleased" must never submit.
//  The deliberate edge: "can you please" <pause> submits — that is the contract
//  the UI teaches ("M1K3 will take its turn after you say please"), so the
//  behaviour follows the promise, not a guess about intent.
//
//  Signed: Kev + claude-fable-5, 2026-08-13, Confidence 0.85 (pure and pinned;
//  the felt beat of the 1s polite window is Kev's to settle). Prior: Unknown.
//  Review: claude-opus-5-5, 2026-11-19 — localisation: `uiHint` resolves from M1K3Voice's catalog with the
//  submit word filled in as `%@` from `submitWord` (English in every language: the listener matches it);
//  `isSubmit` reads the same constant. English unchanged.
//  Review: claude-opus-5-5, 2026-11-19 — review fold: the "listener only hears English" premise was false. Both
//  shells build `AppleSpeechTranscriber()` bare, whose locale defaults to `Locale.current`, which can follow the
//  app's language once a translation ships. So the submit word is per-locale: `localizedSubmitWord` (catalog key
//  "please") is what `uiHint` teaches, and `isSubmit` matches it OR the English `submitWord` (WhisperKit, or a
//  recogniser still in English, keeps working). English unchanged: the en value of "please" is "please".
//  Review: claude-opus-5-5, 2026-11-20 — localisation wave one pins the recogniser to English (`SpeechLocalePolicy`),
//  so the catalog marks "please" do-not-translate and every language's hint teaches the English word the ear hears.
//  `localizedSubmitWord` stays, for the day speech follows the interface (Phase 2).

import Foundation

/// Pure trailing-word check: does this live partial end on the submit word?
public enum PoliteEndpoint {
    /// The one hint both shells show while listening — shared for the same
    /// anti-drift reason as `EndpointCadence`: the Mac and iOS copies of a
    /// user-facing literal agree until someone edits one of them.
    /// Display-only (both voice screens). The quoted word is `localizedSubmitWord`, the word
    /// `isSubmit` listens for in the app's language.
    public static var uiHint: String {
        String(
            localized: "End with “\(localizedSubmitWord)” and M1K3 will take its turn",
            bundle: .module,
            comment: "Voice mode hint while listening. %@ is the spoken submit word, already translated (the key “please” in this catalog). Use this language's quotation marks."
        )
    }

    /// The English spoken submit word. Always matched, whatever the app's language: WhisperKit
    /// and an English recogniser hear English.
    public static let submitWord = "please"

    /// The submit word the hint teaches, from M1K3Voice's catalog. While the recogniser is pinned to
    /// English (`SpeechLocalePolicy`, localisation wave one) the key is do-not-translate, so this is
    /// "please" in every language; it becomes the language's own word when speech follows the interface.
    public static var localizedSubmitWord: String {
        String(
            localized: "please",
            bundle: .module,
            comment: "Spoken word that ends a voice turn (“tell me a story, please”). Not translated while speech recognition is pinned to English (SpeechLocalePolicy): the recogniser hears English, so the hint must teach the English word."
        )
    }

    /// `localizedSubmitWord` in match form, resolved once (the endpointer asks on every partial).
    private static let localizedMatch = localizedSubmitWord.lowercased().trimmingCharacters(in: edgeTrim)

    public static func isSubmit(_ text: String) -> Bool {
        let lastWord = text
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .last
            .map { $0.lowercased().trimmingCharacters(in: edgeTrim) } ?? ""
        guard !lastWord.isEmpty else { return false }
        return lastWord == submitWord || lastWord == localizedMatch
    }

    /// Punctuation peeled off the final word ("please." / "please!" / ", please").
    private static let edgeTrim = CharacterSet.letters.inverted
}
