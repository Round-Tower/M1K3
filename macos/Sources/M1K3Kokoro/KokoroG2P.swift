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
//  Review: Kev + claude-opus-5.5, 2026-11-15 (#837) — the case rescue: after the lowercase
//  dictionary hit and the house lexicon miss, the word as written and then its title case
//  are tried ("I'm", "Abuja", "Alzheimer's", "iOS": 4,306 misaki-gb keys exist only with
//  capitals), and inflection bases try title case too ("Abujas"). Every word that hits
//  today keeps its tokens (KokoroG2PCaseTests pins "Polish", "AI", house words). Confidence
//  0.85 (tests through the bundled pipeline; how the rescued words sound is verify-by-ear).
//  Review: Kev + claude-opus-5.5, 2026-11-15 (#838 slice 2) — numbers and symbols the way
//  people say them: the walker carries one word of context each way, reads a sign or
//  currency symbol into its number, takes one ':' or '/' between digits into the run,
//  says "to" for a dash between two numbers (its own caption word) and leaves dash
//  chains (dates) alone; `SpokenNumbers` decides the words. A lone "I" stays the pronoun
//  unless a capitalised cue leads. Every rule is pinned against the bundled dictionary
//  (KokoroG2PSpokenTests, SpokenNumbersTests). Confidence 0.8: tests prove the tokens;
//  the round trip (slice 1) and Kev's ear prove the sound.
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

/// Which link of the fallback chain spoke a word (#838 slice 1): the share that reaches
/// `.letterToSound` on a corpus is the hard-word rate, measured instead of guessed.
public enum G2PSource: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case dictionary, house, cased, inflection, compound, spellOut, letterToSound
    /// A digit run read by NumberSpeller / SpokenNumbers (ordinals, money, ranges…).
    case number
    /// A Roman numeral read after a cue ("Henry VIII").
    case roman
    /// Nothing resolved: the word is silent.
    case silent
}

/// Token assembly plus the word boundaries that produced it.
public struct G2PResult: Sendable, Equatable {
    public let tokens: [Int]
    public let words: [G2PWord]
    /// Parallel to `words`: the fallback that resolved each one (empty when the
    /// result was built by hand).
    public let sources: [G2PSource]

    public init(tokens: [Int], words: [G2PWord], sources: [G2PSource] = []) {
        self.tokens = tokens
        self.words = words
        self.sources = sources
    }

