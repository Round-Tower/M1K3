//
//  DistillationAttribution.swift
//  M1K3Chat
//
//  #284: the distiller turned things M1K3 OFFERED — "if you're feeling
//  nostalgic, the old honey story's still a hit", "if you'd rather chat
//  about AI ethics" — into "facts about the user". MemoryFactValidator
//  guards WHO the fact names (user vs assistant); FactDurabilityPolicy
//  guards WHAT KIND of sentence it is; neither ever asked WHO ASSERTED it.
//  This is that missing fence: an attribution check, not a quarantine (a
//  SelfWiringQuarantine-style span fingerprint of the source exemplars
//  catches none of the live witnesses — there is no shared long span,
//  just an unattributed paraphrase).
//
//  Two deterministic, fail-closed rules, applied in
//  MemoryDistillationCoordinator AFTER the existing validator + durability
//  filters (both of those already ran inside MemoryFactParser.parse):
//   1. `userContributionIsTrivial` — a greeting-only slice never reaches the
//      distiller at all. Cheapest possible fix for the dominant live case
//      (the "yo" witness): nothing the user said could anchor anything.
//   2. `isAnchored` — a surviving fact must share real content with
//      something the user actually said. A model's own paraphrase of its
//      own offer still won't cross this fence, because the user's turns
//      never mentioned it either.
//
//  Known, accepted false negative: a bare confirmation ("yes") to an
//  assistant's question carries no content tokens of its own, so a fact
//  built from that exchange is dropped even though the user genuinely
//  confirmed it. A fail-closed, deterministic fence costs some recall —
//  the alternative (crediting the assistant's own question) reopens the
//  door this file exists to close.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-11, Confidence 0.85 (fully pinned
//  in DistillationAttributionTests, incl. the false-negative case; the
//  coordinator-level wiring is pinned in MemoryDistillationCoordinatorTests).
//  Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-09-11 (same day, pre-merge) — the first cut's floors
//  cost real recall: a 24-character trivial floor skipped "I live in Cork" outright, and a
//  four-letter token minimum dropped "My dog is Rex" / "I'm 42" as unanchored. The character
//  floor is gone (review 1 named "I'm a teacher." too, review 2 "I'm diabetic") — a slice of
//  single-word turns is the only trivial gate; tokens count from three letters with the common
//  three-letter function words stopworded, and runs of two or more digits count.
//  Review: Kev + claude-fable-5.1, 2026-09-11 (review 6 fold) — the self-name guard reads the
//  account's names (`NSFullUserName` / `NSUserName`) instead of a hardcoded "kev" that was a no-op
//  for every other user. Review 7 fold: only the GIVEN name matches by leading fragment (Kev for
//  Kevin); surnames and the login name match exactly — "fit" for Fitzgerald is a word, not a name.
//

import Foundation

public enum DistillationAttribution {
    /// Common enough to appear in almost any sentence; sharing one of these
    /// between a fact and the user's turns proves nothing about anchoring.
    static let stopwords: Set<String> = [
        "that", "this", "with", "from", "have", "about", "would", "could",
        "user", "assistant", "conversation", "when", "what", "where", "which",
        "their", "there", "these", "those", "been", "being", "were", "will",
        "your", "just", "like", "some", "than", "them", "they", "very", "into",
        // Three-letter function words — in nearly every sentence, so proof of nothing.
        "the", "and", "for", "you", "are", "was", "but", "not", "has", "had",
        "his", "her", "its", "can", "all", "any", "one", "out", "how", "who",
        "why", "now", "get", "got", "did", "yes", "too", "our", "him", "she",
        "our", "let", "may", "own", "say", "see", "way", "yet",
    ]

