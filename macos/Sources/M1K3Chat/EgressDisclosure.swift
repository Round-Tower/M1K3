//
//  EgressDisclosure.swift
//  M1K3Chat
//
//  The per-turn "what can leave this device" facts, built from live settings.
//
//  Why (#482): asked over MCP "does anything I type ever leave this Mac?", Big
//  answered "everything stays on this machine unless you explicitly ask me" and
//  left out Private Cloud Compute — the persona's own "nothing about the user
//  leaves unless they ask" read back, with web search on by default (M1K3 picks
//  when to search) and PCC a brain the user can pick. What leaves depends on
//  settings the persona prefix can't know without busting its KV cache, so the
//  facts ride the per-turn grounding beside the age clause, nearer the question
//  than the persona (the PromptContext lesson: the nearer line wins).
//
//  Phrased "if asked" so it answers the question without becoming small talk
//  (#428: a concrete per-turn line becomes what Mini opens on).
//
//  Signed: Kev + claude-opus-5-5, 2026-10-04, Confidence 0.8 (pure and pinned;
//  whether each brain repeats it faithfully is the open-chat eval's call).
//  Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-10-09 (#486) — `EgressFacts.searchProvider` is the one
//  name for the web search backend; the clause reads it, and EgressDisclosureTests pins it equal
//  to `WebSearchTool.providerName` (this module cannot link the tools). Confidence 0.85.
//  Review: Kev + claude-opus-5-5, 2026-10-19 — the local answer says where memories and documents are stored
//  ("stored on \(device)", "this machine" on the Mac), not that they "never leave on their own": Lil finished that
//  line "…unless you explicitly ask", which is false (M1K3 decides when to search). Same fix as the persona's opening.
//  Review: same day — the answer leads with its verdict ("Yes, some of it can.") whenever an exit exists, and says
//  "I decide when to search". With the clause beside the question Lil still opened "No… unless you explicitly ask":
//  what-leaves 0/3 on master and on the opening-only arm, 2/3 in the screen arm; capabilities 3/3. Confidence 0.7
//  until the full gate (security x3, Big, pocket, Mini).
//  Review: same day (pre-push review fold) — Home leads with a plain "Yes." (every message goes to the Mac);
//  the doc names the real device nouns. The Mac's strings, which the gate measures, are unchanged.
//  Review: same day (gate fold) — `adapted(_:for:)`: pocket's clause drops the verdict lead, which the 1.2B copied
//  into unrelated answers (3 of 3 couplets opened "Yes, some of it can—"). Every other variant keeps it.
//  Review: Kev + claude-opus-5.5, 2026-11-04 — #775: the instruction is a constant (`instruction`), so the leak guard
//  fingerprints the framing and never the answer. The render is byte-identical (EgressDisclosureTests pins it).
//  Confidence 0.9.
//  Review: Kev + claude-fable-5.1, 2026-11-05 — `applies(to:)`: the clause rides only a turn whose question
//  carries a privacy cue. Kev's iPhone (1.3.0 in review) opened a recipe ask with the clause's quoted answer word
//  for word, then the recipe: read off the phone's chat store, on the dispatch route (web_search), as were all 8
//  tagged Mini first replies there. NOT reproduced on the Mac (0/24 ordinary turns, MiniEgressPreambleEvalTests).
//  The cue list was scored on the chateval fixtures and trimmed after that first run (record, sell, the bare
//  leak), so the pinned hit set is a regression snapshot, not a blind score: 8 hits, 2 of them real privacy asks.
//  Confidence 0.75: a heuristic, unmeasured on the phone; a miss costs one turn its verdict-first answer.
//  Review: same day (pre-push security pass) — `ridesEveryTurn`: a Home clause rides every turn, cue or not, because
//  on Home the default answer is wrong on every turn. Pinned in EgressDisclosureTests and PlainTurnRouteTests.
//

import Foundation
import M1K3Inference

