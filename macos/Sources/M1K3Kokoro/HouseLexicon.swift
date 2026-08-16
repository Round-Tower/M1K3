//
//  HouseLexicon.swift
//  M1K3Kokoro
//
//  Hand-authored en-GB pronunciations for the words M1K3 says constantly and
//  the bundled dictionary doesn't know — the maker's name, the places and
//  products of this app's own life. Letter-to-sound could guess most of them,
//  but identity words deserve EXACT pronunciations (and "Aoife" proves the
//  point: no English letter rule survives Irish).
//
//  IPA is parsed through KokoroPhonemeMap; an entry whose IPA doesn't fully
//  map is dropped at lookup (fail-closed), and HouseLexiconTests speaks every
//  entry through the real bundled pipeline so a bad entry turns the suite red.
//
//  "M1K3" → "Mike": the kill-or-commit-Mike branding question was COMMITTED
//  (Kev, 2026-08-16) — the visual brand stays M1K3, the voice says the name
//  the leet always encoded. Reverting is deleting two entries.
//
//  Signed: Kev + claude-fable-5, 2026-08-16, Confidence 0.85 (every entry
//  spoken through the bundled pipeline in tests; the accent of each guess is
//  verify-by-ear). Prior: Unknown.
//

import Foundation

/// word (lowercase) → IPA. Consulted after the dictionary, before inflection.
public enum HouseLexicon {
    public static let entries: [String: String] = [
        "kev": "kˈɛv",
        "kevin": "kˈɛvɪn",
        "ardmore": "ˈɑːdmɔː",
        "kokoro": "kəkˈɔːɹəʊ",
        "qwen": "kwˈɛn",
        "aoife": "ˈiːfə",
        "murphysig": "mˈɜːfisˌɪg",
        "lexy": "lˈɛksi",
        // ★ The kill-or-commit-Mike ruling: COMMITTED (Kev, 2026-08-16). Text
        // stays M1K3 — the voice says the name the leet always encoded. The
        // digit branch consults the house lexicon for exactly this pair.
        "m1k3": "mˈaɪk",
        "m1k3's": "mˈaɪks",
    ]

    /// Tokens for a word, if it's ours. nil for everyone else.
    public static func tokens(for word: String) -> [Int]? {
        entries[word].flatMap { KokoroPhonemeMap.tokens(for: $0) }
    }
}
