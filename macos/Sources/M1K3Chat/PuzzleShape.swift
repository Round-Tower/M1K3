//
//  PuzzleShape.swift
//  M1K3Chat
//
//  Does a turn read as a multi-step reasoning problem? The speed tiers (Mini, Lil) think only on an
//  explicit "explain / step by step" ask (`ThinkingPolicy.strongAnalyticMarkers`), so a word problem
//  answers fast and falls for its trap: 2026-11-19, Lil thinking always 74/78 on the routed reasoning
//  fixtures at a 39 s median, Auto 38/52 at 6.7 s, and Auto thought on none of them. This names the
//  shape cheaply and in the wave-one languages, for the `thinkingShape` A/B arms
//  (`ThinkingShapeMode`): think on it, or reason in steps without a think phase.
//
//  A puzzle is one of:
//  - two or more quantities (digits outside names, number words) AND a counting / timing ask ("how many",
//    "wie viele", "combien", "cuántos", "quantos");
//  - a day count and a "what day" ask; a clock time and an angle; "which is bigger" over two numbers; a
//    probability with a number; "the next number";
//  - a chain of two or more comparisons AND an ordering ask ("… taller than … Who is the shortest?");
//  - an explicit riddle or logic puzzle.
//  Never a paste (a code fence, or over 600 characters): a document full of figures is a reading
//  task, not a puzzle.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-20, Confidence 0.65 (lexical; tuned on the chateval
//  reasoning prompts, so its honest precision and recall are the blind set's, #713). Prior: none.
//  Review: Kev + claude-opus-5-5, 2026-11-20 — the challenger's fold (its probes are now tuning tests; the blind set
//  was scored before and after, counts only): numerals bounded out of names, a clock time counted once, weekdays and
//  cross-language homographs out of the number words, one|once|half|double worth one quantity at most, comparison
//  chains need an ordering ask, reasoning asks bounded (compartir, Steuererklärung, explicit), composed Unicode,
//  new shapes (day count, clock angle, which-is-bigger, probability, next number). Confidence 0.7.

import Foundation

public enum PuzzleShape {
    /// A turn longer than this is a paste, not a puzzle.
    static let pasteCharacters = 600

    public static func detects(_ question: String) -> Bool {
        // Composed form first: NSRegularExpression compares UTF-16, so a decomposed "cuántos" missed every
        // accented pattern (challenger, 2026-11-20).
        let text = question.precomposedStringWithCanonicalMapping.lowercased()
        guard text.count <= pasteCharacters, !text.contains("```") else { return false }
        if matches(riddle, in: text) || matches(sequenceAsk, in: text) { return true }
        let quantity = quantities(in: text)
        if matches(whichIsBigger, in: text), quantity >= 2 { return true }
        if matches(probability, in: text), quantity >= 1 { return true }
        if matches(dayCount, in: text), matches(dayAsk, in: text) { return true }
        if matches(clockAngle, in: text), matches(clockTime, in: text) { return true }
        if count(comparison, in: text) >= 2, matches(orderingAsk, in: text) { return true }
        return quantity >= 2 && matches(countingAsk, in: text)
    }

    /// An explicit ask to explain, compare or go step by step, in en, de, fr, es and pt. The English
    /// stems are `ThinkingPolicy.strongAnalyticMarkers`; the others are their wave-one twins, bounded so
    /// "compartir" (share), "Steuererklärung" and "explicit" are not asks to reason.
    public static func asksForReasoning(_ question: String) -> Bool {
        matches(reasoningAsk, in: question.precomposedStringWithCanonicalMapping.lowercased())
    }

    // MARK: - Lexicon

