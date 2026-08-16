//
//  KokoroG2P.swift
//  M1K3Kokoro
//
//  Pure grapheme→phoneme→token mapping for the Kokoro model (backend-agnostic —
//  the same vocab ids feed both the historical ONNX path and the current MLX
//  one). Splits text into
//  words (looked up in a bundled pronunciation dictionary) and punctuation (mapped to
//  the model's vocab tokens), assembling the int64 token sequence Kokoro expects:
//  per-word phonemes joined by the space token, punctuation attached directly, wrapped
//  in [0 … 0] pad tokens.
//
//  The DICTIONARY is data (swappable — now misaki-gb, Apache 2.0). THIS assembly
//  logic is the tested IP. Per-word lookup reproduces whole-sentence phonemes for
//  the common case; minor sentence-prosody stress differences on some function
//  words (ˈ vs ˌ) are expected and benign.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-09, Confidence 0.75, Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-06-11 — walker rewritten over the ORIGINAL
//  string (per-word lowercase for lookup only) to add annotatedTokens word
//  boundaries for karaoke timing; phonemeTokens is now a capped wrapper, all
//  prior tests untouched-green. Confidence 0.85.
//  Review: Kev + claude-fable-5, 2026-06-11 — OOV fallback chain added (the
//  "skipping" fix): digit runs + unit suffixes become NumberSpeller words,
//  no-vowel/short-caps OOV spells out via single-letter dict keys; one G2PWord
//  per expansion keeps karaoke ranges exact. Pronounceable OOV still skips —
//  conservative by design. Confidence 0.85 (audio quality verify-at-⌘R).
//

import Foundation

/// One word as the G2P walker saw it: where it sits in the original text and
/// which of the assembled tokens are its own phonemes. Inter-word spaces and
/// punctuation belong to the token stream, never to a word's `tokenRange` —
/// the timing estimator attributes them. OOV words carry an empty `tokenRange`
/// at their stream position.
public struct G2PWord: Sendable, Equatable {
    /// UTF-16 offsets into the original input text (case preserved).
    public let textRange: Range<Int>
    /// Indices into `G2PResult.tokens`; empty for out-of-vocabulary words.
    public let tokenRange: Range<Int>

    public init(textRange: Range<Int>, tokenRange: Range<Int>) {
        self.textRange = textRange
        self.tokenRange = tokenRange
    }
}

/// Token assembly plus the word boundaries that produced it.
public struct G2PResult: Sendable, Equatable {
    public let tokens: [Int]
    public let words: [G2PWord]

    public init(tokens: [Int], words: [G2PWord]) {
        self.tokens = tokens
        self.words = words
    }
}

public struct KokoroG2P: Sendable {
    /// BOS/EOS pad token the model expects wrapping every input.
    public static let pad = 0
    /// The vocab's space token, emitted between adjacent words.
    public static let space = 16
    /// Model context limit on phoneme tokens (before the pad wrap).
    public static let maxTokens = 510

    private let dictionary: [String: [Int]]
    private let punctuation: [Character: Int]

    public init(
        dictionary: [String: [Int]],
        punctuation: [Character: Int] = KokoroG2P.defaultPunctuation
    ) {
        self.dictionary = dictionary
        self.punctuation = punctuation
    }

    /// Phoneme tokens WITHOUT the pad wrap. Its `.count` is the index into the voice
    /// style array, so it is capped at `maxTokens` on a word boundary.
    public func phonemeTokens(_ text: String) -> [Int] {
        assemble(text, cap: Self.maxTokens).tokens
    }

    /// Word-boundary-annotated assembly for the karaoke word-timing estimator.
    /// UNCAPPED — chunking (SpeechChunker) owns the 510 limit; capping here would
    /// silently truncate long answers.
    public func annotatedTokens(_ text: String) -> G2PResult {
        assemble(text, cap: nil)
    }

