//
//  ReplyLanguage.swift
//  M1K3Chat
//
//  Which language a turn wants back (Kev, 2026-11-19: "Brains need to reply in the users language ideally
//  pal... It will cause issues otherwise"). The persona is English and so is every brain's habit, so a
//  German question got an English answer, or a German one only when the brain felt like it.
//
//  Option 3 of the four Kev was shown: read EACH turn with Apple's recogniser, and when the turn is too short
//  to read ("ok", "danke"), fall back to the device's language. The answer rides `turnClauses` as one line
//  ("The person is writing in German: reply in German.") beside the age and egress clauses, never in the
//  cached persona prefix. English adds nothing, so an English prompt is byte for byte what it was.
//
//  Code fences, inline code and links are dropped before the read: they say nothing about the person.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-19, Confidence 0.7 (the recogniser is Apple's; the letter floor
//  and confidence floor are set on ReplyLanguageTests' lines, and the chateval `language` kind is the measure,
//  owed before the clause ships on). Prior: Unknown
//

import Foundation
import NaturalLanguage

public enum ReplyLanguage {
    /// Letters a turn needs before its own language beats the device's. A CJK or Hangul character counts
    /// `ideographWeight` letters: "日本で一番高い山は何ですか" is 13 characters and plainly Japanese.
    static let minimumLetters = 12
    static let ideographWeight = 3
    /// The recogniser's probability for its top language, below which the turn is called unreadable.
    static let minimumConfidence = 0.6

    /// The language a turn is written in, as a language code ("de", "pt", "ja", "zh-Hans"), or nil when
    /// the turn is too short or too mixed to say.
    public static func detect(_ turn: String) -> String? {
        // Quoted words are someone else's ("Translate 'Wo ist der Bahnhof?'"): read the turn without them,
        // unless that leaves too little to read (a turn that is only a quote).
        let whole = proseOnly(turn)
        let unquoted = withoutQuotes(whole)
        let prose = letterWeight(of: unquoted) >= minimumLetters ? unquoted : whole
        guard letterWeight(of: prose) >= minimumLetters else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(prose)
        guard let top = recognizer.languageHypotheses(withMaximum: 1).first,
              top.value >= minimumConfidence
        else { return nil }
        return fold(top.key.rawValue)
    }

    /// The turn's language when it can be read, else the device's (folded to its language code).
    public static func resolve(turn: String, deviceLanguage: String?) -> String? {
        detect(turn) ?? deviceLanguage.flatMap(fold)
    }

    /// The turn's reply-language line, or nil for English (and when nothing can be said).
    public static func clause(for turn: String, deviceLanguage: String?) -> String? {
        if let read = detect(turn) {
            guard read != "en" else { return nil }
            let name = name(of: read)
            return "The person is writing in \(name): reply in \(name)."
        }
        guard let device = deviceLanguage.flatMap(fold), device != "en" else { return nil }
        let name = name(of: device)
        return "This device is set to \(name): reply in \(name)."
    }

    /// The switch (`M1K3 -replyLanguage NO` turns it off for an A/B). On when unset.
    public static let enabledKey = "replyLanguage"

    /// What the shells wire (Mac and iPhone): the clause for this turn, the device language read from the
    /// person's preferred list (the app itself is English-only, so its own localisation says nothing).
    public static func liveClause(for turn: String, defaults: UserDefaults = .standard) -> String? {
        guard defaults.object(forKey: enabledKey) as? Bool ?? true else { return nil }
        return clause(for: turn, deviceLanguage: Locale.preferredLanguages.first)
    }

    /// "pt-BR" → "pt", "en-GB" → "en", "zh-Hans-CN" → "zh-Hans" (Chinese keeps its script: the two
    /// written forms are different replies).
    static func fold(_ tag: String) -> String? {
        let parts = tag.replacingOccurrences(of: "_", with: "-").split(separator: "-").map(String.init)
        guard let language = parts.first?.lowercased(), !language.isEmpty else { return nil }
        if language == "zh" {
            let script = parts.dropFirst().first { $0.count == 4 } ?? "Hans"
            return "zh-\(script.capitalized)"
        }
        return language
    }

    /// The language's English name, which every brain reads: "German", "Portuguese", "Japanese".
    static func name(of code: String) -> String {
        let english = Locale(identifier: "en")
        if code.hasPrefix("zh-") {
            let script = code.dropFirst(3)
            return script == "Hant" ? "Traditional Chinese" : "Simplified Chinese"
        }
        return english.localizedString(forLanguageCode: code) ?? code
    }

    /// The turn without fenced code, inline code or links.
    static func proseOnly(_ turn: String) -> String {
        var prose = turn
        for pattern in [#"```[\s\S]*?(```|$)"#, #"`[^`\n]*`"#, #"\b[a-zA-Z][a-zA-Z0-9+.-]*://\S+"#] {
            prose = prose.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return prose
    }

    /// The text without quoted spans: "…", “…”, „…“, «…», 「…」, and '…' only where the quote mark stands
    /// outside a word, so "don't" and "l'Australie" are not quotes.
    static func withoutQuotes(_ text: String) -> String {
        let patterns = [
            #""[^"\n]*""#, #"“[^”\n]*”"#, #"„[^“”\n]*[“”]"#, #"«[^»\n]*»"#, #"「[^」\n]*」"#,
            #"(?<!\p{L})['‘][^'’\n]+['’](?!\p{L})"#,
        ]
        return patterns.reduce(text) { $0.replacingOccurrences(of: $1, with: " ", options: .regularExpression) }
    }

    static func letterWeight(of text: String) -> Int {
        text.unicodeScalars.reduce(0) { total, scalar in
            guard scalar.properties.isAlphabetic else { return total }
            return total + (isIdeographic(scalar) ? ideographWeight : 1)
        }
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
