//
//  ReplyLanguage.swift
//  M1K3Chat
//
//  Which language a turn wants back (Kev, 2026-11-19: "Brains need to reply in the users language ideally
//  pal... It will cause issues otherwise"). The persona is English and so is every brain's habit, so a
//  German question got an English answer, or a German one only when the brain felt like it.
//
//  Option 3 of the four Kev was shown: read EACH turn with Apple's recogniser. A turn too short to read
//  ("ok", "danke") keeps the language of the person's last readable turn, and only the first turn of a chat
//  falls back to the device's language (an English speaker on a German Mac who types "thanks, got it" mid-chat
//  stays in English). The answer rides `turnClauses` as one line ("The person is writing in German: reply in
//  German.") beside the age and egress clauses, never in the cached persona prefix. English adds nothing, so
//  an English prompt is byte for byte what it was.
//
//  What the read skips, because it says nothing about the person's own language: code fences, inline code,
//  links, quoted words ("Translate 'Wo ist der Bahnhof?'"). On a multi-line turn, the first or last line whose
//  language differs from the body's is the instruction ("Fasse das zusammen:" above an English email is German);
//  a pasted sign-off in another language at the end of an otherwise English paste would win too (known). The clause
//  names only languages on `replyLanguages`, and romanised Arabic (Arabizi) says nothing.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-19, Confidence 0.7 (the recogniser is Apple's; the letter floor
//  and confidence floor are set on ReplyLanguageTests' lines, and the chateval `language` kind is the measure,
//  owed before the clause ships on). Prior: Unknown
//  Review: claude-opus-5-5, 2026-11-19 (pre-push review fold) — three false positives closed: a short turn
//  carries the last readable turn's language (the device only on a chat's first turn); a turn whose frame is
//  too short beside its quote is unreadable, not read as the quote; a long paste is read by its instruction
//  line (the first or last line that differs from the body). The confidence floor stays 0.6 (0.7 dropped a Spanish
//  fixture read 0.67 against Catalan); kana reads as Japanese whatever the recogniser says, `und` and
//  region-only Chinese tags fold correctly. Confidence 0.75.
//  Review: claude-opus-5-5, 2026-11-19 (challenger fold, 150-turn blind set) — three fixes, no threshold moved:
//  a turn that is not a paste keeps a non-English read only when every readable piece (split at —–:;.!? and
//  newlines) agrees, so a short foreign opener on an English question says nothing; a two-line paste's body is
//  its longer line, so the shorter instruction can differ and win; paste length is the larger of characters and
//  letter weight, so a CJK paste under an English question is a paste. Blind set 134/150 → 137/150, wrong-language
//  clauses 3 → 0, English false positives 2 → 0 (sc-zhs-03 still reads a Chinese question about a Python error as
//  English: no clause, missed); the 48 language fixtures still all read right. Confidence 0.75 (the blind set is
//  one author's lines; the agreement rule trades a missed clause for a wrong one, on purpose).
//  Review: claude-opus-5-5, 2026-11-19 (round 2, blind batch 2) — four rules. (1) An allowlist of 29 languages: the
//  recogniser read Hinglish, romaji, Taglish and Finglish as Indonesian, so id/ms/tl and anything unlisted say nothing.
//  (2) An Arabizi guard: two or more words, and 15% of them, with a digit between lowercase letters ("a3raf") say
//  nothing; it trips on 3 Arabizi turns and on no fixture or batch-1 turn. (3) The instruction rule covers every
//  multi-line turn, not only pastes over 280: the body is the heaviest blank-line block once the first and last lines
//  are set aside. Under the paste threshold two guards keep it from naming a wrong language: a Latin-script edge
//  wins only when it reads English, and of two lines the heavier must double the other to be the body (an English
//  question a little heavier than the Arabic message it asked about read Arabic). (4) A comma splits pieces for the
//  agreement rule. Batch 2 78 → 89/105 (ratchet scoring), wrong-language clauses on English turns 1 → 0, romanised
//  wrong reads 11 → 0 (all now no clause); batch 1 unchanged at 137/150, turn for turn; the 48 fixtures all read
//  right. Both batches are now tuned against. Confidence 0.7 (the two-line doubling rule is a judgment call, and a
//  native question heavier than a short English line it asks about is still read English: no clause, missed).
//  Review: claude-opus-5-5, 2026-11-19 (review fold) — four fixes. (1) A declined turn (romanised, or read off the
//  allowlist) stops `resolve`: no older turn and no device stands in for it, and the device names only listed
//  languages (Arabizi on a German Mac was told "This device is set to German"; an Indonesian Mac named Indonesian).
//  (2) Under the paste threshold a non-Latin edge that does not ask loses to an English line that does ("…what does it
//  say?" above an Arabic greeting read Arabic); only an English question dismisses, so the rule can only remove a
//  clause. (3) A Han piece no longer vetoes a Han whole ("相対性理論" read Chinese inside a Japanese turn). (4) The
//  Arabizi guard counts a digit only beside a vowel and never in "X2X" ("e2e", "p2p", "k8s", "mp3s" tripped it).
//  Skipped, with the reasons in the fold's report: short pieces from "3.12"-style splits (six probes all read right),
//  and an English sign-off line on a short foreign turn (same shape as an English question without "?" over a
//  foreign paste, b2-cj-13; a fix there would name a wrong language). Batches 137/150, 89/105, 103/125 (was 101).
//  Confidence 0.7 (the question-mark signal is cheap and only ever removes a clause; b3-pa-40, with no "?", stays).
//  Review: Kev + claude-opus-5-5, 2026-11-20 — `liveClause(voiceLanguage:)`: a voice turn falls back to the voice's
//  language (`spokenLanguage`, English), never the device's. The challenger on the voice design found a German Mac
//  answering a short voice turn in German through the English Kokoro voice. Confidence 0.85.
//

