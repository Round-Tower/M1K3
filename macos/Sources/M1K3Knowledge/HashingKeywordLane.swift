//
//  HashingKeywordLane.swift
//  M1K3Knowledge
//
//  #670: the phone embeds with HashingEmbeddingService (no ~600 MB download on the
//  first-run path), and a bag-of-words cosine against a whole-document chunk sits far
//  under the hashing chunk floor for a keyword question: "roofline" scored 0.084
//  against notes that say "Keep the original roofline", and a question cleared 0.35
//  only on shared function words ("what did the … about the"). So the cosine lane
//  measured stopword overlap, and "ask your notes" missed on iPhone and iPad.
//
//  On the hashing arm ONLY, when the cosine lane kept no document, this lane admits
//  ONE document chunk that FTS5 matched on EVERY content word of the query (strict
//  AND, never the relaxed OR retry). Lexical is all hashing measures anyway, and BM25
//  measures it better. It never touches memories (their lane has its own floor) and a
//  real embedder never reaches it. The ⌘R weather bug (7 KB of OR-matched noise
//  drowning web_search routing) is held off by the strict AND, the stopword strip, the
//  one-chunk cap, and a live-data refusal: a question about the weather, the news or a
//  price is the web's, so the lane never answers it from a note that names the city —
//  pinned in HashingKeywordLaneTests.
//
//  "Hashing arm" is not iOS-only: the Mac's SwappableEmbeddingService forwards the
//  ACTIVE fingerprint, so while MLX warms (hashing fallback active) the lane runs there
//  too. That's wanted — the Mac's stored vectors are Gemma then, so the cosine lane is
//  meaningless and lexical grounding beats none.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-23
//  Context: the narrowed option (a) from a challenger pass on #670; options (b) stopword-stripped
//  hashing vectors (re-index, a dedupe hazard on "not") and (c) a phone embedder were set aside.
//  Confidence: 0.75 — precision pinned on the fixtures; conversational phrasings ("what did we
//  decide…") still miss by design (no stemming, no synonyms) until the phone gets a real embedder.
//  Open: an English-only stopword list — elsewhere every word is a content word, so the lane
//  only fires when the query's words all appear (precision kept, recall not gained).
//  Format: MurphySig v0.4 (https://murphysig.dev/spec). Prior: none (new file).
//

import Foundation

public enum HashingKeywordLane {
    /// One document chunk BM25 matched on every content word, or nil. Callers run it
    /// only when the cosine lane kept no document, and treat a throw (a store read
    /// error) as nil: the lane is an extra, never a reason to fail a turn.
    public static func admit(
        store: KnowledgeStore,
        query: String,
        fingerprint: String,
        excludedKinds: Set<KnowledgeKind> = []
    ) throws -> ChunkHit? {
        guard fingerprint.hasPrefix("hashing/"), !asksForLiveData(query), let terms = contentTerms(query) else {
            return nil
        }
        let kinds = KnowledgeStore.groundingDocumentKinds.subtracting(excludedKinds)
        guard !kinds.isEmpty else { return nil }
        return try store.searchFTS(
            query: terms.joined(separator: " "), limit: 1, kinds: kinds, relaxedFallback: false
        ).first
    }

    /// The query's content words: lowercased, split on anything that isn't a letter or
    /// digit, stopwords and single characters dropped. Nil when nothing is left.
    static func contentTerms(_ query: String) -> [String]? {
        let words = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 && !stopwords.contains($0) }
        var seen = Set<String>()
        let terms = words.filter { seen.insert($0).inserted }
        return terms.isEmpty ? nil : terms
    }

    /// A question the web answers (weather, news, prices, scores, "today"): never a
    /// note's to answer, whatever words they share (the ⌘R weather-bug class).
    static func asksForLiveData(_ query: String) -> Bool {
        let words = Set(query.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted))
        return !words.isDisjoint(with: liveDataWords)
    }

    static let liveDataWords: Set<String> = [
        "weather", "forecast", "rain", "temperature", "news", "headlines", "latest", "today", "tonight",
        "tomorrow", "yesterday", "price", "prices", "stock", "stocks", "score", "scores", "current", "currently",
    ]

    /// English function words plus the verbs a question wraps around its subject
    /// ("what did the notes SAY about…", "TELL me…"). Kept short on purpose: a word
    /// missing here only makes the lane stricter.
    static let stopwords: Set<String> = [
        "a", "about", "above", "after", "again", "all", "am", "an", "and", "any", "are", "as", "at",
        "be", "been", "before", "being", "below", "between", "both", "but", "by",
        "can", "could", "did", "do", "does", "doing", "down", "during", "each", "few", "for", "from",
        "further", "had", "has", "have", "having", "he", "her", "here", "hers", "him", "his", "how",
        "i", "if", "in", "into", "is", "it", "its", "just", "me", "more", "most", "my", "no", "nor",
        "not", "now", "of", "off", "on", "once", "only", "or", "other", "our", "ours", "out", "over",
        "own", "same", "she", "should", "so", "some", "such", "than", "that", "the", "their", "them",
        "then", "there", "these", "they", "this", "those", "through", "to", "too", "under", "until",
        "up", "very", "was", "we", "were", "what", "when", "where", "which", "while", "who", "whom",
        "why", "will", "with", "would", "you", "your", "yours",
        "ll", "re", "ve", "don", "doesn", "didn", "isn", "wasn", "aren", "haven",
        "please", "tell", "say", "said", "says", "show", "give", "remind", "know", "think",
        "find", "look", "get", "got", "let", "us", "anything", "something", "thing", "things",
        // Words that name the container, not the subject: "what did my notes say" has no
        // content word, so it must not match every chunk that says "notes".
        "note", "notes", "document", "documents", "doc", "docs", "file", "files", "pdf", "pdfs",
    ]
}