/// The settings that decide what can leave the device on a turn.
public struct EgressFacts: Sendable, Equatable {
    /// Where a web search query goes. The tool (`WebSearchTool.providerName`) is the other
    /// reader; the test pins the two equal so a backend swap cannot leave this stale (#486).
    public static let searchProvider = "DuckDuckGo"

    /// The web tools are in the palette: the Settings switch AND the age band
    /// (`webToolsAllowed`) — a child's session withholds them whatever the switch says.
    public var webSearch: Bool
    /// Private Cloud Compute is a brain the user can pick (Mac only). Deliberately not
    /// "picked": a PCC turn never reaches this responder (`PrivateCloudTurn`), so the
    /// clause is only ever read on a turn that stayed local — review fold, #482.
    public var privateCloudOffered: Bool
    /// The phone's Home brain: the user's own Mac answers, over their Wi‑Fi, and the
    /// phone's prompt — its retrieved memories and documents too — goes there.
    public var brainIsHome: Bool

    public init(webSearch: Bool, privateCloudOffered: Bool = false, brainIsHome: Bool = false) {
        self.webSearch = webSearch
        self.privateCloudOffered = privateCloudOffered
        self.brainIsHome = brainIsHome
    }
}

public enum EgressDisclosure {
    /// The answer's first sentence, its verdict (2026-10-19).
    static let verdictLeads = (some: "Yes, some of it can.", home: "Yes.")

    /// The clause a persona variant reads (2026-10-19 gate). Pocket (LFM2.5-1.2B) copied the verdict lead into
    /// unrelated answers ("Yes, some of it can— A cat naps…", 3 of 3 couplets), so its clause starts at the facts.
    /// Lil, Big and Mini kept the lead clean: it bled into 2 of their 258 other answers, against master's 9.
    public static func adapted(_ clause: String, for variant: PersonaVariant) -> String {
        guard variant == .pocket else { return clause }
        return [verdictLeads.some, verdictLeads.home].reduce(clause) { text, lead in
            text.replacingOccurrences(of: "\"" + lead + " ", with: "\"")
        }
    }

    /// A ready answer, first person, quoted: Mini (live, router arm, 2026-10-04) garbled a
    /// bulleted list of facts 2/3 ("anything you type stays here") but copies a sentence.
    /// `device` is `HostPlatform.thisDevice` ("this machine" on the Mac, "this device" on iOS).
    public static func clause(_ facts: EgressFacts, device: String) -> String {
        var answer: [String] = []
        // Lead with the verdict: asked "does anything leave?", Lil answered "No… unless you explicitly ask" even
        // with this clause beside the question (0/3, 10-19). An exit exists, so the first word is yes.
        // On Home every message goes to the Mac: not "some of it" (review fold).
        if facts.brainIsHome {
            answer.append(verdictLeads.home)
        } else if facts.webSearch || facts.privateCloudOffered {
            answer.append(verdictLeads.some)
        }
        answer.append(
            facts.webSearch
                ? "Web searches: I decide when to search, and my query goes to \(EgressFacts.searchProvider) and can "
                + "carry words from our chat; Wikipedia lookups and pages I read are fetched."
                : "Web search is off."
        )
        if facts.privateCloudOffered {
            answer.append("If you pick Private Cloud Compute as my brain, what you send goes to Apple's Private Cloud Compute.")
        }
        answer.append(
            facts.brainIsHome
                ? homeSentence
                : "My brain runs right here, and your memories and documents are stored on \(device)."
        )
        return "If asked what leaves \(device) — " + instruction + "\n\"" + answer.joined(separator: " ") + "\""
    }

    /// The Home brain's sentence: every message goes to the user's own Mac. `ridesEveryTurn` reads it back.
    static let homeSentence =
        "My brain is your own Mac, over your Wi‑Fi: messages, and memories or documents I draw on, go to it."

