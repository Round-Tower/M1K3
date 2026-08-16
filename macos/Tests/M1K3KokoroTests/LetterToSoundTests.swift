//
//  LetterToSoundTests.swift
//  M1K3KokoroTests
//
//  The rule engine's pins: hand-checked IPA for words exercising each rule
//  family — start clusters, digraphs, vowel teams, r-controlled vowels,
//  magic-e, positional ow/er/ie/y, soft c/g, doubled consonants, first-vowel
//  stress — plus the refusals (non-ASCII stays silent, exactly the old
//  behavior).
//
//  Signed: Kev + claude-fable-5, 2026-08-16, Confidence 0.85, Prior: Unknown
//

import M1K3Kokoro
import Testing

struct LetterToSoundTests {
    @Test("the names that started this: Kev is speakable")
    func kev() {
        #expect(LetterToSound.ipa(for: "Kev") == "kˈɛv")
        #expect(LetterToSound.ipa(for: "Kevin") == "kˈɛvɪn")
    }

    @Test("rule families produce the expected IPA")
    func ruleFamilies() {
        #expect(LetterToSound.ipa(for: "shane") == "ʃˈeɪn") // sh + magic-e
        #expect(LetterToSound.ipa(for: "glarp") == "glˈɑːp") // ar
        #expect(LetterToSound.ipa(for: "throck") == "θɹˈɒk") // th + ck
        #expect(LetterToSound.ipa(for: "knapp") == "nˈæp") // kn + doubled p
        #expect(LetterToSound.ipa(for: "wrenlow") == "ɹˈɛnləʊ") // wr + final ow
        #expect(LetterToSound.ipa(for: "quenby") == "kwˈɛnbi") // qu + final y
        #expect(LetterToSound.ipa(for: "moyle") == "mˈɔɪl") // oy + silent e
        #expect(LetterToSound.ipa(for: "creel") == "kɹˈiːl") // ee
        #expect(LetterToSound.ipa(for: "flump") == "flˈʌmp") // short u default
        #expect(LetterToSound.ipa(for: "cinder") == "sˈɪndə") // soft c + final er
        #expect(LetterToSound.ipa(for: "gyre") == "ʤˈaɪɹ") // soft g + magic-e
    }

    @Test("stress lands before the first vowel")
    func stressPlacement() {
        #expect(LetterToSound.ipa(for: "strand") == "stɹˈænd")
    }

    @Test("non-ASCII letters refuse — the old silence is preserved for them")
    func nonASCIIRefuses() {
        #expect(LetterToSound.ipa(for: "Zoë") == nil)
        #expect(LetterToSound.ipa(for: "こころ") == nil)
        #expect(LetterToSound.tokens(for: "Zoë") == nil)
    }

    @Test("tokens render through the phoneme map")
    func tokensRender() {
        // kˈɛv = k(53) ˈ(156) ɛ(86) v(64) — the ids the bundled vocab uses.
        #expect(LetterToSound.tokens(for: "kev") == [53, 156, 86, 64])
    }
}
