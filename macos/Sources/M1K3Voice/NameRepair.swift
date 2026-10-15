//
//  NameRepair.swift
//  M1K3Voice
//
//  Swaps a misheard span of a transcript for a name M1K3 already knows when the
//  two sound alike: "Karen 2 Hill" is Carrauntoohil, "Don Leary" is Dún Laoghaire.
//  Every recogniser misses Irish names (17–21% WER on Kev's corpus) and none takes
//  a vocabulary that helps (SpeechTranscriber ignores contextual strings), so the
//  repair runs on the text instead: a sound key per span (Irish digraphs folded,
//  vowel clusters and doubled letters collapsed), Levenshtein similarity against
//  each known name.
//
//  A wrong name is worse than a garbled one (it reads as right, and the distiller
//  would keep it), so the guards lean to leaving text alone: a span needs a
//  capital that doesn't just open a sentence (or two or more words that sound
//  near-exactly like the name), may not start or end on a function word, never
//  touches a known name, a weekday or a month, and is refused when a second name
//  sounds nearly as close. Measured in docs/evals/2026-10-15-stt.md: at these
//  defaults, 92 right swaps to 3 wrong over both sets, no trap word touched.
//
//  Pure and not wired: where the names come from, keeping repaired names out of
//  memory distillation, and whether it runs at all are open (Kev).
//
//  Signed: Kev + claude-opus-5-5, 2026-10-15, Confidence 0.7 (tuned on one speaker
//  and a synthetic held-out voice; challenger reviewed). Prior: Unknown.
//  Open: a held-out set read by a real second speaker before the thresholds are trusted.

import Foundation

public struct NameRepair: Sendable {
    public struct Repair: Sendable, Equatable {
        /// The words as heard, without surrounding punctuation.
        public let heard: String
        public let name: String
        public let score: Double
    }

    public static let defaultThreshold = 0.75
    /// The bar for a span with no name-like capital (and two or more words).
    public static let nearExact = 0.92
    /// How far the best name must sound ahead of the next: below it, the span is ambiguous.
    public static let defaultMargin = 0.10

    private let names: [(name: String, key: String)]
    private let known: Set<String>
    private let threshold: Double
    private let margin: Double

    public init(names: [String], threshold: Double = defaultThreshold, margin: Double = defaultMargin) {
        self.names = names.map { ($0, Self.soundKey($0)) }.filter { !$0.key.isEmpty }
        known = Set(names.map(Self.plain))
        self.threshold = threshold
        self.margin = margin
    }

    public func repair(_ text: String) -> (text: String, repairs: [Repair]) {
        guard !names.isEmpty else { return (text, []) }
        var words = text.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        let bare = words.map { $0.trimmingCharacters(in: .punctuationCharacters.union(.symbols)) }
        let swaps = choose(candidates(words: words, bare: bare))
        var repairs: [Repair] = []
        for swap in swaps.sorted(by: { $0.start > $1.start }) {
            guard let name = swap.name else { continue }
            let last = words[swap.start + swap.count - 1]
            let tail = String(last.reversed().prefix { $0.isPunctuation }.reversed())
            let heard = bare[swap.start ..< swap.start + swap.count].joined(separator: " ")
            repairs.append(Repair(heard: heard, name: name, score: swap.score))
            words.replaceSubrange(swap.start ..< swap.start + swap.count, with: [name + tail])
        }
        return (words.joined(separator: " "), repairs.reversed())
    }

    // MARK: - Choosing spans

    private struct Candidate {
        let score: Double
        let start: Int
        let count: Int
        /// nil: an ambiguous span that claims its words untouched.
        let name: String?
    }

    private func candidates(words: [String], bare: [String]) -> [Candidate] {
        // A capital that only opens a sentence says nothing about a name.
        var starts: Set = [0]
        for (index, word) in words.enumerated() where word.last.map({ ".?!".contains($0) }) == true {
            starts.insert(index + 1)
        }
        let locked = Set(bare.indices.filter {
            known.contains(Self.plain(bare[$0])) || Self.lockedWords.contains(bare[$0].lowercased())
        })
        var found: [Candidate] = []
        for count in [3, 2, 1] where count <= words.count {
            for start in 0 ... words.count - count {
                let span = Array(bare[start ..< start + count])
                guard span.allSatisfy({ !$0.isEmpty }),
                      !Self.functionWords.contains(span[0].lowercased()),
                      !Self.functionWords.contains(span[count - 1].lowercased()),
                      locked.isDisjoint(with: start ..< start + count)
                else { continue }
                let capped = span.indices.contains {
                    span[$0].first?.isUppercase == true && !starts.contains(start + $0)
                }
                if !capped, count == 1 { continue } // a lone lowercase word is an ordinary word
                let key = Self.soundKey(span.joined(separator: " "))
                guard key.count >= 4 else { continue }
                if let candidate = best(key: key, start: start, count: count, capped: capped) {
                    found.append(candidate)
                }
            }
        }
        return found
    }