import Foundation
import NaturalLanguage

public enum ReplyLanguage {
    /// Letters a turn needs before its own language counts. A CJK or Hangul character counts
    /// `ideographWeight` letters: "日本で一番高い山は何ですか" is 13 characters and plainly Japanese.
    static let minimumLetters = 12
    static let ideographWeight = 3
    /// The recogniser's probability for its top language, below which the turn is called unreadable: a
    /// wrong "reply in X" is worse than none. 0.7 was tried and dropped a plain Spanish question (es 0.67 against
    /// Catalan 0.33); at 0.6 the language fixtures' 48 prompts all read right.
    static let minimumConfidence = 0.6
    /// A turn longer than this, over more than one line, is read by its instruction line, not its body. Length is
    /// the larger of characters and letter weight: 150 characters of Chinese is a paste, not a question.
    static let pasteThreshold = 280
    /// How many times a short two-line turn's heavier line must outweigh the other to be its body (a paste).
    static let pasteOutweighs = 2
    /// How many earlier user turns a short turn looks back through for a readable one.
    static let carryLookback = 4
    /// The only languages a read may name. A wrong "reply in X" is the worst outcome, and the recogniser reads
    /// romanised text (Hinglish, romaji, Taglish, Finglish) as Indonesian with near certainty, so Indonesian, Malay
    /// and Tagalog are left out on purpose, as is every language not listed: a read outside the list says nothing
    /// and the brain answers as it would without the clause. The list grows only with measurement: a language joins
    /// when its reads, and the romanised turns that land on it, have been checked on a blind set.
    static let replyLanguages: Set<String> = [
        "en", "de", "fr", "es", "pt", "it", "nl", "sv", "da", "nb", "fi", "pl", "cs", "ro", "hu", "tr", "el", "ru",
        "uk", "he", "ar", "fa", "hi", "ja", "zh-Hans", "zh-Hant", "ko", "th", "vi",
    ]
    /// The share of a Latin-script turn's words that must carry a digit between letters ("a3raf", "bta3y") before
    /// it is called Arabizi, with at least two such words: one model name or numeronym ("mp3s") is not enough.
    static let romanisedShare = 0.15

    /// The language a turn is written in, as a language code ("de", "pt", "ja", "zh-Hans"), or nil when
    /// the turn is too short, too mixed, or only a frame around someone else's words.
    public static func detect(_ turn: String) -> String? {
        if case let .language(code) = reading(turn) { return code }
        return nil
    }

    /// What a read of one turn found: a language the clause may name, nothing (too short, too mixed, only a frame),
    /// or a language the read declines to name (romanised, or off `replyLanguages`). A declined turn is a signal, not
    /// silence: the device or an older turn must not stand in for it.
    enum Reading: Equatable {
        case language(String)
        case unreadable
        case declined
    }

    static func reading(_ turn: String) -> Reading {
        let prose = proseOnly(turn)
        // Arabizi reads as Spanish or Polish with confidence: its digits-for-letters say it is not either.
        guard !isRomanised(prose) else { return .declined }
        guard let read = read(prose) else { return .unreadable }
        return replyLanguages.contains(read) ? .language(read) : .declined
    }

