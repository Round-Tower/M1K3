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
//  links, quoted words ("Translate 'Wo ist der Bahnhof?'"). On a long multi-line turn, the first or last line
//  whose language differs from the body's is the instruction ("Fasse das zusammen:" above an English email is
//  German); a pasted sign-off in another language at the end of an otherwise English turn would win too (known).
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
    /// How many earlier user turns a short turn looks back through for a readable one.
    static let carryLookback = 4

    /// The language a turn is written in, as a language code ("de", "pt", "ja", "zh-Hans"), or nil when
    /// the turn is too short, too mixed, or only a frame around someone else's words.
    public static func detect(_ turn: String) -> String? {
        let prose = proseOnly(turn)
        let lines = prose.split(whereSeparator: \.isNewline).map(String.init)
            .filter { $0.unicodeScalars.contains(where: \.properties.isAlphabetic) }
        // Characters undercount a CJK paste (one ideograph is a word), so length takes the letter weight too: an
        // English question above 190 characters of Japanese was read whole, and the Japanese won.
        let length = max(prose.count, letterWeight(of: prose))
        guard length > pasteThreshold, lines.count > 1 else { return agreed(prose) }
        // A long multi-line turn is an instruction around a paste. The instruction is the first or last line
        // whose language differs from the body's: "Fasse das zusammen:" above an English email is German.
        // The body is read from the middle lines alone: the recogniser weighs a text's opening heavily, and read
        // whole, one German line above six English ones came back German at 0.96. Two lines have no middle, so
        // the body is the longer of the two: with a nil body the first line always "differed" and won, and an
        // English article above a French instruction read English.
        let middle = lines.count == 2
            ? lines.max { letterWeight(of: $0) < letterWeight(of: $1) } ?? ""
            : lines.dropFirst().dropLast().joined(separator: "\n")
        let body = readable(middle).flatMap(recognise)
        for line in [lines[0], lines[lines.count - 1]] {
            if let read = readable(line).flatMap(recognise), read != body { return read }
        }
        return body
    }

    /// The read of a turn that is not a paste, kept only when its pieces agree. The recogniser weighs a text's
    /// opening heavily, so a short foreign opener outweighed the English after it ("Dziękuję bardzo — how do I say
    /// that properly?" read Polish at 0.99). A non-English read is split at clause punctuation and every piece long
    /// enough to read must read the same language, else the turn says nothing: a wrong "reply in X" is worse than
    /// none. English is never vetoed, since an English read adds no clause.
    private static func agreed(_ prose: String) -> String? {
        guard let text = readable(prose), let whole = recognise(text) else { return nil }
        guard whole != "en" else { return whole }
        let pieces = text.components(separatedBy: CharacterSet(charactersIn: "—–:;.!?\n"))
        for piece in pieces where letterWeight(of: piece) >= minimumLetters {
            if let read = recognise(piece), read != whole { return nil }
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
    static func resolve(
        turn: String, earlierTurns: [String] = [], deviceLanguage: String?
    ) -> (code: String, source: Source)? {
        if let read = detect(turn) { return (read, .person) }
        for earlier in earlierTurns.suffix(carryLookback).reversed() {
            if let read = detect(earlier) { return (read, .person) }
        }
        guard earlierTurns.isEmpty, let device = deviceLanguage.flatMap(fold) else { return nil }
        return (device, .device)
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

    /// What the shells wire (Mac and iPhone): the clause for this turn, the device language read from the
    /// person's preferred list (the app itself is English-only, so its own localisation says nothing).
    public static func liveClause(
        for turn: String, earlierTurns: [String] = [], defaults: UserDefaults = .standard
    ) -> String? {
        guard defaults.object(forKey: enabledKey) as? Bool ?? true else { return nil }
        return clause(for: turn, earlierTurns: earlierTurns, deviceLanguage: Locale.preferredLanguages.first)
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

    static func letterWeight(of text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            guard scalar.properties.isAlphabetic else { return total }
            return total + (isIdeographic(scalar) ? ideographWeight : 1)
        }
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