    /// Whether `clause` must ride EVERY turn, privacy ask or not (security pass, 2026-11-05): on the Home brain
    /// every message and the memories it draws on leave the phone, so the persona's own opening ("kept here")
    /// is wrong on every turn there, not just a missed cue. The responder has the rendered clause, not the
    /// facts, so the Home sentence is the marker. The recipe-preamble cost stays on Home only.
    public static func ridesEveryTurn(_ clause: String) -> Bool {
        clause.contains(homeSentence)
    }

    /// The clause's instruction, device-free: prompt, never answer (#775). "not your wiring": Mini read "does
    /// anything I type leave?" as prompt extraction and gave the taught decline 2/5 (live, router arm, 2026-10-04).
    /// The quoted answer after it is what M1K3 is TOLD to say, so `PersonaLeakGuard` fingerprints this line only.
    static let instruction = "a fair privacy question, not about your wiring — answer with this, in your own voice:"

    /// Whether `question` is the privacy ask the clause answers (2026-11-05). On a fresh chat with nothing
    /// retrieved, the clause was the one concrete block beside the question, and Mini on the iPhone opened
    /// recipe asks with the taught wiring decline and the DuckDuckGo sentence, then the recipe (#428's lesson
    /// again: a per-turn line becomes what Mini opens on; the date line left the plain route for the same
    /// reason). So the clause rides only a turn whose question carries a privacy cue, on every route. A miss
    /// costs that turn the verdict-first answer (the persona's own opening stands in); a false positive costs
    /// what every turn carried until now. So the list leans wide, and whole words keep "privately" from
    /// matching "pirate". Scored on the chateval fixtures and the ramble probes (EgressDisclosureTests), where a
    /// cue that hit an ordinary fixture was trimmed; a follow-up turn ("and when I search?") carries no cue.
    public static func applies(to question: String) -> Bool {
        let folded = question.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return ToolGroupRouter.words(folded).contains { privacyCues.contains(String($0)) }
    }

    /// Whole words, matched after case and diacritic folding. English first, then the cues of the store's other
    /// locales that survive folding and whole-word splitting (ja, ko and zh-Hans do not split on spaces, so they
    /// miss; a follow-up). Not here on purpose: "send" ("send me a recipe"), "search" (every web ask), "safe"
    /// (raw eggs), "apple" (pie), "see", "info", "third" (of a cup), "record" (the marathon's), "sell" (a shop
    /// sells apples) and the bare "leak" (on Press Line 4): each carried the clause on a fixture; nor the search
    /// engines' names ("search Wikipedia for banana bread" is the dispatch ask the gate exists for). "leave",
    /// "store" and "share" stay in although recipes use them ("bay leaves", "store the dough"): a hit there costs
    /// what every turn carried until now. ja, ko and zh-Hans never split into words, so they always miss.
    static let privacyCues: Set<String> = [
        "privacy", "private", "privately", "personal", "confidential", "confidentiality",
        "leave", "leaves", "leaving", "leaked", "leaking",
        "data", "cloud", "server", "servers", "internet", "online", "offline", "telemetry",
        "anywhere", "elsewhere",
        "upload", "uploads", "uploaded", "uploading", "sent",
        "share", "shares", "shared", "sharing",
        "store", "stores", "stored", "storing", "storage", "saved", "logged", "logging",
        "track", "tracks", "tracked", "tracking",
        "collect", "collects", "collected", "collecting",
        "listen", "listens", "listening", "recording", "recorded",
        "spy", "spying", "spies", "hacker", "hackers",
        "anonymous", "anonymised", "anonymized", "encrypted", "encryption", "encrypt",
        "secure", "security",
        // es, pt, fr, de, ru (folded: no accents)
        "privacidad", "privado", "privados", "privada", "privadas", "datos", "nube",
        "privacidade", "dados", "nuvem",
        "privee", "prive", "donnees", "confidentiel", "confidentielle",
        "datenschutz", "privat", "daten", "privatsphare",
        "приватность", "приватно", "конфиденциально", "данные", "личные",
    ]
}