    /// The read before the allowlist.
    private static func read(_ prose: String) -> String? {
        let lines = prose.split(whereSeparator: \.isNewline).map(String.init)
            .filter { $0.unicodeScalars.contains(where: \.properties.isAlphabetic) }
        guard lines.count > 1 else { return agreed(prose) }
        // Characters undercount a CJK paste (one ideograph is a word), so length takes the letter weight too: an
        // English question above 190 characters of Japanese was read whole, and the Japanese won.
        let isPaste = max(prose.count, letterWeight(of: prose)) > pasteThreshold
        // Two short lines of similar weight could be a question over a paste or a paste over a question: an English
        // question a little heavier than the Arabic message it asks about read Arabic. Neither line is the body then,
        // and the turn is read whole.
        if !isPaste, lines.count == 2 {
            let weights = lines.map(letterWeight(of:)).sorted()
            guard weights[1] >= pasteOutweighs * weights[0] else { return agreed(prose) }
        }
        // A multi-line turn is an instruction around a paste, long or short. The instruction is the first or last
        // line whose language differs from the body's: "Fasse das zusammen:" above an English email is German, and
        // so is a Japanese question under a two-line English notice (read whole, the English won 14 of 15 times).
        let body = readable(bodyText(of: prose, lines: lines)).flatMap(recognise)
        for (index, line) in [(0, lines[0]), (lines.count - 1, lines[lines.count - 1])] {
            guard let edge = readable(line).flatMap(recognise), edge != body else { continue }
            if isPaste || edge == "en" { return edge }
            // Under the paste threshold, a Latin-script edge wins only when it reads English (which adds no clause):
            // the recogniser confuses Latin-script languages on one short line ("Merci beaucoup!" above an English
            // question is an opener, not an instruction), while another script anchors its read. A non-Latin edge
            // that does not ask, beside an English line that does, is what the person is asking about or a thank-you,
            // not the instruction: "…what does it say?" above an Arabic greeting is English (review fold, 2026-11-19).
            // Only an English question dismisses it, so the dismissal can only ever remove a clause, never name one,
            // and a Japanese question at the other end keeps its Japanese opener's read.
            guard !isMostlyLatin(line) else { continue }
            let englishAsks = lines.indices.contains { other in
                other != index && asks(lines[other]) && readable(lines[other]).flatMap(recognise) == "en"
            }
            if englishAsks, !asks(line) { continue }
            return edge
        }
        // Nothing differs: a paste is its body, a short turn is read whole under the agreement rule.
        return isPaste ? body : agreed(prose)
    }

    /// The body of a multi-line turn: the heaviest block of lines (blocks split at blank lines) once the first and
    /// last lines are set aside, since the recogniser weighs a text's opening heavily (one German line above six
    /// English ones read German at 0.96). Two lines leave nothing aside, so the body is the heavier line: with a nil
    /// body the first line always "differed" and won, and an English article above a French instruction read English.
    private static func bodyText(of prose: String, lines: [String]) -> String {
        guard lines.count > 2 else { return lines.max { letterWeight(of: $0) < letterWeight(of: $1) } ?? "" }
        // Each lettered line with the block it sits in: a blank line starts a new block.
        var block = 0
        var placed: [(block: Int, line: String)] = []
        for raw in prose.components(separatedBy: .newlines) {
            if raw.trimmingCharacters(in: .whitespaces).isEmpty { block += 1; continue }
            if raw.unicodeScalars.contains(where: \.properties.isAlphabetic) { placed.append((block, raw)) }
        }
        let blocks = Dictionary(grouping: placed.dropFirst().dropLast(), by: \.block).values
            .map { $0.map(\.line).joined(separator: "\n") }
        return blocks.max { letterWeight(of: $0) < letterWeight(of: $1) } ?? ""
    }

    /// The read of a turn that is not a paste, kept only when its pieces agree. The recogniser weighs a text's
    /// opening heavily, so a short foreign opener outweighed the English after it ("Dziękuję bardzo — how do I say
    /// that properly?" read Polish at 0.99). A non-English read is split at clause punctuation and every piece long
    /// enough to read must read the same language, else the turn says nothing: a wrong "reply in X" is worse than
    /// none. English is never vetoed, since an English read adds no clause.
    private static func agreed(_ prose: String) -> String? {
        guard let text = readable(prose), let whole = recognise(text) else { return nil }
        guard whole != "en" else { return whole }
        let pieces = text.components(separatedBy: CharacterSet(charactersIn: "—–:;,.!?\n"))
        for piece in pieces where letterWeight(of: piece) >= minimumLetters {
            // A few Han characters cannot tell Japanese from either Chinese ("相対性理論" read Chinese inside a
            // Japanese turn), so a Han piece only vetoes a Han whole by a different script family, never by another
            // Han read; the whole's read, with its kana, is the better one.
            if let read = recognise(piece), read != whole, !(isHanLanguage(read) && isHanLanguage(whole)) {
                return nil
            }
        }
        return whole
    }