    private func best(key: String, start: Int, count: Int, capped: Bool) -> Candidate? {
        let scored = names
            .filter { abs(count - $0.name.split(separator: " ").count) <= (count == 3 ? 2 : 1) }
            .map { (score: Self.similarity(key, $0.key), name: $0.name) }
            .sorted { $0.score > $1.score }
        guard let top = scored.first, top.score >= (capped ? threshold : max(threshold, Self.nearExact)) else {
            return nil
        }
        if scored.count > 1, top.score - scored[1].score < margin {
            return Candidate(score: top.score, start: start, count: count, name: nil)
        }
        return Candidate(score: top.score, start: start, count: count, name: top.name)
    }

    /// Best first (longer spans win ties); a span overlapping a taken one is dropped.
    private func choose(_ candidates: [Candidate]) -> [Candidate] {
        var taken = IndexSet()
        var chosen: [Candidate] = []
        for candidate in candidates.sorted(by: { ($0.score, $0.count) > ($1.score, $1.count) }) {
            let range = candidate.start ..< candidate.start + candidate.count
            guard !taken.intersects(integersIn: range) else { continue }
            taken.insert(integersIn: range)
            chosen.append(candidate)
        }
        return chosen
    }

    // MARK: - Sound

    /// Spelling folded toward sound: letters only, digits spoken ("2" is "to"),
    /// Irish and English digraphs folded, a vowel cluster one slot, doubles single.
    static func soundKey(_ text: String) -> String {
        var key = plain(text)
        for (spelling, sound) in rules {
            key = key.replacingOccurrences(of: spelling, with: sound)
        }
        var out = ""
        for character in key {
            let folded: Character = "aeiou".contains(character) ? "a" : character
            if out.last != folded { out.append(folded) }
        }
        return out
    }

    static func plain(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en"))
        var out = ""
        for character in folded {
            if let digit = character.wholeNumberValue, character.isASCII {
                out += digitSounds[digit]
            } else if character.isASCII, character.isLetter {
                out.append(contentsOf: character.lowercased())
            }
        }
        return out
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let x = Array(a), y = Array(b)
        var previous = Array(0 ... y.count)
        for i in 1 ... x.count {
            var row = [i] + Array(repeating: 0, count: y.count)
            for j in 1 ... y.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return 1 - Double(previous[y.count]) / Double(max(x.count, y.count))
    }

    private static let digitSounds = ["oh", "one", "to", "three", "for", "five", "six", "seven", "ate", "nine"]
    private static let rules = [
        ("ph", "f"), ("bh", "v"), ("mh", "v"), ("dh", ""), ("gh", ""), ("th", "t"), ("sh", "s"), ("ch", "k"),
        ("ck", "k"), ("c", "k"), ("q", "k"), ("x", "ks"), ("z", "s"), ("y", "i"), ("w", "u"), ("h", ""),
    ]
    private static let functionWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "so", "of", "to", "in", "on", "at", "by", "for", "from",
        "with", "about", "as", "into", "than", "then", "i", "me", "my", "you", "your", "he", "she", "it", "we",
        "they", "them", "us", "our", "his", "her", "its", "this", "that", "these", "those", "there", "here",
        "is", "am", "are", "was", "were", "be", "been", "being", "do", "does", "did", "have", "has", "had",
        "will", "would", "can", "could", "should", "may", "might", "must", "shall", "not", "no", "yes", "what",
        "when", "where", "who", "why", "how", "which", "while", "just", "also", "very", "too", "only", "sorry",
        "please", "okay", "ok", "oh", "well", "like", "up", "down", "out", "off", "over", "under", "again",
    ]
    private static let lockedWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february",
        "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
    ]
}
