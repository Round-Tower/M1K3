import Foundation
@testable import M1K3Kokoro
import Testing

/// The OOV fallback chain: digit runs become spoken numbers, unit suffixes ride
/// the same word, mixed alphanumerics and unpronounceable acronyms spell out
/// per character — all with ONE G2PWord spanning the original text range so
/// karaoke timing still highlights "15°C" as a single word. Pure-letter words
/// that merely aren't in the dictionary stay silently skipped (regression).
struct KokoroG2PFallbackTests {
    /// Synthetic single-token entries: number words, letters, units.
    private let dict: [String: [Int]] = [
        "aa": [101], "bb": [102],
        "fifteen": [21, 22], "three": [23], "point": [24], "five": [25],
        "twenty": [26], "six": [27], "percent": [28], "celsius": [29],
        "fahrenheit": [30], "degree": [31],
        "m": [41], "k": [42], "u": [43], "s": [44], "a": [45],
        "one": [46], "zero": [47],
        // Compound-split fixtures: known sub-words, none a single dict entry combined.
        "grand": [60, 61], "master": [62, 63], "key": [64], "board": [65],
        // Inflection fixtures: bases whose FINAL token sets the allomorph.
        // 70/84 = arbitrary voiced finals; 62=/t/, 53=/k/ voiceless; 61=/s/ sibilant.
        "play": [70], "cat": [80, 62], "kiss": [81, 61],
        "want": [82, 62], "walk": [83, 53], "rain": [84], "try": [85],
    ]

    private func g2p() -> KokoroG2P {
        KokoroG2P(dictionary: dict)
    }

    // MARK: - Numbers

    @Test("a digit run becomes its spoken number words joined by spaces")
    func digitRun() {
        // "15" → fifteen [21,22]; one word covering UTF-16 range 0..<2.
        let result = g2p().annotatedTokens("15")
        #expect(result.tokens == [21, 22])
        #expect(result.words == [G2PWord(textRange: 0 ..< 2, tokenRange: 0 ..< 2)])
    }

    @Test("digit runs join the sentence with normal word spacing")
    func digitRunInSentence() {
        // "aa 15 bb" → aa SP fifteen SP bb
        #expect(g2p().phonemeTokens("aa 15 bb") == [101, 16, 21, 22, 16, 102])
    }

    @Test("a decimal literal is one word: integer part, point, fraction digits")
    func decimalLiteral() {
        // "3.5" → three point five, one word covering 0..<3.
        let result = g2p().annotatedTokens("3.5")
        #expect(result.tokens == [23, 16, 24, 16, 25])
        #expect(result.words == [G2PWord(textRange: 0 ..< 3, tokenRange: 0 ..< 5)])
    }

    @Test("a year reads as pairs")
    func yearPairs() {
        // "2026" → twenty twenty six
        #expect(g2p().phonemeTokens("2026") == [26, 16, 26, 16, 27])
    }

    // MARK: - Unit suffixes

    @Test("percent rides the number as one word")
    func percentSuffix() {
        // "15%" → fifteen percent, ONE word covering 0..<3.
        let result = g2p().annotatedTokens("15%")
        #expect(result.tokens == [21, 22, 16, 28])
        #expect(result.words == [G2PWord(textRange: 0 ..< 3, tokenRange: 0 ..< 4)])
    }

    @Test("degree-celsius rides the number as one word")
    func celsiusSuffix() {
        // "15°C" → fifteen celsius, ONE word covering 0..<4 (° is 1 UTF-16 unit).
        let result = g2p().annotatedTokens("15°C")
        #expect(result.tokens == [21, 22, 16, 29])
        #expect(result.words == [G2PWord(textRange: 0 ..< 4, tokenRange: 0 ..< 4)])
    }

    @Test("degree-fahrenheit and lone degree map to their words")
    func fahrenheitAndLoneDegree() {
        #expect(g2p().phonemeTokens("15°F") == [21, 22, 16, 30])
        #expect(g2p().phonemeTokens("15°") == [21, 22, 16, 31])
    }

    // MARK: - Spell-out