    /// How many words each fallback spoke.
    public var sourceCounts: [G2PSource: Int] {
        sources.reduce(into: [:]) { $0[$1, default: 0] += 1 }
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
    ///
    /// #838: the walker also carries one word of context each way (the previous word
    /// run, reset by punctuation, and a peek at the next) for the rules that need it
    /// ("1500 people" is a count, "Henry VIII" a king), reads a leading sign or
    /// currency symbol into the number it qualifies ("-5", "£5"), and speaks a dash
    /// between two numbers as "to" (its own caption word over the dash).
    private func assemble(_ text: String, cap: Int?) -> G2PResult {
        var tokens: [Int] = []
        var words: [G2PWord] = []
        var sources: [G2PSource] = []
        var prevWasToken = false
        var offset = 0 // running UTF-16 offset into the original text
        let chars = Array(text)
        let charCount = chars.count
        var index = 0
        var previousWord: String?
        var pendingUnit: [String] = [] // "£5 million": "pounds" waits for "million"

        /// Appends one caption word; false when the cap stops the walk.
        func emit(_ toks: [Int]?, _ textRange: Range<Int>, _ source: G2PSource) -> Bool {
            guard let toks, !toks.isEmpty else {
                // OOV: no phonemes, no space — an empty token range at the
                // current position keeps the word addressable for timing.
                words.append(G2PWord(textRange: textRange, tokenRange: tokens.count ..< tokens.count))
                sources.append(.silent)
                return true
            }
            let needed = (prevWasToken ? 1 : 0) + toks.count
            if let cap, tokens.count + needed > cap { return false }
            if prevWasToken { tokens.append(Self.space) }
            let tokenStart = tokens.count
            tokens.append(contentsOf: toks)
            words.append(G2PWord(textRange: textRange, tokenRange: tokenStart ..< tokens.count))
            sources.append(source)
            prevWasToken = true
            return true
        }

        while index < charCount {
            let char = chars[index]
            let prefix = numericPrefix(chars, at: index)
            if prefix != nil || char.isLetter || char.isASCIIDigit {
                let runStart = prefix == nil ? index : index + 1
                let run = scanRun(chars, from: runStart, previous: previousWord)
                let width = (prefix == nil ? 0 : char.utf16.count) + run.utf16Count
                let textRange = offset ..< offset + width
                index = run.end
                offset += width
                let next = peekWord(chars, from: run.end)
                let waiting = pendingUnit // set by the previous run only when THIS run is its scale word
                pendingUnit = []
                var source = G2PSource.silent
                var toks = resolveTokens(for: run, prefix: prefix, previous: previousWord, next: next,
                                         pendingUnit: &pendingUnit, source: &source)
                if !waiting.isEmpty, let unit = joinedTokens(for: waiting), let base = toks {
                    toks = base + [Self.space] + unit
                }
                guard emit(toks, textRange, source) else { break }
                previousWord = run.text
            } else if let dashWord = dashWord(chars, at: index) {
                let width = char.utf16.count
                guard emit(joinedTokens(for: [dashWord]), offset ..< offset + width, .number) else { break }
                offset += width
                index += 1
                previousWord = dashWord
            } else if char == " " || char == "\n" || char == "\t" || char == "\r" {
                offset += 1 // whitespace → implicit space, emitted only before the next word
                index += 1
            } else if let tok = punctuation[char] {
                if let cap, tokens.count + 1 > cap { break }
                tokens.append(tok)
                prevWasToken = true
                offset += char.utf16.count
                index += 1
                previousWord = nil
                pendingUnit = []
            } else {
                offset += char.utf16.count // unknown character → skip
                index += 1
            }
        }
        return G2PResult(tokens: tokens, words: words, sources: sources)
    }

    /// A sign or currency symbol that belongs to the number after it.
    private enum NumericPrefix: Equatable {
        case minus
        case currency(Character)
    }

    /// "-5" / "−5" at the start of a number (not between two: that's a range or a
    /// subtraction), and "£5" / "$20" / "€3.50".
    private func numericPrefix(_ chars: [Character], at index: Int) -> NumericPrefix? {
        let char = chars[index]
        guard index + 1 < chars.count, chars[index + 1].isASCIIDigit else { return nil }
        if SpokenNumbers.isCurrencySymbol(char) { return .currency(char) }
        guard char == "-" || char == "\u{2212}" else { return nil }
        if index == 0 { return .minus }
        let before = chars[index - 1]
        return before.isWhitespace || "([{\"“'/".contains(before) ? .minus : nil
    }

    /// The word a dash speaks between two numbers: "to" for a range ("4-7",
    /// "1990–2000", "1990 – 2000"), "minus" for U+2212 ("10−3"). A chain of
    /// separators (an ISO date, "10:30-11:00") is left as it was.
    private func dashWord(_ chars: [Character], at index: Int) -> String? {
        let char = chars[index]
        guard char == "-" || char == "–" || char == "\u{2212}" else { return nil }
        if index > 0, index + 1 < chars.count, chars[index - 1].isASCIIDigit, chars[index + 1].isASCIIDigit {
            guard separatorCount(chars, around: index) == 1 else { return nil }
            return char == "\u{2212}" ? "minus" : SpokenNumbers.rangeWord
        }
        // A spaced en dash between two numbers: "1990 – 2000".
        guard char == "–",
              index >= 2, chars[index - 1] == " ", chars[index - 2].isASCIIDigit,
              index + 2 < chars.count, chars[index + 1] == " ", chars[index + 2].isASCIIDigit else { return nil }
        return SpokenNumbers.rangeWord
    }

    private static let separators: Set<Character> = [":", "/", "-", "–", "\u{2212}"]

    /// How many separators sit between digits in the numeric chain around `index`
    /// (digits, '.', ',' and separators): 1 for "4-7" or "10:30", 2 for "2026-11-15".
    private func separatorCount(_ chars: [Character], around index: Int) -> Int {
        func inChain(_ char: Character) -> Bool {
            char.isASCIIDigit || char == "." || char == "," || Self.separators.contains(char)
        }
        var lower = index
        while lower > 0, inChain(chars[lower - 1]) {
            lower -= 1
        }
        var upper = index
        while upper + 1 < chars.count, inChain(chars[upper + 1]) {
            upper += 1
        }
        var count = 0
        for position in lower ... upper where Self.separators.contains(chars[position]) {
            if position > lower, position < upper,
               chars[position - 1].isASCIIDigit, chars[position + 1].isASCIIDigit
            {
                count += 1
            }
        }
        return count
    }

    /// The next word after `end`, past spaces only (any punctuation in between → nil).
    private func peekWord(_ chars: [Character], from end: Int) -> String? {
        var index = end
        while index < chars.count, chars[index] == " " || chars[index] == "\t" {
            index += 1
        }
        var word = ""
        while index < chars.count, chars[index].isLetter || chars[index] == "'" {
            word.append(chars[index])
            index += 1
        }
        return word.isEmpty ? nil : word
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
    /// word for timing. #838: one ':' or '/' between digits joins the run ("10:30",
    /// "3/4") when it is the chain's only separator, and after "Elements" a Roman
    /// numeral takes its proposition ("I.47").
    private func scanRun(_ chars: [Character], from start: Int, previous: String?) -> WordRun {
        var end = start
        var utf16Count = 0
        var containsDigit = false
        var containsLetter = false
        while end < chars.count {
            let runChar = chars[end]
            let digitBefore = end > start && chars[end - 1].isASCIIDigit
            let digitAfter = end + 1 < chars.count && chars[end + 1].isASCIIDigit
            if runChar.isLetter || runChar == "'" {
                containsLetter = true
            } else if runChar.isASCIIDigit {
                containsDigit = true
            } else if runChar == "." || runChar == "," {
                let euclid = runChar == "." && digitAfter && previous?.lowercased() == "elements"
                    && SpokenNumbers.romanValue(String(chars[start ..< end])) != nil
                guard (digitBefore && digitAfter) || euclid else { break }
            } else if runChar == ":" || runChar == "/" {
                guard digitBefore, digitAfter, !containsLetter,
                      separatorCount(chars, around: end) == 1 else { break }
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
    private func resolveTokens(for run: WordRun, prefix: NumericPrefix?, previous: String?, next: String?,
                               pendingUnit: inout [String], source: inout G2PSource) -> [Int]?
    {
        if run.containsDigit {
            source = .number
            // House names first: "M1K3" is pronounced "Mike" (the
            // kill-or-commit ruling, 2026-08-16) — not spelled out. Only when
            // no unit or sign rode the run; "15°C" never reaches the lexicon.
            if run.unitWords.isEmpty, prefix == nil, let house = houseTokens(run.text.lowercased()) {
                source = .house
                return house
            }
            if case let .currency(symbol) = prefix, run.unitWords.isEmpty,
               let money = SpokenNumbers.currency(symbol: symbol, literal: run.text)
            {
                if let next, SpokenNumbers.isScaleWord(next), money.tail.isEmpty {
                    pendingUnit = money.unit
                    return joinedTokens(for: money.amount)
                }
                return joinedTokens(for: money.all)
            }
            let sign = prefix == .minus ? ["minus"] : []
            if let words = numericWords(run, signed: !sign.isEmpty, previous: previous, next: next) {
                return joinedTokens(for: sign + words + run.unitWords)
            }
            // Mixed alphanumeric ("V2X7") → spell out per character.
            source = .spellOut
            return spellOutTokens(run.text, extraWords: run.unitWords, signWords: sign)
        }
        if let roman = SpokenNumbers.roman(run.text, previous: previous, next: next) {
            source = .roman
            return joinedTokens(for: roman)
        }
        let raw = run.text.lowercased()
        let chain: [(G2PSource, () -> [Int]?)] = [
            (.dictionary, { lookup(raw) }),
            (.house, { houseTokens(raw) }),
            (.cased, { casedLookup(run.text, lowered: raw) }),
            (.inflection, { inflectedTokens(raw) }),
            (.compound, { compoundTokens(raw) }),
            // A run that should be spelled out STOPS here, spoken or not: letter-to-sound
            // never guesses at "zzzqx" (an empty hit is a silent word).
            (.spellOut, { shouldSpellOut(run.text) ? spellOutTokens(run.text, extraWords: []) ?? [] : nil }),
            (.letterToSound, { LetterToSound.tokens(for: raw) }),
        ]
        for (link, resolve) in chain {
            if let hit = resolve() {
                source = link
                return hit
            }
        }
        return nil
    }

    /// The #838 readings of a digit run, most specific first; nil → spell it out.
    private func numericWords(_ run: WordRun, signed: Bool, previous: String?, next: String?) -> [String]? {
        let text = run.text
        if let ordinal = SpokenNumbers.ordinal(text) { return ordinal }
        if text.contains(":") { return SpokenNumbers.colon(text) }
        if text.contains("/") { return SpokenNumbers.fraction(text) }
        if let version = SpokenNumbers.version(text) { return version }
        if previous?.lowercased() == "elements", let dot = text.firstIndex(of: ".") {
            let book = String(text[..<dot])
            if let euclid = SpokenNumbers.euclid(book: book, proposition: String(text[text.index(after: dot)...])) {
                return euclid
            }
        }
        // A year needs a year's context: "1500 people" is a count; an amount with a
        // sign or a unit ("-1500", "2000%") is never a year.
        let year = !signed && run.unitWords.isEmpty && SpokenNumbers.readsAsYear(previous: previous, next: next)
        return NumberSpeller.numberWords(text, yearReading: year)
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
        return lookup(stem) ?? houseTokens(stem) ?? lookup(Self.titleCased(stem)) ?? compoundTokens(stem)
    }

    /// The case rescue (#837): misaki-gb keys 4,306 words only with capitals ("I'm",
    /// "Abuja", "Alzheimer's", "iOS"), which the lowercased lookup can never reach. Tried
    /// AFTER the lowercase hit and the house lexicon, so every dictionary or house hit keeps
    /// today's tokens ("Polish" at a sentence start stays "polish"). Only dictionary misses
    /// change: their own capitalised entry now beats the guess they got (inflection for 18
    /// keys such as "Phillips", else compound, spell-out, letter-to-sound or silence). The
    /// word as written first ("iOS", "ASEAN"), then title case ("i'm" → "I'm").
    private func casedLookup(_ original: String, lowered: String) -> [Int]? {
        if original != lowered, let hit = lookup(original) { return hit }
        let title = Self.titleCased(lowered)
        if title != original, title != lowered, let hit = lookup(title) { return hit }
        return nil
    }

    /// First character upper, the rest as given (lowercase in every caller).
    private static func titleCased(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
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
    private func spellOutTokens(_ text: String, extraWords: [String], signWords: [String] = []) -> [Int]? {
        var words: [String] = signWords
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
    /// dictionary lacks are dropped; nil when nothing resolved. A "," word is the
    /// comma's pause token, attached like written punctuation (no space before it):
    /// the digit groups and the Euclid reference (#838).
    private func joinedTokens(for expansionWords: [String]) -> [Int]? {
        var out: [Int] = []
        var spoke = false
        for word in expansionWords {
            if word == ",", let comma = punctuation[","] {
                if spoke { out.append(comma) }
                continue
            }
            guard let toks = dictionary[word], !toks.isEmpty else { continue }
            if !out.isEmpty { out.append(Self.space) }
            out.append(contentsOf: toks)
            spoke = true
        }
        return spoke ? out : nil
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
