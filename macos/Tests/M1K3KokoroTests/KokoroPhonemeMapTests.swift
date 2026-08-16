//
//  KokoroPhonemeMapTests.swift
//  M1K3KokoroTests
//
//  The phoneme→token table is DERIVED data, and this suite is the derivation:
//  every mapped character is re-checked against the real bundled dictionary by
//  rendering an anchor word's textbook en-GB IPA through the map and comparing
//  with the dictionary's own tokens (the SpellOutLetters precedent — never
//  trust the table's comment). A swapped dictionary that re-keys the vocab
//  turns this red instead of quietly mispronouncing everything we author.
//
//  Signed: Kev + claude-fable-5, 2026-08-16, Confidence 0.9, Prior: Unknown
//

import M1K3Kokoro
import Testing

struct KokoroPhonemeMapTests {
    /// Anchor word → its textbook en-GB IPA. Together these cover every
    /// consonant, vowel, diphthong, and mark the map defines (r/ɹ share a token).
    private static let anchors: [(word: String, ipa: String)] = [
        ("cat", "kˈæt"), ("dog", "dˈɒg"), ("ship", "ʃˈɪp"), ("chip", "ʧˈɪp"),
        ("jam", "ʤˈæm"), ("thin", "θˈɪn"), ("then", "ðˈɛn"), ("sing", "sˈɪŋ"),
        ("yes", "jˈɛs"), ("wet", "wˈɛt"), ("red", "ɹˈɛd"), ("let", "lˈɛt"),
        ("met", "mˈɛt"), ("net", "nˈɛt"), ("pet", "pˈɛt"), ("ten", "tˈɛn"),
        ("zoo", "zˈuː"), ("book", "bˈʊk"), ("food", "fˈuːd"), ("bird", "bˈɜːd"),
        ("car", "kˈɑː"), ("door", "dˈɔː"), ("day", "dˈeɪ"), ("eye", "ˈaɪ"),
        ("boy", "bˈɔɪ"), ("now", "nˈaʊ"), ("oh", "ˈəʊ"), ("hot", "hˈɒt"),
        ("hut", "hˈʌt"), ("about", "əbˈaʊt"), ("five", "fˈaɪv"), ("one", "wˈʌn"),
        ("you", "juː"), ("gemma", "ʤˈɛmə"), ("murphy", "mˈɜːfi"),
    ]

    @Test("every authored IPA character round-trips through the real dictionary")
    func anchorsMatchBundledDictionary() throws {
        let g2p = try KokoroG2P.bundled()
        for (word, ipa) in Self.anchors {
            let dictionaryTokens = g2p.phonemeTokens(word)
            let mapTokens = KokoroPhonemeMap.tokens(for: ipa)
            #expect(mapTokens == dictionaryTokens,
                    "\(word): map(\(ipa)) = \(mapTokens ?? []) vs dict \(dictionaryTokens)")
        }
    }

    @Test("an unmapped character fails the whole string — no half-words")
    func unmappedFailsClosed() {
        #expect(KokoroPhonemeMap.tokens(for: "kˈɛ⟡v") == nil)
        #expect(KokoroPhonemeMap.tokens(for: "") == nil)
    }
}
