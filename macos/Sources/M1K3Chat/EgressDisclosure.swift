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
//

import Foundation

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
    /// A ready answer, first person, quoted: Mini (live, router arm, 2026-10-04) garbled a
    /// bulleted list of facts 2/3 ("anything you type stays here") but copies a sentence.
    /// `device` is `HostPlatform.thisDevice` ("this Mac").
    public static func clause(_ facts: EgressFacts, device: String) -> String {
        var answer: [String] = []
        // Lead with the verdict: asked "does anything leave?", Lil answered "No… unless you explicitly ask" even
        // with this clause beside the question (0/3, 10-19). An exit exists, so the first word is yes.
        if facts.webSearch || facts.privateCloudOffered || facts.brainIsHome {
            answer.append("Yes, some of it can.")
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
                ? "My brain is your own Mac, over your Wi‑Fi: messages, and memories or documents I draw on, go to it."
                : "My brain runs right here, and your memories and documents are stored on \(device)."
        )
        // "not your wiring": Mini read "does anything I type leave?" as prompt extraction and
        // gave the taught decline 2/5 (live, router arm, 2026-10-04).
        return "If asked what leaves \(device) — a fair privacy question, not about your wiring — answer with this, "
            + "in your own voice:\n\"" + answer.joined(separator: " ") + "\""
    }
}
