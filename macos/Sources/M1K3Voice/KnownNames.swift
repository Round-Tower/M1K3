//
//  KnownNames.swift
//  M1K3Voice
//
//  The names NameRepair repairs toward: the user's own name plus every
//  capitalised run in what M1K3 remembers ("Their sister Aoife lives in Dún
//  Laoghaire" gives Aoife and Dún Laoghaire). There is no entity table, so the
//  facts are read as text. A lone capital opening a sentence is skipped ("Prefers
//  short answers"); a run of two or more there counts ("Lough Hyne is near…"),
//  less an opener word or verb that leads it ("Prefers Python" gives Python).
//  Words under three letters or with a digit (AI, M1K3) are never names. Facts
//  arrive newest first (MemoryStore.allMemories), so past `limit` the newest win.
//
//  NameRepair only ever repairs TOWARD a name in this list and never touches a
//  name already heard right, so a repaired turn can't put a new name into memory.
//  A garbled name already in memory (voice-garbled-memory-entities) is repaired
//  toward as faithfully as a right one: garbage in, garbage out.
//
//  Signed: Kev + claude-opus-5-5, 2026-10-16, Confidence 0.75. Prior: Unknown.
//  Review: Kev + claude-opus-5-5, 2026-10-16 (follow-up) — openers are a word list (the "-s" rule ate
//  Charles); the cap keeps the newest facts' names, pinned by a test.

import Foundation

public enum KnownNames {
    /// Enough for a long memory; NameRepair scores every span against every name.
    public static let limit = 300

    public static func from(facts: [String], userName: String?) -> [String] {
        var names: [String] = []
        var seen: Set<String> = []
        func add(_ name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, names.count < limit, seen.insert(trimmed.lowercased()).inserted else { return }
            names.append(trimmed)
        }
        if let userName { add(userName) }
        for fact in facts {
            for sentence in fact.split(whereSeparator: { ".!?\n".contains($0) }) {
                for name in runs(in: String(sentence)) {
                    add(name)
                }
            }
        }
        return names
    }

    /// Words that open a fact without being part of a name. A list, not a rule: "anything ending
    /// in s" also ate Charles and Thomas (#618 review).
    private static let openers: Set<String> = [
        "the", "a", "an", "their", "his", "her", "our", "my", "your", "they", "she", "he", "it", "this",
        "that", "user", "has", "had", "is", "was", "wants", "needs", "prefers", "likes", "loves", "uses",
        "enjoys", "lives", "works", "plays", "owns", "speaks", "studies", "visits", "hates", "runs",
        "drives", "reads", "writes", "builds", "codes", "listens", "watches", "follows", "supports",
    ]

    /// Capitalised runs in one sentence. Punctuation after a word ends its run.
    private static func runs(in sentence: String) -> [String] {
        var found: [String] = []
        var run: [String] = []
        var runStart = 0
        func close() {
            // A run opening the sentence sheds a leading opener or verb ("Prefers Python", "The Burren").
            if runStart == 0, run.count >= 2, let first = run.first,
               openers.contains(first.lowercased())
            {
                run.removeFirst()
                runStart = 1
            }
            if run.count >= 2 || (run.count == 1 && runStart > 0) { found.append(run.joined(separator: " ")) }
            run = []
        }
        let words = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
        let wrap = CharacterSet.punctuationCharacters.union(.symbols)
        for (index, raw) in words.enumerated() {
            var word = raw.trimmingCharacters(in: wrap)
            var possessive = false
            for suffix in ["'s", "’s"] where word.hasSuffix(suffix) {
                word = String(word.dropLast(suffix.count))
                possessive = true
            }
            let isName = word.count >= 3 && word.first?.isUppercase == true
                && !word.contains(where: \.isNumber) && word != word.uppercased()
            if isName {
                if run.isEmpty { runStart = index }
                run.append(word)
            } else {
                close()
            }
            // "Aoife's car", "Cork, then…": the run ends at the word.
            if isName, possessive || raw.last.map({ !$0.isLetter }) == true { close() }
        }
        close()
        return found
    }
}
