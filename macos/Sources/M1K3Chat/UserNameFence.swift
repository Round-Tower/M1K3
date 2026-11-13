//
//  UserNameFence.swift
//  M1K3Chat
//
//  Who says the user is called that? On 2026-11-13 recall_memory "the user's
//  name" returned five live profile facts: Kev, Kevin Murphy, Mike, paL, and
//  "not provided". Three are wrong, and each walked through every fence:
//
//   - "The user is named Mike." M1K3's spoken name is Mike. "Hey Mike, what's
//     the weather" put the token in the user's turn, so the fact anchored.
//   - "The user's name is paL." Kev calls M1K3 "pal". Same door.
//   - "The user's name is not provided." Anchored on the word "name".
//
//  DistillationAttribution asks whether the user SAID the fact's words. For a
//  name that is the wrong question: a name is said most often to ADDRESS
//  someone. So a fact that names the user needs one of two things the
//  assistant's name can never have: it is the account's own name, or the user
//  introduced themselves by it ("my name is…", "I'm…", "call me…").
//
//  No word lists: a real Mike, Buddy or Chief says "call me Mike" once and the
//  fact stands. What is lost is a name the distiller inferred with no
//  introduction in the slice — fail-closed, like every fence beside this one.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.8 (pinned in
//  UserNameFenceTests on the three live rows and their near-misses; the
//  introduction phrasings are English and hand-listed, so a real introduction
//  worded another way is dropped until a fixture adds it). Prior: none (new file).
//  Open: the five name facts already stored are untouched — nothing here sweeps the
//  store, and contradicting name facts still do not supersede one another.
//  Known, accepted cost: "The user is named after his grandfather" reads as the name "after" and is
//  dropped (so does "is called out by…"). Casing cannot tell them apart: "paL" has to be caught.
//

import Foundation

public enum UserNameFence {
    /// The phrases that make a fact a claim about what the USER is called, each
    /// ending where the name starts. "is" alone is not here ("the user is
    /// Irish"), nor "identifies as" ("…as a researcher"), nor a bare "goes by"
    /// ("…goes by train").
    private static let naming = #"\buser(?:'s name is| name is| is called| is named| goes by the name) "#

    /// How people introduce themselves, each followed by the name.
    private static let introductions = [
        "my name is", "my name's", "the name is", "the name's", "name's",
        "i am", "i'm", "im", "call me", "they call me", "everyone calls me", "people call me",
        "i go by", "i'm called", "i am called", "this is",
    ]

    /// The first word of the name a fact gives the user, lowercased, keeping
    /// the marks inside a name (O'Brien, Anne-Marie); nil when the fact is not a
    /// naming fact.
    static func claimedName(in fact: String) -> String? {
        let norm = MemoryFactValidator.straightenedApostrophes(MemoryFactNormalizer.normalize(fact))
        guard let lead = norm.range(of: naming, options: .regularExpression) else { return nil }
        let first = norm[lead.upperBound...].split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let name = first.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return name.isEmpty ? nil : name
    }

    /// True unless `fact` names the user with a name nothing supports. A fact
    /// that names nobody always passes: this fence has no opinion on it.
    public static func isSupported(
        fact: String,
        userTurns: [String],
        selfNames: DistillationAttribution.UserNames = .none
    ) -> Bool {
        guard let name = claimedName(in: fact) else { return true }
        if selfNames.exact.contains(name) { return true }
        if let given = selfNames.given, name.count >= 2, given.hasPrefix(name) { return true }
        return userTurns.contains { introduces(name, in: $0) }
    }

    /// Whether `turn` holds a self-introduction by exactly `name`: "I'm Mike",
    /// never "I'm Mike's brother" and never "I'm not Mike".
    static func introduces(_ name: String, in turn: String) -> Bool {
        let text = MemoryFactValidator.straightenedApostrophes(turn.lowercased())
        let lead = introductions.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let pattern = "(?<![a-z'])(?:\(lead))\\s+(?:just\\s+)?\(NSRegularExpression.escapedPattern(for: name))(?![a-z0-9'])"
        return text.range(of: pattern, options: .regularExpression) != nil
    }
}