    private static func regex(_ pattern: String) -> NSRegularExpression {
        // The patterns are literals below; a typo is a crash in the first test that reads them.
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: pattern, options: [])
    }

    private static let reasoningAsk = regex(
        #"\bexplain|\bcompar(?!t)|\banaly|\bdebug|step by step|reason through|"#
            + #"\berklär|\bvergleich|schritt für schritt|"#
            + #"\bexpliqu|étape par étape|"#
            + #"\bexplic(?!it)|\bexplíc|paso a paso|"#
            + #"passo a passo"#
    )

    private static let riddle = regex(
        #"\b(riddle|logic puzzle|brain ?teaser|trick question|rätsel|knobelaufgabe|énigme|devinette|acertijo|adivinanza|charada)\b"#
    )

    /// "What is the next number: 2, 4, 8, 16?"
    private static let sequenceAsk = regex(
        #"\bnext number\b|\bcontinue the (sequence|pattern)\b|\bnächste zahl\b|\bprochain nombre\b|\bsiguiente n[uú]mero\b|\bpr[oó]ximo n[uú]mero\b"#
    )

    /// "Which is bigger, 9.11 or 9.9?" (with two quantities).
    private static let whichIsBigger = regex(
        #"\bwhich is (bigger|larger|greater|smaller|more)\b|\b(was|welche[rs]?) ist (größer|kleiner|mehr)\b|\b(lequel|laquelle|quel|quelle) est (le |la )?plus (grand|petit)e?\b|\bcu[aá]l es (mayor|menor|m[aá]s grande|m[aá]s peque[nñ]o)\b|\bqual é (maior|menor)\b"#
    )

    /// A probability ask with a quantity in it ("the probability of rolling a 7").
    private static let probability = regex(
        #"\bprobabilit|\bwahrscheinlichkeit\b|\bprobabilidad|\bprobabilidade\b|\bodds of\b"#
    )

    /// A count of days, and an ask for the day it lands on: "What day is it in 100 days?"
    private static let dayCount = regex(#"(?<![\p{L}\d.,])\d+ (days?|tage?n?|jours?|d[ií]as)\b"#)
    private static let dayAsk = regex(
        #"\bwhat day\b|\bwhich day\b|\bwelche[nrms]? (wochen)?tag\b|\bquel jour\b|\bqu[eé] d[ií]a\b|\bque dia\b"#
    )

    /// The clock-hands puzzle: an angle and a clock time.
    private static let clockAngle = regex(#"\b(angle|winkel|zeiger|aiguilles|agujas|ponteiros)\b"#)
    private static let clockTime = regex(#"\b\d{1,2}:\d{2}\b"#)

    /// "taller than", "größer als", "plus grand que", "más alto que", "maior que", "mayor que". Two of them
    /// read as a puzzle only beside an ordering ask: "warmer than Porto and cheaper than Madrid" is shopping,
    /// and German "Bilder als PNG" is not a comparison at all.
    private static let comparison = regex(
        #"\b(?!rather\b|other\b)\w+er than\b|\b(more|less|better|worse) (\w+ )?than\b|\b\w+er als\b|\b(mehr|weniger) als\b|"#
            + #"\b(plus|moins) \w+ (que|qu’|qu')|\b(meilleur|pire)e?s? que\b|"#
            + #"\b(m[aá]s|menos) \w+ que\b|\b(mayor|menor|mejor|peor)(es)? que\b|"#
            + #"\b(mais|menos) \w+ (do )?que\b|\b(maior|menor|melhor|pior)(es)? (do )?que\b"#
    )

    private static let orderingAsk = regex(
        #"\bwho('s| is) (the \w+est|older|younger|taller|shorter)\b|\bwer ist (am|der|die) \w+\b|\bqui est (le|la) plus\b|\bqui[eé]n es (el|la) m[aá]s\b|\bquem é (o|a) mais\b"#
    )

    private static let countingAsk = regex(
        #"\bhow (many|much|far|long|old|fast|often)\b|\bwhat (day|time|percent|angle|speed)\b|\bwhich day\b|\bon which\b|\bby what\b|\bwho is the \w+est\b|\bwhat(?: is|'s|’s) (the|your) (smaller|larger|average|total|final)\b|\baverage speed\b|"#
            + #"\bwie ?(viele?|lange|weit|alt|schnell|oft)\b|\bwelche[nrms]? (wochen)?tag\b|\bwer ist am\b|durchschnittsgeschwindigkeit|"#
            + #"\bcombien\b|\bquel(le)? (jour|heure|âge)\b|\bqui est le plus\b|vitesse moyenne|"#
            + #"\bcu[aá]nt[oa]s?\b|\bqu[eé] (d[ií]a|hora|edad)\b|\bqui[eé]n es el m[aá]s\b|velocidad (media|promedio)|"#
            + #"\bquant[oa]s?\b|\bque (dia|horas)\b|\bquem é (o|a) mais\b|velocidade média|\bqual a idade\b"#
    )

    /// A number written in digits, not inside a name ("M4", "Qwen3.5") and once per figure ("27.1.2", "3:40").
    private static let numeral = regex(#"(?<![\p{L}\d.,])\d+(?:[.,:/]\d+)*%?"#)

    /// Number words. No weekdays (opening hours are not puzzles) and no cross-language homographs: "dos"
    /// (Portuguese "of the"), "segunda" (second-hand), "sept" (September), "neuf" (new), "einmal" (filler).
    private static let numberWord = regex(
        #"\b(two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|twenty|thirty|forty|fifty|sixty|seventy|eighty|ninety|hundred|thousand|twice|triple|dozen|"#
            + #"eins|zwei|drei|vier|fünf|sechs|sieben|acht|neun|zehn|elf|zwölf|zwanzig|dreißig|vierzig|fünfzig|hundert|tausend|zweimal|doppelt|doppelte[nrs]?|hälfte|"#
            + #"deux|trois|quatre|cinq|huit|dix|onze|douze|vingt|trente|quarante|cinquante|cent|mille|moitié|"#
            + #"tres|cuatro|cinco|seis|siete|ocho|nueve|diez|doce|veinte|treinta|cuarenta|cincuenta|cien|mil|mitad|doble|triple|"#
            + #"dois|duas|três|quatro|sete|oito|nove|dez|doze|vinte|trinta|quarenta|cinquenta|cem|metade|dobro|triplo)\b"#
    )

    /// Words that are numbers only sometimes ("one night", "once I order", "half an hour", "a double room"):
    /// together they add at most one quantity.
    private static let softNumberWord = regex(#"\b(one|once|half|double)\b"#)

    private static func range(_ text: String) -> NSRange {
        NSRange(text.startIndex..., in: text)
    }

    private static func matches(_ pattern: NSRegularExpression, in text: String) -> Bool {
        pattern.firstMatch(in: text, range: range(text)) != nil
    }

    private static func count(_ pattern: NSRegularExpression, in text: String) -> Int {
        pattern.numberOfMatches(in: text, range: range(text))
    }

    static func quantities(in text: String) -> Int {
        count(numeral, in: text) + count(numberWord, in: text) + min(1, count(softNumberWord, in: text))
    }
}

/// The `thinkingShape` A/B arm (launch argument / defaults key). `off` is today's policy.
public enum ThinkingShapeMode: String, CaseIterable, Sendable {
    /// Today: a speed tier thinks only on an explicit English "explain / step by step" ask.
    case off
    /// A speed tier also thinks on a `PuzzleShape` turn, and on a wave-one "explain" ask.
    case think
    /// No think phase; a `PuzzleShape` turn carries `ThinkingPolicy.stepsClause` instead.
    case steps

    /// UserDefaults key (`M1K3 -thinkingShape think`).
    public static let defaultsKey = "thinkingShape"

    public init(argument: String?) {
        self = argument.flatMap(Self.init(rawValue:)) ?? .off
    }
}