    /// The recogniser's read of readable prose, under the confidence floor, folded to a language code.
    private static func recognise(_ prose: String) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(prose)
        guard let top = recognizer.languageHypotheses(withMaximum: 1).first,
              top.value >= minimumConfidence
        else { return nil }
        // Kana is only ever Japanese; a kanji-heavy Japanese line can read as Chinese.
        if top.key.rawValue.hasPrefix("zh"), prose.unicodeScalars.contains(where: isKana) { return "ja" }
        return fold(top.key.rawValue)
    }

    /// Where a reply language came from: the turn (or the person's last readable turn), or the device.
    enum Source: Equatable {
        case person, device
    }

    /// The turn's language when it can be read, else the person's last readable turn's, else, on a chat's
    /// first turn only, the device's. `earlierTurns` are the person's own earlier turns, oldest first.
    /// A declined turn (romanised, or a language off the list) stops the search: the person is writing something the
    /// clause will not name, so neither an older turn nor the device speaks for them (review fold, 2026-11-19: Arabizi
    /// on a German Mac was told the device is set to German). The device names only listed languages too.
    static func resolve(
        turn: String, earlierTurns: [String] = [], deviceLanguage: String?
    ) -> (code: String, source: Source)? {
        for candidate in [turn] + earlierTurns.suffix(carryLookback).reversed() {
            switch reading(candidate) {
            case let .language(code): return (code, .person)
            case .declined: return nil
            case .unreadable: continue
            }
        }
        guard earlierTurns.isEmpty, let device = deviceLanguage.flatMap(fold), replyLanguages.contains(device)
        else { return nil }
        return (device, .device)
    }

    /// The language the PERSON is writing or speaking in, from this turn or their last readable one; never the
    /// device's. Seeds the spoken answer's language (`SpokenAnswerLanguage.begin(seed:)`). Nil when unknown.
    public static func personLanguage(turn: String, earlierTurns: [String] = []) -> String? {
        guard let resolved = resolve(turn: turn, earlierTurns: earlierTurns, deviceLanguage: nil),
              resolved.source == .person else { return nil }
        return resolved.code
    }

    /// The turn's reply-language line, or nil for English (and when nothing can be said).
    public static func clause(for turn: String, earlierTurns: [String] = [], deviceLanguage: String?) -> String? {
        guard let resolved = resolve(turn: turn, earlierTurns: earlierTurns, deviceLanguage: deviceLanguage),
              resolved.code != "en"
        else { return nil }
        let name = name(of: resolved.code)
        switch resolved.source {
        case .person: return "The person is writing in \(name): reply in \(name)."
        case .device: return "This device is set to \(name): reply in \(name)."
        }
    }

    /// The switch (`M1K3 -replyLanguage NO` turns it off for an A/B). On when unset.
    public static let enabledKey = "replyLanguage"

    /// The language voice mode speaks: English until voice is localised (the shells pass it as a voice
    /// turn's `voiceLanguage`).
    public static let spokenLanguage = "en"

    /// What the shells wire (Mac and iPhone): the clause for this turn, the device language read from the
    /// person's preferred list (the app itself is English-only, so its own localisation says nothing).
    ///
    /// `voiceLanguage` is set on a voice turn. It replaces the device as the fallback for a turn too short to
    /// read, so "hi" in voice mode on a German Mac is answered in the voice's language, not in German read
    /// aloud by an English voice. What the person actually said still wins.
    public static func liveClause(
        for turn: String, earlierTurns: [String] = [], voiceLanguage: String? = nil,
        deviceLanguage: String? = Locale.preferredLanguages.first, defaults: UserDefaults = .standard
    ) -> String? {
        guard defaults.object(forKey: enabledKey) as? Bool ?? true else { return nil }
        return clause(for: turn, earlierTurns: earlierTurns, deviceLanguage: voiceLanguage ?? deviceLanguage)
    }

    /// The part of the prose that speaks for the person, or nil when that part is too short to read.
    static func readable(_ focus: String) -> String? {
        let unquoted = withoutQuotes(focus)
        // A turn that is only a quote is read as written; a frame beside a quote is read alone, and a frame
        // too short to read is unreadable ("Translate 'Wo ist der Bahnhof?'" says nothing about German).
        let hasFrame = unquoted.unicodeScalars.contains(where: \.properties.isAlphabetic)
        let text = hasFrame ? unquoted : focus
        return letterWeight(of: text) >= minimumLetters ? text : nil
    }

    /// "pt-BR" → "pt", "en-GB" → "en", "zh-Hans-CN" → "zh-Hans", "zh-TW" → "zh-Hant" (Chinese keeps its
    /// script: the two written forms are different replies). "und" (undetermined) is nil.
    static func fold(_ tag: String) -> String? {
        let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let language = parts.first?.lowercased(), !language.isEmpty, language != "und" else { return nil }
        guard language == "zh" else { return language }
        let rest = parts.dropFirst()
        if let script = rest.first(where: { $0.count == 4 }) { return "zh-\(script.capitalized)" }
        let traditional = rest.contains { ["TW", "HK", "MO"].contains($0.uppercased()) }
        return traditional ? "zh-Hant" : "zh-Hans"
    }

    /// The language's English name, which every brain reads: "German", "Portuguese", "Japanese".
    static func name(of code: String) -> String {
        if code.hasPrefix("zh-") {
            return code.hasSuffix("Hant") ? "Traditional Chinese" : "Simplified Chinese"
        }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// The turn without fenced code, inline code or links.
    static func proseOnly(_ turn: String) -> String {
        var prose = turn
        for pattern in [#"```[\s\S]*?(```|$)"#, #"`[^`\n]*`"#, #"\b[a-zA-Z][a-zA-Z0-9+.-]*://\S+"#] {
            prose = prose.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return prose
    }

    /// The text without quoted spans: "…", “…”, „…“, «…», »…«, 「…」, 『…』, and '…' only where the quote
    /// mark stands outside a word, so "don't" and "l'Australie" are not quotes.
    static func withoutQuotes(_ text: String) -> String {
        let patterns = [
            #""[^"\n]*""#, #"“[^”\n]*”"#, #"„[^“”\n]*[“”]"#, #"«[^»\n]*»"#, #"»[^«\n]*«"#, #"「[^」\n]*」"#,
            #"『[^』\n]*』"#, #"(?<!\p{L})['‘][^'’\n]+['’](?!\p{L})"#,
        ]
        return patterns.reduce(text) { $0.replacingOccurrences(of: $1, with: " ", options: .regularExpression) }
    }

    /// Arabizi: a mostly Latin-script turn where at least two words, and `romanisedShare` of them, carry a single
    /// digit between two lowercase letters ("a3raf", "ta2s", "bta3y"). Narrow on purpose: a word-initial digit
    /// ("7aga") is not counted, since "3rd" and "4K" look the same, and a run of digits ("i18n", "l10n") never counts.
    /// Arabizi's digits stand for consonants, so one sits beside a vowel; a digit between two consonants ("p2p",
    /// "k8s", "mp3s") is an initialism, and "e2e" (the same letter either side of a 2: "end to end") a numeronym.
    static func isRomanised(_ text: String) -> Bool {
        guard isMostlyLatin(text) else { return false }
        let words = text.split { !($0.isLetter || $0.isNumber) }
        let romanised = words.filter { word in
            let chars = Array(word)
            return chars.indices.dropFirst().dropLast().contains { index in
                let before = chars[index - 1], after = chars[index + 1]
                guard chars[index].isASCII, chars[index].isNumber, before.isLowercase, after.isLowercase else {
                    return false
                }
                let isNumeronym = chars.count == 3 && before == after
                return !isNumeronym && (isVowel(before) || isVowel(after))
            }
        }
        return romanised.count >= 2 && Double(romanised.count) >= romanisedShare * Double(words.count)
    }

    /// Whether most of the text's letters are Latin script.
    static func isMostlyLatin(_ text: String) -> Bool {
        var latin = 0
        var other = 0
        for scalar in text.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x41 ... 0x24F, 0x1E00 ... 0x1EFF: latin += 1
            default: other += 1
            }
        }
        return latin > other
    }

    static func letterWeight(of text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            guard scalar.properties.isAlphabetic else { return total }
            return total + (isIdeographic(scalar) ? ideographWeight : 1)
        }
    }

    /// Whether the text carries a question mark in any script: "?", "？" or Arabic "؟".
    static func asks(_ text: String) -> Bool {
        text.contains { "?？؟".contains($0) }
    }

    private static func isVowel(_ letter: Character) -> Bool {
        "aeiouy".contains(letter)
    }

    private static func isHanLanguage(_ code: String) -> Bool {
        code == "ja" || code.hasPrefix("zh-")
    }

    private static func isKana(_ scalar: Unicode.Scalar) -> Bool {
        (0x3040 ... 0x30FF).contains(scalar.value)
    }

    private static func isIdeographic(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040 ... 0x30FF, 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF, 0xAC00 ... 0xD7AF, 0xF900 ... 0xFAFF:
            true
        default:
            false
        }
    }
}
