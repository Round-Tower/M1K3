//
//  ReadCompressor.swift
//  M1K3Inference
//
//  The read route's second stage: a cleaned text fitted to a character budget,
//  so a long paste still reaches a 4,096-token Mini with room for the answer.
//
//  Two strategies, both kept so the eval can pair them:
//  - `head`: the start of the text, cut at a word, marked. Today's file-as-context
//    behaviour in miniature (FileTextExtractor keeps the first 50,000 characters).
//  - `extractive`: the text split into passages of up to ~600 characters, each scored
//    against the question with BM25 over crudely stemmed words; the lead passage
//    (when it is short), the best passages, then their neighbours, rendered in the
//    document's order with `[…]` where something was left out. A question that
//    shares no word with the text (a "summarise this") gets passages spread evenly
//    across it instead.
//
//  No embedder on purpose: this runs the same on the Mac, the phone's hashing store
//  and an App Clip with no index at all. Whether meaning beats words here is an eval
//  arm, not an assumption.
//
//  - `filled`: `extractive`, then the rest of the budget on passages spread evenly across the
//    text. The first smoke on Mini (4,096 window, Mac) put the trade in numbers: a full budget
//    took 8.8 s to the first word, the lean pick 0.9 s.
//
//  Review (same day, pre-push review fold): the budget check adds lengths instead of re-rendering
//  (a 400k paste with hundreds of hits re-rendered per candidate); CJK sentence marks split.
//  Open: CJK has no spaces, so BM25 reads a run as one word and such text falls to the even spread.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-14, Confidence 0.7 (the passage size, the
//  lead rule and the neighbour fill are starting points; the blind set scores them).
//  Prior: none (new file).
//

import Foundation

public enum ReadCompressor {
    public enum Strategy: String, Sendable, CaseIterable {
        case head
        case extractive
        /// `extractive`, then the rest of the budget spent on passages spread across the text:
        /// more coverage for a synthesis question, more prefill before the first word.
        case filled
    }

    public struct Fit: Sendable, Equatable {
        /// What the brain will read.
        public let text: String
        /// True when anything was left out.
        public let cut: Bool
        public let keptPassages: Int
        public let totalPassages: Int
    }

    public static let gapMarker = "[\u{2026}]"
    static let passageSeparator = "\n\n"
    /// Passages are packed up to this many characters; longer units are split.
    static let passageTarget = 600
    /// The lead passage rides along only when it costs at most this share of the budget.
    static let leadShare = 4

    public static func fit(_ text: String, question: String, budget: Int, strategy: Strategy) -> Fit {
        guard text.count > budget else {
            return Fit(text: text, cut: false, keptPassages: 1, totalPassages: 1)
        }
        guard budget > gapMarker.count + passageSeparator.count else {
            return Fit(text: "", cut: true, keptPassages: 0, totalPassages: 1)
        }
        switch strategy {
        case .head:
            return Fit(text: headCut(text, budget: budget), cut: true, keptPassages: 1, totalPassages: 1)
        case .extractive, .filled:
            return extractive(passages(of: text), question: question, budget: budget, fill: strategy == .filled)
        }
    }

    // MARK: - Head

    /// The start of `text`, cut at the last whitespace (when one is near) and marked.
    static func headCut(_ text: String, budget: Int) -> String {
        let suffix = passageSeparator + gapMarker
        let room = budget - suffix.count
        guard room > 0 else { return "" }
        var head = text.prefix(room)
        if let space = head.lastIndex(where: \.isWhitespace),
           head.distance(from: space, to: head.endIndex) < 200
        {
            head = head[..<space]
        }
        let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "" : trimmed + suffix
    }

    // MARK: - Passages

    /// Paragraphs packed into passages of up to `passageTarget` characters. A paragraph
    /// longer than that is split by lines, then sentences, then hard at the target.
    static func passages(of text: String) -> [String] {
        let paragraphs = text
            .split(separator: /\n[ \t]*\n/)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var units: [String] = []
        for paragraph in paragraphs {
            units += splitToFit(paragraph)
        }
        return pack(units, joiner: passageSeparator)
    }