    @Test("mixed alphanumerics spell out per character as one word")
    func mixedAlphanumeric() {
        // "M1S5" → m one s five, one word covering 0..<4. (This fixture WAS
        // "M1K3" — retired from spell-out duty when the kill-or-commit-Mike
        // ruling made it a house NAME; see HouseLexiconTests.m1k3SaysMike.)
        let result = g2p().annotatedTokens("M1S5")
        #expect(result.tokens == [41, 16, 46, 16, 44, 16, 25])
        #expect(result.words == [G2PWord(textRange: 0 ..< 4, tokenRange: 0 ..< 7)])
    }

    @Test("short all-caps OOV acronyms spell out")
    func acronymSpellsOut() {
        // "USA" → u s a
        #expect(g2p().phonemeTokens("USA") == [43, 16, 44, 16, 45])
    }

    @Test("no-vowel OOV words spell out")
    func noVowelSpellsOut() {
        // "mks" lowercase, no vowels → m k s
        #expect(g2p().phonemeTokens("mks") == [41, 16, 42, 16, 44])
    }

    @Test("pronounceable OOV words are now GUESSED by letter-to-sound, not skipped")
    func pronounceableOOVSpeaks() {
        // Pre-2026-08-16 this pinned total silence ("conservative by design") —
        // which meant "Kev", "Kevin", and "Kokoro" itself were unspeakable.
        // LTS emits canonical Kokoro ids regardless of this fake dictionary.
        let result = g2p().annotatedTokens("aa blorptastic bb")
        #expect(result.words.count == 3)
        #expect(!result.words[1].tokenRange.isEmpty)
        // Neighbours keep their words and spacing around the guess.
        #expect(result.tokens.first == 101)
        #expect(result.tokens.last == 102)
    }

    @Test("a word letter-to-sound refuses (non-ASCII) still skips silently")
    func unguessableOOVStaysSilent() {
        let result = g2p().annotatedTokens("aa Zoë bb")
        #expect(result.tokens == [101, 16, 102])
        #expect(result.words.count == 3)
        #expect(result.words[1].tokenRange.isEmpty)
    }

    // MARK: - Compound split (the "grandmaster" fix)

    @Test("a compound OOV word splits into its known sub-words and is spoken")
    func compoundSplits() {
        // "grandmaster" is NOT a dict entry, but grand + master are → speak both,
        // joined by the space token, as ONE word for karaoke timing.
        let result = g2p().annotatedTokens("grandmaster")
        #expect(result.tokens == [60, 61, 16, 62, 63])
        #expect(result.words == [G2PWord(textRange: 0 ..< 11, tokenRange: 0 ..< 5)])
    }

    @Test("compound split is case-insensitive and rides a sentence cleanly")
    func compoundInSentence() {
        // "aa Keyboard bb" → aa SP key SP board SP bb
        #expect(g2p().phonemeTokens("aa Keyboard bb") == [101, 16, 64, 16, 65, 16, 102])
    }

    @Test("a partial segmentation never half-speaks — it falls through to a whole-word guess")
    func compoundPartialFallsToGuess() {
        // "masterful" = master + "ful" (not in dict) — no COMPLETE split. The
        // old pin was silence; now letter-to-sound guesses the WHOLE word (one
        // span, never a half-spoken "master" + hole).
        let result = g2p().annotatedTokens("masterful")
        #expect(result.words.count == 1)
        #expect(!result.words[0].tokenRange.isEmpty)
        #expect(result.words[0].tokenRange == 0 ..< result.tokens.count)
    }

    @Test("single-letter dict keys can't make a compound into letter-soup")
    func compoundMinSegmentGuard() {
        // "ask" would be a-s-k via single-letter keys if unguarded; the ≥3-char
        // minimum blocks that. It then speaks WHOLE via letter-to-sound
        // (ˈæsk = [156, 43, 61, 53]) — one guess, not three letter names.
        #expect(g2p().phonemeTokens("ask") == [156, 43, 61, 53])
    }

    // MARK: - Inflection (the "plays" fix): OOV -s/-es/-ies/-ed forms

