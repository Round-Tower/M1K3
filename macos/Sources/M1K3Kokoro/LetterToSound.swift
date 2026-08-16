//
//  LetterToSound.swift
//  M1K3Kokoro
//
//  The last stop before silence: en-GB letter-to-sound rules for pronounceable
//  out-of-vocabulary words. Until now the OOV chain's final answer was a
//  SILENT SKIP — "conservative by design" — which meant M1K3 could not say
//  "Kev", "Kevin", "Ardmore", "Qwen", or even "Kokoro" (its own voice's name).
//  A rough-but-honest pronunciation attempt is what a human reader does with an
//  unknown name, and it beats a hole in the sentence every time.
//
//  Deliberately LAST in the fallback chain — dictionary, house lexicon,
//  inflection, compound split, and acronym spell-out all take precedence — so
//  it can only ever replace what used to be silence. ASCII letters only:
//  anything else still falls through to the old silent skip.
//
//  The rules are the compact classics: start clusters (kn/wr/wh/gn), digraphs
//  (ch/sh/th/ph/ck/ng/qu/dg), vowel teams (ee/ea/oo/ou/ow/ai/ay/oa/oi/oy/au/
//  aw/oe/ie/ue), r-controlled vowels (ar/or/er/ir/ur), magic-e, soft c/g,
//  doubled-consonant collapse, and short-vowel defaults, with primary stress on
//  the first vowel — the right default for the names this exists to speak.
//
//  Known limits, accepted: `th` always maps voiceless (θ) — voiced ð (then,
//  mother) is lexically conditioned and undecidable from spelling alone; real
//  `th` words come from the dictionary anyway. Same class as unstressed-vowel
//  reduction: rules guess, the lexicon knows.
//
//  Signed: Kev + claude-fable-5, 2026-08-16, Confidence 0.8 (the engine and
//  every rule are pinned by LetterToSoundTests against hand-checked IPA; the
//  AUDIO quality of any given guess is verify-by-ear, and the design accepts
//  imperfect guesses as strictly better than silence). Prior: Unknown.
//  Review: Kev + claude-fable-5, 2026-08-16 — the -ce/-ge softness bug (bot
//  review, PR #135): applyFinalE now sentinels soft c/g BEFORE dropping the e.
//

import Foundation

public enum LetterToSound {
    /// Kokoro tokens for an OOV word, or nil when the word carries characters
    /// the rules don't cover (non-ASCII letters keep the old silent behavior).
    public static func tokens(for word: String) -> [Int]? {
        guard let ipa = ipa(for: word) else { return nil }
        return KokoroPhonemeMap.tokens(for: ipa)
    }

    /// The IPA guess. Public because the rules ARE the tested surface.
    public static func ipa(for raw: String) -> String? {
        let word = raw.lowercased().replacingOccurrences(of: "'", with: "")
        guard !word.isEmpty, word.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        var chars = Array(word)
        applyFinalE(&chars)

        var phonemes: [String] = []
        var index = 0
        while index < chars.count {
            index = consume(chars, at: index, into: &phonemes)
        }
        guard !phonemes.isEmpty else { return nil }
        return stressed(phonemes).joined()
    }

    // MARK: - Final-e handling

    /// Magic-e (V-C-e → long vowel, drop e) or plain silent final e. Sentinel
    /// uppercase letters mark the lengthened vowel for the scanner.
    private static func applyFinalE(_ chars: inout [Character]) {
        guard chars.count >= 3, chars.last == "e" else { return }
        let consonant = chars[chars.count - 2]
        guard !"aeiou".contains(consonant) else { return } // "ee"/"oe" are teams, not magic
        let vowel = chars[chars.count - 3]
        // The magic vowel must stand ALONE: a vowel before it makes a team
        // ("moose", "moyle") that the scanner owns — lengthening one half
        // would break the digraph match. y counts as a magic vowel (gyre).
        let standsAlone = chars.count < 4 || !"aeiouy".contains(chars[chars.count - 4])
        if "aeiouy".contains(vowel), !"wxy".contains(consonant), standsAlone {
            let long: [Character: Character] = [
                "a": "A", "e": "E", "i": "I", "o": "O", "u": "U", "y": "I",
            ]
            chars[chars.count - 3] = long[vowel] ?? vowel
        }
        // Soft c/g must be decided HERE, before the e is deleted — single()'s
        // lookahead can never see a character that no longer exists (the
        // face→"fake" bug, PR #135 review). The sentinel carries the softness.
        if consonant == "c" { chars[chars.count - 2] = "C" }
        if consonant == "g" { chars[chars.count - 2] = "G" }
        chars.removeLast()
    }

