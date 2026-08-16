//
//  KokoroPhonemeMap.swift
//  M1K3Kokoro
//
//  IPA character → Kokoro vocab token id, for pronunciations we author
//  ourselves (the house lexicon + the letter-to-sound fallback). The bundled
//  misaki dictionary ships only word→ids, so this table was DERIVED empirically
//  (2026-08-16): 60+ anchor words with textbook en-GB pronunciations were read
//  out of the real bundled dictionary and aligned character-by-character
//  (e.g. "cat" [53,156,43,62] = k ˈ æ t). Diphthongs are single tokens
//  (the Kokoro canonical form: eɪ=24, aɪ=25, əʊ=33, aʊ=39, ɔɪ=41 — consistent
//  with KokoroG2P+Bundled's pinned affricates ʧ=133, ʤ=82); long vowels are
//  vowel + ː (158), exactly as the dictionary encodes them (iː = 51,158).
//
//  ⚠️ Do not trust this table from the comment: KokoroPhonemeMapTests re-derives
//  every mapping from bundled anchor words on every run (the SpellOutLetters
//  precedent), so a swapped dictionary that re-keys the vocab turns the suite
//  red instead of quietly mispronouncing everything.
//
//  Signed: Kev + claude-fable-5, 2026-08-16, Confidence 0.85 (every id below
//  read off the live bundled dictionary, not a published vocab; the test is the
//  authority). Prior: Unknown.
//

import Foundation

/// Parses an IPA string (our own authored pronunciations) into Kokoro tokens.
public enum KokoroPhonemeMap {
    /// Multi-character phonemes first — the parser is longest-match.
    static let diphthongs: [String: Int] = [
        "eɪ": 24, "aɪ": 25, "əʊ": 33, "aʊ": 39, "ɔɪ": 41,
    ]

    static let singles: [Character: Int] = [
        // Stress + length
        "ˈ": 156, "ˌ": 157, "ː": 158,
        // Consonants
        "b": 44, "d": 46, "f": 48, "g": 92, "h": 50, "j": 52, "k": 53,
        "l": 54, "m": 55, "n": 56, "p": 58, "s": 61, "t": 62, "v": 64,
        "w": 65, "z": 68, "ŋ": 112, "ɹ": 123, "r": 123, "ʃ": 131, "ʒ": 147,
        "ʧ": 133, "ʤ": 82, "θ": 119, "ð": 81,
        // Vowels
        "æ": 43, "ɛ": 86, "ɪ": 102, "ɒ": 71, "ʌ": 138, "ʊ": 135, "ə": 83,
        "i": 51, "u": 63, "ɑ": 69, "ɔ": 76, "ɜ": 87,
    ]

    /// Token sequence for an IPA string, longest-match. nil if ANY character is
    /// unmapped — a half-pronounced word is worse than the fallback chain's next
    /// step, so this fails closed.
    public static func tokens(for ipa: String) -> [Int]? {
        var result: [Int] = []
        let chars = Array(ipa)
        var index = 0
        while index < chars.count {
            if index + 1 < chars.count,
               let diph = diphthongs[String(chars[index ... index + 1])]
            {
                result.append(diph)
                index += 2
                continue
            }
            guard let tok = singles[chars[index]] else { return nil }
            result.append(tok)
            index += 1
        }
        return result.isEmpty ? nil : result
    }
}