    private static func splitToFit(_ paragraph: String) -> [String] {
        guard paragraph.count > passageTarget else { return [paragraph] }
        let lines = paragraph.split(separator: "\n").map(String.init)
        if lines.count > 1 {
            return pack(lines.flatMap(splitToFit), joiner: "\n")
        }
        let sentences = sentences(of: paragraph)
        if sentences.count > 1 {
            return pack(sentences.flatMap(splitToFit), joiner: " ")
        }
        // One run-on with no sentence ends: hard slices.
        var slices: [String] = []
        var rest = Substring(paragraph)
        while !rest.isEmpty {
            slices.append(String(rest.prefix(passageTarget)))
            rest = rest.dropFirst(passageTarget)
        }
        return slices
    }

    /// Greedy packing in order: units joined while the joined piece stays within the target.
    private static func pack(_ units: [String], joiner: String) -> [String] {
        var packed: [String] = []
        var current = ""
        for unit in units {
            if current.isEmpty {
                current = unit
            } else if current.count + joiner.count + unit.count <= passageTarget {
                current += joiner + unit
            } else {
                packed.append(current)
                current = unit
            }
        }
        if !current.isEmpty { packed.append(current) }
        return packed
    }

    static let sentenceEnds: Set<Character> = [".", "!", "?"]

    /// Sentences: a cut after `.`, `!` or `?` followed by whitespace, or straight after `。！？`.
    static func sentences(of text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        var previousEnds = false
        for character in text {
            if previousEnds, character.isWhitespace {
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
                previousEnds = false
                continue
            }
            current.append(character)
            previousEnds = sentenceEnds.contains(character)
            if "。！？".contains(character) {
                // CJK runs on without a space: the mark itself ends the sentence.
                let trimmed = current.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
                previousEnds = false
            }
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { sentences.append(trimmed) }
        return sentences
    }

    // MARK: - Extractive

    static func extractive(_ passages: [String], question: String, budget: Int, fill: Bool = false) -> Fit {
        let total = passages.count
        let scores = BM25.scores(query: terms(of: question), passages: passages.map(terms(of:)))
        let lengths = passages.map(\.count)
        var chosen = Set<Int>()

        /// The rendered length from the passages' lengths alone, so a huge paste with many hits
        /// costs one count per passage, not a re-render per candidate.
        func tryAdd(_ index: Int) {
            guard passages.indices.contains(index), !chosen.contains(index) else { return }
            chosen.insert(index)
            if renderedLength(lengths, chosen: chosen) > budget { chosen.remove(index) }
        }

        if let lead = passages.first, lead.count <= budget / leadShare { tryAdd(0) }

        // Best first; a tie keeps the document's order.
        let hits = scores.indices
            .filter { scores[$0] > 0 }
            .sorted { scores[$0] > scores[$1] || (scores[$0] == scores[$1] && $0 < $1) }
        if hits.isEmpty {
            // Nothing in common with the question: an even spread over the whole text.
            let average = max(1, passages.reduce(0) { $0 + $1.count } / max(1, total))
            let slots = max(1, budget / (average + passageSeparator.count + gapMarker.count))
            let picks = slots >= total ? Array(0 ..< total)
                : (0 ..< slots).map { slot in
                    slots == 1 ? 0 : Int((Double(slot) * Double(total - 1) / Double(slots - 1)).rounded())
                }
            picks.forEach(tryAdd)
        } else {
            hits.forEach(tryAdd)
            for hit in hits where chosen.contains(hit) {
                tryAdd(hit + 1)
            }
        }
        if fill { spreadOrder(count: total).forEach(tryAdd) }

        if chosen.isEmpty {
            // Even the best passage is over the budget: its start, marked.
            let best = hits.first.map { passages[$0] } ?? passages.first ?? ""
            let text = headCut(best, budget: budget - gapMarker.count - passageSeparator.count)
            let lead = hits.first == 0 ? "" : gapMarker + passageSeparator
            return Fit(
                text: text.isEmpty ? "" : lead + text, cut: true,
                keptPassages: text.isEmpty ? 0 : 1, totalPassages: total
            )
        }
        return Fit(
            text: render(passages, chosen: chosen), cut: chosen.count < total,
            keptPassages: chosen.count, totalPassages: total
        )
    }

    /// Every index of `count` once, in an order that covers the whole range evenly at any point
    /// it is stopped: 0, the middle, the quarters, the eighths… (van der Corput, base 2).
    static func spreadOrder(count: Int) -> [Int] {
        guard count > 0 else { return [] }
        var seen = Set<Int>()
        var order: [Int] = []
        var step = 0
        while order.count < count, step < count * 64 {
            var fraction = 0.0
            var denominator = 1.0
            var bits = step
            while bits > 0 {
                denominator *= 2
                fraction += Double(bits & 1) / denominator
                bits >>= 1
            }
            let index = min(count - 1, Int(fraction * Double(count)))
            if seen.insert(index).inserted { order.append(index) }
            step += 1
        }
        for index in 0 ..< count where !seen.contains(index) {
            order.append(index)
        }
        return order
    }

    /// `render(passages, chosen:).count`, from the lengths.
    static func renderedLength(_ lengths: [Int], chosen: Set<Int>) -> Int {
        let ordered = chosen.sorted()
        var parts = 0
        var characters = 0
        var previous: Int?
        for index in ordered {
            let skipped = previous.map { index > $0 + 1 } ?? (index > 0)
            if skipped {
                parts += 1
                characters += gapMarker.count
            }
            parts += 1
            characters += lengths[index]
            previous = index
        }
        if let last = ordered.last, last < lengths.count - 1 {
            parts += 1
            characters += gapMarker.count
        }
        return characters + max(0, parts - 1) * passageSeparator.count
    }

    /// The chosen passages in document order, `[…]` wherever a run of passages is left out.
    static func render(_ passages: [String], chosen: Set<Int>) -> String {
        let ordered = chosen.sorted()
        var parts: [String] = []
        var previous: Int?
        for index in ordered {
            let skipped = previous.map { index > $0 + 1 } ?? (index > 0)
            if skipped { parts.append(gapMarker) }
            parts.append(passages[index])
            previous = index
        }
        if let last = ordered.last, last < passages.count - 1 { parts.append(gapMarker) }
        return parts.joined(separator: passageSeparator)
    }

    // MARK: - Words

    static let stopwords: Set<String> = [
        "a", "an", "the", "is", "are", "was", "were", "be", "been", "to", "of", "and", "or", "in", "on", "at",
        "for", "with", "what", "which", "who", "whom", "when", "where", "why", "how", "much", "many", "does",
        "do", "did", "it", "its", "this", "that", "these", "those", "i", "you", "he", "she", "we", "they", "my",
        "your", "our", "their", "from", "by", "as", "about", "can", "could", "would", "should", "will", "me",
        "tell", "please", "there", "any", "some", "if", "than", "then", "so", "not", "no", "yes", "has", "have",
        "had", "say", "said", "text", "doc", "document", "get",
    ]

    /// Lowercased word stems of `text`, stopwords out.
    static func terms(of text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !stopwords.contains($0) }
            .map(stem)
    }