    /// The user's own names as the account knows them: every letter run of
    /// three or more from `NSFullUserName()` + `NSUserName()` (matched
    /// exactly), plus the GIVEN name (the full name's first token, whatever its length), which also
    /// matches by leading fragment — "Kev" for "Kevin", "Alex" for
    /// "Alexander" — because that is how people are addressed. Surnames and
    /// the login name never match by fragment (review 7 on #288: "fit" for
    /// Fitzgerald, "gran" for Grant would have swallowed ordinary words).
    /// KNOWN, ACCEPTED COST: an ordinary word that is a fragment of the
    /// given name ("ale" for Alexandra) is treated as the name — fail-closed,
    /// like the "yes" case below; pinned in DistillationAttributionTests.
    public struct UserNames: Equatable, Sendable {
        public let exact: Set<String>
        public let given: String?

        public static let none = UserNames(exact: [], given: nil)

        public init(exact: Set<String>, given: String?) {
            self.exact = exact
            self.given = given
        }
    }

    /// Sharing ONLY a name proves nothing — the same conflation
    /// MemoryFactValidator guards against on the assistant's side ("the user
    /// is M1K3"), mirrored here so a fact can't anchor itself purely by
    /// repeating who it's supposedly about. Derived from the account, never
    /// hardcoded (review 6 on #288: the developer's first name had shipped in
    /// the fence, a no-op for every other user).
    public static let systemUserNames = userNames(fullName: NSFullUserName(), shortName: NSUserName())

    static func userNames(fullName: String, shortName: String) -> UserNames {
        let letters = { (text: String) -> [String] in
            text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        }
        let long = { (tokens: [String]) in tokens.filter { $0.count >= 3 } }
        // `given` is the RAW first token, before the length filter: for "Ed
        // Grant" it is "ed" (too short to fragment-match anything, which is
        // fine), never "grant" — a surname must not inherit the fragment
        // leniency by being the first name long enough to survive (review 8).
        let full = letters(fullName)
        return UserNames(exact: Set(long(full) + long(letters(shortName))), given: full.first)
    }

    static func isSelfName(_ token: String, names: UserNames) -> Bool {
        guard token.count >= 3 else { return false }
        if names.exact.contains(token) { return true }
        return names.given?.hasPrefix(token) ?? false
    }

    /// True when every user turn in the slice is a single word — "yo",
    /// "sure", "thanks" — so a distiller call would have nothing to anchor.
    /// That is the ONLY gate: a character floor ate "I live in Cork", a
    /// two-word rule ate "I'm diabetic", and the price of a false non-trivial
    /// is one background distiller call while a false trivial is a lost fact.
    /// The anchor fence (`isAnchored`) is what keeps offered facts out; this
    /// only saves the call. The coordinator skips distillation on `true`.
    public static func userContributionIsTrivial(turns: [ChatTurn]) -> Bool {
        let userTurns = turns.filter { $0.role == .user }
        return userTurns.allSatisfy { turn in
            turn.text.split(whereSeparator: \.isWhitespace).count <= 1
        }
    }

    /// True when `fact` shares at least one real content token with the
    /// union of `userTurns` — the deterministic backstop that a candidate
    /// fact was actually SAID (or clearly confirmed) by the user, not merely
    /// offered by the assistant and echoed back with a different subject.
    /// `selfNames`: the user's own names (`systemUserNames` in the app; tests
    /// pass their own) — they never count as evidence.
    public static func isAnchored(fact: String, userTurns: [String], selfNames: UserNames = .none) -> Bool {
        let factTokens = contentTokens(in: fact, selfNames: selfNames)
        guard !factTokens.isEmpty else { return false }
        let userTokens = Set(userTurns.flatMap { contentTokens(in: $0, selfNames: selfNames) })
        return !factTokens.isDisjoint(with: userTokens)
    }

    /// Lowercased alphanumeric runs of three letters or more, plus any run
    /// of two or more digits ("42" is content, "step 1" is not), minus
    /// stopwords and the user's own name — function words and the subject's
    /// own name are too common to count as evidence of anchoring. Three, not
    /// four: "dog", "Rex", "car", "son" are most of what a short fact is made of.
    private static func contentTokens(in text: String, selfNames: UserNames) -> Set<String> {
        Set(
            text.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 3 || ($0.count >= 2 && $0.allSatisfy(\.isNumber)) }
                .filter { !stopwords.contains($0) }
                .filter { !isSelfName($0, names: selfNames) }
        )
    }
}