    // MARK: - Grapheme scanning

    private static let startClusters: [String: String] = [
        "kn": "n", "wr": "ɹ", "wh": "w", "gn": "n",
    ]

    private static let trigraphs: [String: String] = [
        "tch": "ʧ", "igh": "aɪ",
    ]

    private static let digraphs: [String: String] = [
        "ch": "ʧ", "sh": "ʃ", "th": "θ", "ph": "f", "ck": "k", "ng": "ŋ",
        "qu": "kw", "dg": "ʤ",
        "ee": "iː", "ea": "iː", "oo": "uː", "ou": "aʊ",
        "ai": "eɪ", "ay": "eɪ", "oa": "əʊ", "oi": "ɔɪ", "oy": "ɔɪ",
        "au": "ɔː", "aw": "ɔː", "oe": "əʊ", "ue": "uː",
        "ar": "ɑː", "or": "ɔː", "ir": "ɜː", "ur": "ɜː",
    ]

    /// Consume one grapheme at `index`, append its phoneme(s), return the next index.
    private static func consume(_ chars: [Character], at index: Int, into phonemes: inout [String]) -> Int {
        let remaining = chars.count - index
        let isFinal = { (len: Int) in index + len == chars.count }

        if index == 0, remaining >= 2,
           let cluster = startClusters[String(chars[0 ... 1])]
        {
            phonemes.append(cluster)
            return index + 2
        }
        if remaining >= 3, let tri = trigraphs[String(chars[index ... index + 2])] {
            phonemes.append(tri)
            return index + 3
        }
        if remaining >= 2 {
            let pair = String(chars[index ... index + 1])
            // Position-sensitive teams first.
            if pair == "ow" { phonemes.append(isFinal(2) ? "əʊ" : "aʊ"); return index + 2 }
            if pair == "er" { phonemes.append(isFinal(2) ? "ə" : "ɜː"); return index + 2 }
            if pair == "ie" { phonemes.append(isFinal(2) ? "aɪ" : "iː"); return index + 2 }
            if let di = digraphs[pair] { phonemes.append(di); return index + 2 }
            // Doubled consonant → one sound.
            if chars[index] == chars[index + 1], !"aeiou".contains(chars[index]) {
                phonemes.append(single(chars[index], next: index + 2 < chars.count ? chars[index + 2] : nil,
                                       atStart: index == 0, atEnd: isFinal(2)))
                return index + 2
            }
        }
        phonemes.append(single(chars[index], next: index + 1 < chars.count ? chars[index + 1] : nil,
                               atStart: index == 0, atEnd: isFinal(1)))
        return index + 1
    }

    /// One letter's sound, context-aware (soft c/g, positional y).
    private static func single(_ char: Character, next: Character?, atStart: Bool, atEnd: Bool) -> String {
        switch char {
        case "a": return "æ"
        case "e": return "ɛ"
        case "i": return "ɪ"
        case "o": return "ɒ"
        case "u": return "ʌ"
        case "A": return "eɪ"
        case "E": return "iː"
        case "I": return "aɪ"
        case "O": return "əʊ"
        case "U": return "uː"
        case "y":
            if atStart { return "j" }
            return atEnd ? "i" : "ɪ"
        // "EI" are the magic-e sentinels — a lengthened front vowel still softens.
        case "c": return next.map { "eiyEI".contains($0) } == true ? "s" : "k"
        case "g": return next.map { "eiyEI".contains($0) } == true ? "ʤ" : "g"
        // Softness decided by applyFinalE before the e was dropped (-ce/-ge).
        case "C": return "s"
        case "G": return "ʤ"
        case "j": return "ʤ"
        case "q": return "k"
        case "r": return "ɹ"
        case "x": return "ks"
        default: return String(char)
        }
    }

    /// The set of phoneme strings that count as vowels for stress placement.
    private static let vowelPhonemes: Set<String> = [
        "æ", "ɛ", "ɪ", "ɒ", "ʌ", "ʊ", "ə", "i", "u",
        "iː", "uː", "ɑː", "ɔː", "ɜː", "eɪ", "aɪ", "əʊ", "aʊ", "ɔɪ",
    ]

    /// Primary stress before the first vowel — the natural default for names.
    private static func stressed(_ phonemes: [String]) -> [String] {
        guard let first = phonemes.firstIndex(where: { vowelPhonemes.contains($0) }) else {
            return phonemes
        }
        var result = phonemes
        result.insert("ˈ", at: first)
        return result
    }
}