    /// The one walker behind both APIs. Walks the ORIGINAL string (case preserved,
    /// lowercasing only each extracted word for dictionary lookup) so word text
    /// ranges are exact by construction, tracking a running UTF-16 offset.
    private func assemble(_ text: String, cap: Int?) -> G2PResult {
        var tokens: [Int] = []
        var words: [G2PWord] = []
        var prevWasToken = false
        var offset = 0 // running UTF-16 offset into the original text
        let chars = Array(text)
        let charCount = chars.count
        var index = 0

        while index < charCount {
            let char = chars[index]
            if char.isLetter || char.isASCIIDigit {
                let run = scanRun(chars, from: index)
                let textRange = offset ..< offset + run.utf16Count
                index = run.end
                offset += run.utf16Count
                guard let toks = resolveTokens(for: run), !toks.isEmpty else {
                    // OOV: no phonemes, no space — an empty token range at the
                    // current position keeps the word addressable for timing.
                    words.append(G2PWord(textRange: textRange, tokenRange: tokens.count ..< tokens.count))
                    continue
                }
                let needed = (prevWasToken ? 1 : 0) + toks.count
                if let cap, tokens.count + needed > cap { break }
                if prevWasToken { tokens.append(Self.space) }
                let tokenStart = tokens.count
                tokens.append(contentsOf: toks)
                words.append(G2PWord(textRange: textRange, tokenRange: tokenStart ..< tokens.count))
                prevWasToken = true
            } else if char == " " || char == "\n" || char == "\t" || char == "\r" {
                offset += 1 // whitespace → implicit space, emitted only before the next word
                index += 1
            } else if let tok = punctuation[char] {
                if let cap, tokens.count + 1 > cap { break }
                tokens.append(tok)
                prevWasToken = true
                offset += char.utf16.count
                index += 1
            } else {
                offset += char.utf16.count // unknown character → skip
                index += 1
            }
        }
        return G2PResult(tokens: tokens, words: words)
    }

    /// One maximal word run plus any unit suffix it absorbed.
    private struct WordRun {
        let text: String // original case, units excluded
        let unitWords: [String] // "%" / "°C" / "°F" / "°" → speakable words
        let containsDigit: Bool
        let end: Int // exclusive char index after run + unit
        let utf16Count: Int // run + unit, for the text range
    }

    /// Maximal run: letters, ASCII digits, internal apostrophes, and '.'/','
    /// flanked by digits (decimals, grouping commas). A digit-containing run
    /// absorbs a trailing %, °C, °F, or ° into the SAME run so "15°C" is one
    /// word for timing.
    private func scanRun(_ chars: [Character], from start: Int) -> WordRun {
        var end = start
        var utf16Count = 0
        var containsDigit = false
        while end < chars.count {
            let runChar = chars[end]
            if runChar.isLetter || runChar == "'" {
                // word characters
            } else if runChar.isASCIIDigit {
                containsDigit = true
            } else if runChar == "." || runChar == "," {
                guard end > start, chars[end - 1].isASCIIDigit,
                      end + 1 < chars.count, chars[end + 1].isASCIIDigit else { break }
            } else {
                break
            }
            utf16Count += runChar.utf16.count
            end += 1
        }
        let text = String(chars[start ..< end])
        var unitWords: [String] = []
        if containsDigit, end < chars.count {
            if chars[end] == "%" {
                unitWords = ["percent"]
                utf16Count += 1
                end += 1
            } else if chars[end] == "°" {
                utf16Count += 1
                end += 1
                if end < chars.count, chars[end] == "C" || chars[end] == "c" {
                    unitWords = ["celsius"]
                    utf16Count += 1
                    end += 1
                } else if end < chars.count, chars[end] == "F" || chars[end] == "f" {
                    unitWords = ["fahrenheit"]
                    utf16Count += 1
                    end += 1
                } else {
                    unitWords = ["degree"] // "degrees" is absent from the dict
                }
            }
        }
        return WordRun(text: text, unitWords: unitWords, containsDigit: containsDigit, end: end, utf16Count: utf16Count)
    }

