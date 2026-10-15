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
    /// The bar for a single word of fewer than five sounds.
    static let shortWord = 0.8

    private let names: [Known]
    private let known: Set<String>
    private let written: Set<String>
    private let threshold: Double
    private let margin: Double

    private struct Known {
        let name: String
        let key: String
        let words: Int
    }

    public init(names: [String], threshold: Double = defaultThreshold, margin: Double = defaultMargin) {
        // One entry per name however often it's listed: a duplicate would tie itself and fail the margin.
        var seen: Set<String> = []
        self.names = names.compactMap { name in
            let key = Self.soundKey(name)
            guard !key.isEmpty, seen.insert(Self.plain(name)).inserted else { return nil }
            return Known(name: name, key: key, words: name.split(whereSeparator: \.isWhitespace).count)
        }
        known = seen
        written = Set(self.names.map(\.name))
        self.threshold = threshold
        self.margin = margin
    }

    public func repair(_ text: String) -> (text: String, repairs: [Repair]) {
        guard !names.isEmpty else { return (text, []) }
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let parts = words.map(Self.parts)
        let swaps = choose(candidates(words: words, parts: parts)).filter { $0.name != nil }
        // Nothing to repair: the text comes back exactly as it was, spacing and all.
        guard !swaps.isEmpty else { return (text, []) }
        var repairs: [Repair] = []
        for swap in swaps.sorted(by: { $0.start > $1.start }) {
            guard let name = swap.name else { continue }
            let range = swap.start ..< swap.start + swap.count
            let first = parts[swap.start], last = parts[range.upperBound - 1]
            // The 's stays a possessive unless it was matched as part of the name ("Alohi's", Allihies).
            let possessive = swap.ownsPossessive ? "" : last.possessive
            let heard = parts[range].map(\.bare).joined(separator: " ") + (swap.ownsPossessive ? last.possessive : "")
            repairs.append(Repair(heard: heard, name: name, score: swap.score))
            words.replaceSubrange(range, with: [first.lead + name + possessive + last.tail])
        }
        return (words.joined(separator: " "), repairs.reversed())
    }

    /// A word split into what wraps it and what is matched: `("(", "Bunion", "'s", "),")`.
    private struct WordParts {
        let lead: String
        let bare: String
        let possessive: String
        let tail: String
    }

    private static func parts(_ word: String) -> WordParts {
        let wrap = CharacterSet.punctuationCharacters.union(.symbols)
        let lead = String(word.prefix { $0.unicodeScalars.allSatisfy(wrap.contains) })
        let rest = word.dropFirst(lead.count)
        let tail = String(rest.reversed().prefix { $0.unicodeScalars.allSatisfy(wrap.contains) }.reversed())
        var bare = String(rest.dropLast(tail.count))
        var possessive = ""
        for suffix in ["'s", "’s"] where bare.count > suffix.count + 1 && bare.hasSuffix(suffix) {
            possessive = suffix
            bare = String(bare.dropLast(suffix.count))
        }
        return WordParts(lead: lead, bare: bare, possessive: possessive, tail: tail)
    }

    // MARK: - Choosing spans

    private struct Candidate {
        let score: Double
        let start: Int
        let count: Int
        /// nil: a span that claims its words untouched (ambiguous, or already the name).
        let name: String?
        /// The last word's 's was matched as sound, not kept as a possessive.
        var ownsPossessive = false
    }

    private func candidates(words: [String], parts: [WordParts]) -> [Candidate] {
        let bare = parts.map(\.bare)
        // A capital that only opens a sentence says nothing about a name.
        var starts: Set = [0]
        for (index, word) in words.enumerated() {
            let end = word.reversed().drop { "\"'’”)]".contains($0) }.first
            if let end, ".?!…".contains(end) { starts.insert(index + 1) }
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
                if written.contains(span.joined(separator: " ")) {
                    // Already the name as written ("Liquid Glass"): claim it so nothing inside is touched.
                    found.append(Candidate(score: 1, start: start, count: count, name: nil))
                } else if let candidate = bestOfPossessive(
                    span: span, possessive: parts[start + count - 1].possessive,
                    start: start, count: count, capped: capped
                ) {
                    found.append(candidate)
                }
            }
        }
        return found
    }

    /// A trailing 's is a possessive or part of the sound ("Alohi's"): both readings, the better kept.
    private func bestOfPossessive(
        span: [String], possessive: String, start: Int, count: Int, capped: Bool
    ) -> Candidate? {
        let spoken = span.joined(separator: " ")
        let plainRead = best(key: Self.soundKey(spoken), start: start, count: count, capped: capped)
        guard !possessive.isEmpty else { return plainRead }
        let sounded = (span.dropLast() + [span[count - 1] + possessive]).joined(separator: " ")
        guard var whole = best(key: Self.soundKey(sounded), start: start, count: count, capped: capped),
              whole.score > (plainRead?.score ?? 0)
        else { return plainRead }
        whole.ownsPossessive = true
        return whole
    }

    /// The best and runner-up names for a span. A name whose length alone keeps it below
    /// `threshold - margin` can be neither a winner nor a close runner-up, so it is skipped.
    private func best(key: String, start: Int, count: Int, capped: Bool) -> Candidate? {
        guard key.count >= 4 else { return nil } // three sounds match too much
        let bar = capped ? threshold : max(threshold, Self.nearExact)
        let floor = threshold - margin
        let keyLength = Double(key.count)
        var top: (score: Double, name: String)?
        var second = 0.0
        for known in names where abs(count - known.words) <= (count == 3 ? 2 : 1) {
            let length = Double(known.key.count)
            guard 1 - abs(keyLength - length) / max(keyLength, length) >= floor else { continue }
            let score = Self.similarity(key, known.key)
            if score > (top?.score ?? -1) {
                second = top?.score ?? second
                top = (score, known.name)
            } else if score > second {
                second = score
            }
        }
        // A short single word needs more than one swapped sound: at four sounds a substitution
        // scores 0.75 ("Cole" would be Colm), while a dropped one scores 0.8 ("Gron", Gráinne).
        let short = count == 1 && key.count < 5
        guard let top, top.score >= (short ? max(bar, Self.shortWord) : bar) else { return nil }
        let name = top.score - second < margin ? nil : top.name
        return Candidate(score: top.score, start: start, count: count, name: name)
    }

    /// Best first (longer spans, then earlier, win ties); a span overlapping a taken one is dropped.
    private func choose(_ candidates: [Candidate]) -> [Candidate] {
        var taken = IndexSet()
        var chosen: [Candidate] = []
        let ordered = candidates.sorted {
            ($0.score, $0.count, -$0.start) > ($1.score, $1.count, -$1.start)
        }
        for candidate in ordered {
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
        let x = Array(a.utf8), y = Array(b.utf8) // keys are ASCII
        var previous = Array(0 ... y.count)
        var row = previous
        for i in 1 ... x.count {
            row[0] = i
            for j in 1 ... y.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&previous, &row)
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
