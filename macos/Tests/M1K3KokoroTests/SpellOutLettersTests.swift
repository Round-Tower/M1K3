//
//  SpellOutLettersTests.swift
//  M1K3KokoroTests
//
//  Kev, live 2026-08-11: saying "M1K3" aloud, "it misses the very first letter".
//
//  The spell-out path resolves each character as a dictionary WORD and
//  `joinedTokens` drops whatever it can't resolve — so a missing single-letter
//  entry is silently unspoken, leaving no trace in any log. Measured against the
//  real bundled dictionary, only 8 of 26 letters resolved (a e i j k n r s — the
//  ones that happen to be words), so "M1K3" lost its "M" and "MCP" produced no
//  audio at all.
//
//  These tests drive the REAL dictionary rather than a fake, because the bug was a
//  false belief about that dictionary's contents ("all 26 are present", said the
//  code comment). A fake would have agreed with the comment.
//
//  Signed: Kev + claude-opus-5, 2026-08-11, Confidence 0.9 (measures the shipped
//  resource; the en-GB letter names are judgement — "zed" and "aitch" are the
//  readings Kev would expect). Prior: Unknown.
//

import Foundation
@testable import M1K3Kokoro
import Testing

struct SpellOutLettersTests {
    /// A digit in the run routes deterministically into the spell-out path (mixed
    /// alphanumeric), sidestepping the dictionary/compound fallbacks that would
    /// confound a bare single-letter probe — and it's exactly the shape of the
    /// name that started this: "M1K3".
    private func spelledSeparators(_ text: String, _ g2p: KokoroG2P) -> Int {
        g2p.phonemeTokens(text).filter { $0 == KokoroG2P.space }.count
    }

    /// Letters that add NOTHING to a spelled-out run — the silent-drop bug.
    ///
    /// Measured as "does the letter make the run longer than the digit alone",
    /// NOT as a separator count: "w" is legitimately TWO dictionary words
    /// ("double you"), so counting separators would report a correct W as broken.
    private func silentLetters(in alphabet: String, _ g2p: KokoroG2P) -> String {
        let digitOnly = g2p.phonemeTokens("1").count
        return alphabet.filter { letter in
            g2p.phonemeTokens("1\(letter)").count <= digitOnly
        }
    }

    @Test("every letter of the alphabet survives spell-out")
    func allLettersSpeakable() throws {
        let g2p = try KokoroG2P.bundled()
        // Reported as one list so the SHAPE of a gap is visible, instead of the run
        // dying on the first letter. Before the letter table this printed 18 of 26.
        let missing = silentLetters(in: "abcdefghijklmnopqrstuvwxyz", g2p)
        #expect(missing.isEmpty, "letters that produce NO phonemes: \(missing)")
    }

    @Test("uppercase spells out identically — an acronym isn't a different alphabet")
    func caseDoesNotChangeSpelling() throws {
        let g2p = try KokoroG2P.bundled()
        let missing = silentLetters(in: "ABCDEFGHIJKLMNOPQRSTUVWXYZ", g2p)
        #expect(missing.isEmpty, "uppercase letters producing NO phonemes: \(missing)")
    }

    @Test("W is two words — 'double you', never a bare 'double'")
    func doubleUIsBothWords() throws {
        let g2p = try KokoroG2P.bundled()
        // The letter table resolves all-or-nothing per letter precisely so this
        // can't degrade to half a name.
        #expect(spelledSeparators("1w", g2p) == 2)
    }

    @Test("M1K3 spells out with all four characters")
    func productNameSpellsOutInFull() throws {
        let g2p = try KokoroG2P.bundled()
        // Four spoken characters → three separators. Counting separators catches a
        // DROPPED character without pinning exact phoneme ids, which are a property
        // of the dictionary rather than of this rule.
        //
        // In normal speech this path never runs on the name — SpeechTextPolish
        // rewrites it to "Mike" (leetspeak MIKE) before any engine sees it. The
        // spell-out still has to be right for every other acronym M1K3 says.
        #expect(spelledSeparators("M1K3", g2p) == 3)
    }

    @Test("an all-caps acronym keeps every letter — MCP used to be silence")
    func acronymsKeepEveryLetter() throws {
        let g2p = try KokoroG2P.bundled()
        let tokens = g2p.phonemeTokens("MCP")
        #expect(!tokens.isEmpty, "MCP produced no audio at all")
        #expect(tokens.filter { $0 == KokoroG2P.space }.count == 2)
    }
}
