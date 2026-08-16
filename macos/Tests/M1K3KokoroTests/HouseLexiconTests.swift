//
//  HouseLexiconTests.swift
//  M1K3KokoroTests
//
//  Every house entry is spoken through the REAL bundled pipeline — an entry
//  whose IPA doesn't fully map, or that a dictionary word shadows wrongly,
//  turns this red. Plus the possessive ride-along: "Kev's" resolves its base
//  through the house lexicon and takes the voiced plural.
//
//  Signed: Kev + claude-fable-5, 2026-08-16, Confidence 0.9, Prior: Unknown
//

import M1K3Kokoro
import Testing

struct HouseLexiconTests {
    @Test("every house entry is speakable through the bundled pipeline")
    func allEntriesSpeak() throws {
        let g2p = try KokoroG2P.bundled()
        for (word, ipa) in HouseLexicon.entries {
            let spoken = g2p.phonemeTokens(word)
            let expected = try #require(KokoroPhonemeMap.tokens(for: ipa),
                                        "\(word): IPA \(ipa) doesn't fully map")
            #expect(spoken == expected, "\(word) spoke \(spoken), lexicon says \(expected)")
        }
    }

    @Test("Kev is no longer silence — the bug that started this")
    func kevSpeaks() throws {
        let g2p = try KokoroG2P.bundled()
        // kˈɛv = k ˈ ɛ v
        #expect(g2p.phonemeTokens("Kev") == [53, 156, 86, 64])
        #expect(!g2p.phonemeTokens("Kevin").isEmpty)
        #expect(!g2p.phonemeTokens("Ardmore").isEmpty)
        #expect(!g2p.phonemeTokens("Kokoro").isEmpty)
    }

    @Test("Kev's takes the house base plus the voiced possessive")
    func kevPossessive() throws {
        let g2p = try KokoroG2P.bundled()
        // kˈɛv + /z/ (68)
        #expect(g2p.phonemeTokens("Kev's") == [53, 156, 86, 64, 68])
    }

    @Test("a pronounceable name outside the lexicon now speaks via letter-to-sound")
    func oovNameSpeaks() throws {
        let g2p = try KokoroG2P.bundled()
        // The pre-2026-08-16 behavior was TOTAL silence for these.
        #expect(!g2p.phonemeTokens("Blorptastic").isEmpty)
        // And a full sentence keeps every word addressable for karaoke.
        let result = g2p.annotatedTokens("Kev lives in Ardmore")
        #expect(result.words.count == 4)
        #expect(result.words.allSatisfy { !$0.tokenRange.isEmpty })
    }
}