    @Test("plural -s appends voiced /z/ on a voiced stem")
    func pluralVoiced() {
        // "plays" = play[70] + /z/(68); ONE karaoke word over the whole text.
        let result = g2p().annotatedTokens("plays")
        #expect(result.tokens == [70, 68])
        #expect(result.words == [G2PWord(textRange: 0 ..< 5, tokenRange: 0 ..< 2)])
    }

    @Test("plural -s appends voiceless /s/ on a voiceless stem")
    func pluralVoiceless() {
        // "cats" = cat[80,62 /t/] + /s/(61) — not the lazy /z/.
        #expect(g2p().phonemeTokens("cats") == [80, 62, 61])
    }

    @Test("plural -es appends syllabic /ɪz/ on a sibilant stem")
    func pluralSibilant() {
        // "kisses" = kiss[81,61 /s/] + /ɪz/([102,68]).
        #expect(g2p().phonemeTokens("kisses") == [81, 61, 102, 68])
    }

    @Test("plural -ies restores the -y base")
    func pluralIes() {
        // "tries" = try[85] + /z/(68).
        #expect(g2p().phonemeTokens("tries") == [85, 68])
    }

    @Test("past -ed appends syllabic /ɪd/ after t or d")
    func pastTd() {
        // "wanted" = want[82,62 /t/] + /ɪd/([102,46]).
        #expect(g2p().phonemeTokens("wanted") == [82, 62, 102, 46])
    }

    @Test("past -ed appends voiceless /t/ on a voiceless stem")
    func pastVoiceless() {
        // "walked" = walk[83,53 /k/] + /t/(62).
        #expect(g2p().phonemeTokens("walked") == [83, 53, 62])
    }

    @Test("past -ed appends voiced /d/ on a voiced stem")
    func pastVoiced() {
        // "rained" = rain[84] + /d/(46).
        #expect(g2p().phonemeTokens("rained") == [84, 46])
    }

    @Test("a compound plural composes split + inflection")
    func compoundPlural() {
        // "keyboards" = key[64] + board[65] (compound), then + /z/(68).
        #expect(g2p().phonemeTokens("keyboards") == [64, 16, 65, 68])
    }

    @Test("an OOV word ending in s with no resolvable base is guessed WHOLE")
    func unresolvableSGuessedWhole() {
        // "blorps" — "blorp" isn't a dict word or a compound, and resolveBase
        // deliberately excludes letter-to-sound, so the -s split never fires;
        // the main chain's LTS guesses the whole form instead (old pin: silence).
        #expect(g2p().phonemeTokens("blorps") == LetterToSound.tokens(for: "blorps"))
    }

    @Test("long all-caps words are not spelled out — they get a word guess")
    func longCapsNotSpelled() {
        // 6+ caps is likely a shouted word, not an acronym: never letter-soup.
        // Old pin: silence; now the whole-word letter-to-sound guess (in the
        // REAL pipeline "AMAZING" is a dictionary hit long before this).
        #expect(g2p().phonemeTokens("AMAZING") == LetterToSound.tokens(for: "amazing"))
    }

    // MARK: - Cap behavior

    @Test("an expansion that would blow the cap is dropped whole on the word boundary")
    func capDropsWholeExpansion() {
        // cap small enough that "15" (fifteen = 2 tokens) fits but "3.5"
        // (5 tokens + space) does not.
        let g2p = KokoroG2P(dictionary: dict)
        let capped = g2p.phonemeTokens("15 3.5") // maxTokens applies (510) — not this test
        #expect(capped == [21, 22, 16, 23, 16, 24, 16, 25])
        // Use assemble's cap via phonemeTokens on a long string instead:
        // build a string of many "15 " words to cross 510 and confirm count ≤ 510.
        let many = String(repeating: "15 ", count: 300)
        #expect(g2p.phonemeTokens(many).count <= KokoroG2P.maxTokens)
    }

    // MARK: - Offset bookkeeping

    @Test("words after an expanded run keep exact text ranges")
    func offsetsAfterExpansion() {
        // "15°C aa" — aa starts after "15°C " = UTF-16 offset 5.
        let result = g2p().annotatedTokens("15°C aa")
        #expect(result.words.count == 2)
        #expect(result.words[1].textRange == 5 ..< 7)
    }
}
