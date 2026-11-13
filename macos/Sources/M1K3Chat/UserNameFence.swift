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
//  someone. So a fact that names the user is refused in three cases only:
//
//   1. the "name" is a word for no name at all ("not", "unknown");
//   2. it is the assistant's own name;
//   3. every time the user said it, they were addressing someone with it
//      ("Hey Mike", "Mike, set a timer", "lift the freeze pal").
//
//  and each of those is overridden by the account's own name or by the user
//  introducing themselves with it ("my name is…", "I'm…", "call me…", "it's…").
//  Everything else passes: the fence fails OPEN. Its first cut failed closed
//  (a name needed an introduction from a hand-listed set) and a blind set
//  dropped 11 of 20 real names with it, a correction among them ("no, it's
//  Kevin not Kev").
//
//  Signed: Kev + claude-fable-5.2, 2026-11-13, Confidence 0.75 (pinned in
//  UserNameFenceTests on the three live rows, their near-misses and the
//  challenger's blind set; the address shapes and introductions are English
//  and hand-listed). Prior: none (new file).
//  Open: the five name facts already stored are untouched — nothing here sweeps the
//  store, and contradicting name facts still do not supersede one another.
//  Known, accepted costs: a name the user only ever gave as a sign-off after a comma ("I'm Kevin's
//  wife, Aoife") reads as an address and is dropped; a pasted introduction ("Hi, I'm Jordan from
//  Acme") supports "Jordan"; "The user is named after his grandfather" passes as a claim to the
//  name "after", which nothing refuses.
//

import Foundation

public enum UserNameFence {
    /// The phrases that make a fact a claim about what the USER is called, each
    /// ending where the name starts. "is" alone is not here ("the user is
    /// Irish"), nor "identifies as" ("…as a researcher"), nor a bare "goes by"
    /// ("…goes by train").
    private static let naming = #"\buser(?:(?:'s)? (?:(?:first|full|given|preferred|real|actual) )?(?:nick)?name is"#
        + #"| is called| is named| is known as| goes by the name"#
        + #"| (?:prefers|likes|wants|would like|asked) to be called) "#

    /// Words in front of a name that are not it.
    private static let titles: Set<String> = ["dr", "mr", "mrs", "ms", "miss", "prof", "professor", "sir"]

    /// What a distiller writes where a name would go when there is none.
    private static let nonNames: Set<String> = [
        "not", "unknown", "unspecified", "none", "unclear", "undisclosed", "withheld", "anonymous", "n/a",
    ]

    /// The assistant's names, written and spoken (M1K3Voice's SpokenName says "Mike").
    private static let assistantNames: Set<String> = ["m1k3", "mike", "mikey"]

    /// How people introduce themselves, each followed by the name.
    private static let introductions = [
        "my name is", "my name's", "the name is", "the name's", "name's",
        "i am", "i'm", "im", "call me", "they call me", "everyone calls me", "people call me",
        "i go by", "i'm called", "i am called", "this is", "it's", "it is", "its",
    ]

    /// Words that, right before a name, make it an address.
    private static let greetings: Set<String> = [
        "hey", "hi", "hello", "yo", "thanks", "thank", "you", "cheers", "ok", "okay", "right", "so", "please",
        "sorry", "morning", "night", "goodnight", "evening", "bye", "goodbye", "well", "now", "listen", "look",
    ]

    /// The first word of the name a fact gives the user: lowercased, without
    /// diacritics (the distiller writes "Sean" for a spoken "Seán"), past any
    /// title, keeping the marks inside a name (O'Brien, Anne-Marie). Nil when
    /// the fact is not a naming fact.
    static func claimedName(in fact: String) -> String? {
        let norm = folded(MemoryFactNormalizer.normalize(fact))
        guard let lead = norm.range(of: naming, options: .regularExpression) else { return nil }
        let words = norm[lead.upperBound...].split(whereSeparator: \.isWhitespace)
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
            .filter { !$0.isEmpty }
        return words.first { !titles.contains($0) } ?? words.first
    }

    /// True unless `fact` names the user with something that is not their name
    /// (the header's three cases). A fact that names nobody always passes.
    public static func isSupported(
        fact: String,
        userTurns: [String],
        selfNames: DistillationAttribution.UserNames = .none
    ) -> Bool {
        guard let name = claimedName(in: fact) else { return true }
        if selfNames.exact.contains(name) { return true }
        if let given = selfNames.given, name.count >= 2, folded(given).hasPrefix(name) { return true }
        if userTurns.contains(where: { introduces(name, in: $0) }) { return true }
        if nonNames.contains(name) || assistantNames.contains(name) { return false }
        return !isOnlyAnAddress(name, in: userTurns)
    }

    /// Whether `turn` holds a self-introduction by exactly `name`: "I'm Mike",
    /// "I'm, uh, Niamh", "it's Dr. Chen" — never "I'm Mike's brother" and never
    /// "I'm not Mike".
    static func introduces(_ name: String, in turn: String) -> Bool {
        let lead = introductions.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
        let filler = #"(?:[,.…]?\s+(?:just|uh|um|er|erm|like))*"#
        let title = #"(?:[,.]?\s+(?:"# + titles.joined(separator: "|") + #")\.?)?"#
        let pattern = "(?<![a-z'])(?:\(lead))\(filler)\(title)[,.…]?\\s+"
            + "\(NSRegularExpression.escapedPattern(for: name))(?![a-z0-9'])"
        return folded(turn).range(of: pattern, options: .regularExpression) != nil
    }

    /// True when the user said `name` and EVERY time they did they were
    /// addressing someone with it. Never said at all is false: the anchor fence
    /// (`DistillationAttribution`) already ruled on that.
    static func isOnlyAnAddress(_ name: String, in userTurns: [String]) -> Bool {
        var said = false
        for turn in userTurns {
            for sentence in turn.components(separatedBy: CharacterSet(charactersIn: ".!?\n")) {
                let raw = sentence.split(whereSeparator: \.isWhitespace).map(String.init)
                let words = raw.map { folded($0).trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
                for index in words.indices where words[index] == name {
                    said = true
                    let first = index == 0
                    let last = index == words.count - 1
                    let commaAfter = raw[index].hasSuffix(",")
                    let commaBefore = index > 0 && raw[index - 1].hasSuffix(",")
                    let greeted = index > 0 && greetings.contains(words[index - 1])
                    // "pal" typed in lower case at the end of a sentence is an address; a
                    // capitalised last word ("…know me as Léa") is more likely the name itself.
                    let lowercased = raw[index].first?.isLowercase ?? false
                    let address = greeted || (first && (commaAfter || last))
                        || (last && (commaBefore || lowercased))
                    if !address { return false }
                }
            }
        }
        return said
    }

    /// Lowercased, apostrophes straightened, diacritics removed.
    private static func folded(_ text: String) -> String {
        MemoryFactValidator.straightenedApostrophes(text.lowercased())
            .folding(options: .diacriticInsensitive, locale: nil)
    }
}