    /// Crude and identical on both sides: "parking" → "park", "costs" → "cost", "ferries" → "ferry".
    static func stem(_ word: String) -> String {
        guard word.count > 4 else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("sses") { return String(word.dropLast(2)) }
        if word.hasSuffix("ing") { return String(word.dropLast(3)) }
        if word.hasSuffix("ed") { return String(word.dropLast(2)) }
        if word.hasSuffix("s"), !word.hasSuffix("ss"), !word.hasSuffix("us"), !word.hasSuffix("is") {
            return String(word.dropLast())
        }
        return word
    }
}

/// Okapi BM25 over pre-tokenised passages (k1 1.2, b 0.75).
enum BM25 {
    static func scores(query: [String], passages: [[String]]) -> [Double] {
        let count = Double(passages.count)
        guard count > 0, !query.isEmpty else { return Array(repeating: 0, count: passages.count) }
        let lengths = passages.map { Double($0.count) }
        let average = max(1, lengths.reduce(0, +) / count)
        var frequency: [String: Double] = [:]
        for passage in passages {
            for term in Set(passage) {
                frequency[term, default: 0] += 1
            }
        }
        let unique = Set(query)
        return passages.indices.map { index in
            var counts: [String: Double] = [:]
            for term in passages[index] where unique.contains(term) {
                counts[term, default: 0] += 1
            }
            return unique.reduce(0) { score, term in
                guard let tf = counts[term], let df = frequency[term] else { return score }
                let idf = log(1 + (count - df + 0.5) / (df + 0.5))
                let norm = tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * lengths[index] / average))
                return score + idf * norm
            }
        }
    }
}