    /// Fallback chain: dictionary → house lexicon → inflection → compound →
    /// acronym spell-out → letter-to-sound → nil (silent skip). Expansions join
    /// their words with the space token so one run yields one contiguous token
    /// span. Letter-to-sound is deliberately LAST (2026-08-16): it can only
    /// ever replace what used to be silence — the fate of every pronounceable
    /// OOV word before it, including "Kev" and "Kokoro" itself.
    private func resolveTokens(for run: WordRun) -> [Int]? {
        if run.containsDigit {
            if let numberWords = NumberSpeller.numberWords(run.text) {
                return joinedTokens(for: numberWords + run.unitWords)
            }
            // Mixed alphanumeric ("M1K3") → spell out per character.
            return spellOutTokens(run.text, extraWords: run.unitWords)
        }
        let raw = run.text.lowercased()
        if let hit = lookup(raw) { return hit }
        if let house = houseTokens(raw) { return house }
        if let inflected = inflectedTokens(raw) { return inflected }
        if let compound = compoundTokens(raw) { return compound }
        if shouldSpellOut(run.text) { return spellOutTokens(run.text, extraWords: []) }
        if let guessed = LetterToSound.tokens(for: raw) { return guessed }
        return nil
    }

    /// House-lexicon lookup with the same apostrophe trim as `lookup` — so
    /// "Kev's" resolves its base through the inflection path.
    private func houseTokens(_ word: String) -> [Int]? {
        if let hit = HouseLexicon.tokens(for: word) { return hit }
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        if trimmed != word { return HouseLexicon.tokens(for: trimmed) }
        return nil
    }

    // MARK: - Inflection fallback (the "plays" fix)

    // The spike dictionary (web2-derived) carries base forms and many "-ing"
    // forms but NOT "-s"/"-es" plurals/3rd-person or "-ed" pasts — so they were
    // silently dropped. We resolve the BASE (dictionary or compound-split) and
    // append the correct suffix phoneme. Token ids are the bundled Kokoro en-GB
    // vocab (canonical Kokoro token IDs): the allomorphy is real, not a guess.
    // This is the safety net that also covers any future OOV inflection.
    private static let phonemeZ = 68 // /z/
    private static let phonemeS = 61 // /s/
    private static let phonemeIz = [102, 68] // /ɪz/
    private static let phonemeD = 46 // /d/
    private static let phonemeT = 62 // /t/
    private static let phonemeId = [102, 46] // /ɪd/
    /// Stem-final phonemes that take the syllabic plural /ɪz/: s z ʃ ʒ ʧ ʤ.
    private static let sibilantFinals: Set<Int> = [61, 68, 131, 147, 133, 82]
    /// Voiceless non-sibilant stem finals (take /s/ for plural): p t k f θ.
    private static let voicelessForPlural: Set<Int> = [58, 62, 53, 48, 119]
    /// Voiceless stem finals (take /t/ for past, excluding t itself): p k f θ s ʃ ʧ.
    private static let voicelessForPast: Set<Int> = [58, 53, 48, 119, 61, 131, 133]
    /// Stem finals that take the syllabic past /ɪd/: t d.
    private static let tdFinals: Set<Int> = [62, 46]

    /// Speak an OOV inflected form by resolving its base and appending the
    /// suffix phoneme the dictionary lacked. One contiguous span (one karaoke word).
    private func inflectedTokens(_ word: String) -> [Int]? {
        let chars = Array(word)
        guard chars.count > 2 else { return nil }

        // "-ies" plural of a -y word: tries → try, babies → baby.
        if word.hasSuffix("ies"), chars.count > 3,
           let base = resolveBase(String(chars.dropLast(3)) + "y")
        {
            return base + pluralSuffix(after: base.last)
        }
        // Sibilant "-es": kisses → kiss, washes → wash, boxes → box (syllabic /ɪz/).
        if word.hasSuffix("es"), chars.count > 3,
           let base = resolveBase(String(chars.dropLast(2))),
           Self.sibilantFinals.contains(base.last ?? -1)
        {
            return base + Self.phonemeIz
        }
        // General "-s": plays → play, cats → cat, makes → make.
        if word.hasSuffix("s"), let base = resolveBase(String(chars.dropLast(1))) {
            return base + pluralSuffix(after: base.last)
        }
        // "-ed": play+ed → play, bake+d → bake (silent e). Prefer the longer base.
        if word.hasSuffix("ed"), chars.count > 3 {
            let candidate = [String(chars.dropLast(2)), String(chars.dropLast(1))]
                .compactMap { stem in resolveBase(stem).map { (stem.count, $0) } }
                .max { $0.0 < $1.0 }
            if let base = candidate?.1 {
                return base + pastSuffix(after: base.last)
            }
        }
        return nil
    }

    /// Base tokens via the dictionary or house lexicon, falling back to a
    /// compound split (so "keyboards" = key+board, then +/z/). Deliberately NO
    /// letter-to-sound here: an OOV name ending in s ("glarps", "silas") is
    /// better guessed WHOLE by the main chain's LTS than split into a guessed
    /// base plus a plural it may not have. nil for stems too short to be real.
    private func resolveBase(_ stem: String) -> [Int]? {
        guard stem.count >= 2 else { return nil }
        return lookup(stem) ?? houseTokens(stem) ?? compoundTokens(stem)
    }

    private func pluralSuffix(after last: Int?) -> [Int] {
        guard let last else { return [Self.phonemeZ] }
        if Self.sibilantFinals.contains(last) { return Self.phonemeIz } // /ɪz/
        if Self.voicelessForPlural.contains(last) { return [Self.phonemeS] } // /s/
        return [Self.phonemeZ] // /z/
    }

    private func pastSuffix(after last: Int?) -> [Int] {
        guard let last else { return [Self.phonemeD] }
        if Self.tdFinals.contains(last) { return Self.phonemeId } // /ɪd/
        if Self.voicelessForPast.contains(last) { return [Self.phonemeT] } // /t/
        return [Self.phonemeD] // /d/
    }

    /// Compound fallback: an OOV word that fully decomposes into KNOWN dictionary
    /// words is spoken as those sub-words — "grandmaster" → grand + master. The
    /// segmentation must be COMPLETE (every character covered) and each piece
    /// ≥ `minSegment` chars, so single-letter dictionary keys can't turn a word
    /// into letter-soup and a word that doesn't cleanly decompose stays silent.
    /// One run still yields one contiguous token span (one karaoke word).
    private func compoundTokens(_ word: String, minSegment: Int = 3, maxSegments: Int = 3) -> [Int]? {
        guard let segments = segment(Array(word), minSegment: minSegment, maxSegments: maxSegments),
              segments.count >= 2
        else { return nil }
        return joinedTokens(for: segments)
    }

    /// Full segmentation of `chars` into dictionary words, longest prefix first
    /// (so it prefers the fewest, longest pieces). nil if no complete cover
    /// exists within `maxSegments` using pieces of at least `minSegment` chars.
    private func segment(_ chars: [Character], minSegment: Int, maxSegments: Int) -> [String]? {
        if chars.isEmpty { return [] }
        guard maxSegments > 0 else { return nil }
        var end = chars.count
        while end >= minSegment {
            let prefix = String(chars[0 ..< end])
            if dictionary[prefix] != nil {
                let rest = Array(chars[end...])
                if rest.isEmpty { return [prefix] }
                if let tail = segment(rest, minSegment: minSegment, maxSegments: maxSegments - 1) {
                    return [prefix] + tail
                }
            }
            end -= 1
        }
        return nil
    }

    /// Spell-out is deliberately conservative: only runs that cannot plausibly
    /// be pronounced (no vowels) or look like acronyms (short all-caps) — long
    /// pronounceable proper nouns stay silent rather than becoming letter soup.
    private func shouldSpellOut(_ original: String) -> Bool {
        let lowered = original.lowercased()
        let hasVowel = lowered.contains { "aeiouy".contains($0) }
        if !hasVowel { return true }
        return original.count <= 5 && original.allSatisfy(\.isUppercase)
    }

    /// How each letter is NAMED aloud, en-GB ("zed", not "zee"; "aitch").
    ///
    /// ★ This table replaces the belief that "all 26 single-character dictionary
    /// keys are present". Measured 2026-08-11 against the real bundled dictionary:
    /// only **8** are (a e i j k n r s) — the rest are letters that happen to be
    /// words. Every other letter resolved to nothing and `joinedTokens` drops what
    /// it can't resolve, so they were silently unspoken: "M1K3" lost its "M" (which
    /// is what Kev heard), and "MCP" produced NO AUDIO AT ALL. A dropped phoneme
    /// leaves no trace anywhere, which is how this survived since the spike.
    ///
    /// Every spelling here was probed against the bundled dictionary before being
    /// chosen, so none of them are silently dropped in turn — that's the whole
    /// point, and `SpellOutLettersTests` re-measures it on every run rather than
    /// trusting this comment.
    /// "w" is two dictionary words — `doubleyou` is NOT a key (it only appeared to
    /// resolve when probed on its own, because that goes through the compound
    /// splitter, which `joinedTokens`' raw lookup does not).
    private static let letterNames: [Character: [String]] = [
        "a": ["aye"], "b": ["bee"], "c": ["cee"], "d": ["dee"], "e": ["ee"],
        "f": ["eff"], "g": ["gee"], "h": ["aitch"], "i": ["eye"], "j": ["jay"],
        "k": ["kay"], "l": ["el"], "m": ["em"], "n": ["en"], "o": ["oh"],
        "p": ["pee"], "q": ["queue"], "r": ["are"], "s": ["ess"], "t": ["tee"],
        "u": ["you"], "v": ["vee"], "w": ["double", "you"], "x": ["ex"],
        "y": ["why"], "z": ["zed"],
    ]

    /// The words that speak one character: its letter NAME when the dictionary can
    /// say it, otherwise the bare character.
    ///
    /// The fallback is not decoration — a dictionary that keys letters directly
    /// (the fallback tests' fake, or a future replacement dictionary) keeps
    /// working, and a letter outside the table (accented, non-Latin) behaves
    /// exactly as it did before. All-or-nothing per letter, so "w" never speaks as
    /// a bare "double".
    private func spelledWords(for char: Character) -> [String] {
        let lowered = Character(String(char).lowercased())
        if let name = Self.letterNames[lowered], name.allSatisfy({ dictionary[$0] != nil }) {
            return name
        }
        return [String(lowered)]
    }

    /// Per-character expansion: letters via their spoken names, digits via
    /// NumberSpeller.
    private func spellOutTokens(_ text: String, extraWords: [String]) -> [Int]? {
        var words: [String] = []
        for char in text {
            if char.isLetter {
                words.append(contentsOf: spelledWords(for: char))
            } else if let digit = NumberSpeller.digitWord(char) {
                words.append(digit)
            }
        }
        return joinedTokens(for: words + extraWords)
    }

    /// Dictionary tokens for each word, joined by the space token. Words the
    /// dictionary lacks are dropped; nil when nothing resolved.
    private func joinedTokens(for expansionWords: [String]) -> [Int]? {
        let groups = expansionWords.compactMap { dictionary[$0] }.filter { !$0.isEmpty }
        guard !groups.isEmpty else { return nil }
        return Array(groups.joined(separator: [Self.space]))
    }

    /// Model input tokens = [pad] + phonemes + [pad].
    public func modelTokens(_ text: String) -> [Int] {
        [Self.pad] + phonemeTokens(text) + [Self.pad]
    }

    /// Try the word as-is (keeps contractions like `don't`), then with surrounding
    /// apostrophes trimmed (handles quote-wrapped words like `'hello'`).
    private func lookup(_ word: String) -> [Int]? {
        if let hit = dictionary[word] { return hit }
        let trimmed = word.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        if trimmed != word, let hit = dictionary[trimmed] { return hit }
        return nil
    }

    /// Text-facing punctuation → vocab token. Prosody marks (combining tilde, arrows)
    /// are intentionally excluded — they come from the phonemizer, not raw text.
    public static let defaultPunctuation: [Character: Int] = [
        ";": 1, ":": 2, ",": 3, ".": 4, "!": 5, "?": 6,
        "—": 9, "…": 10, "\"": 11, "(": 12, ")": 13, "“": 14, "”": 15,
    ]
}
