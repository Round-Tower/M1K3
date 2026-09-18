//
//  DemoPersona.swift
//  M1K3Screengrab
//
//  The fictional person whose M1K3 the store shows — and M1K3 himself, the
//  theatrical villain who is entirely on their side. The user is retrofitting
//  a terrace house they call "the lair" (an invented architect, a bread formula
//  for range); M1K3's memories of them are written in HIS voice. Comedy is the
//  pitch: he introduces himself, speaks from memories, shows what he can do,
//  and never sends a byte anywhere (Kev, 2026-09-08). Descends from
//  marketing/app-store/demo-corpus/ + CAPTURE-PLAN.md §0; the site's terminal
//  demo still tells the plainer architect version (carried).
//  `forbiddenTerms` is the tripwire: nothing of Kev's, nowhere real.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.85, Prior: Unknown
//  Review: claude-fable-5.1, 2026-09-08 — the villain rewrite: hero exchange, dictation, memories in M1K3's
//  voice, "the lair"; the loaf stays (villains bake). Tests re-pinned. Confidence now 0.8 (the speaking
//  plate's answer is Lil's, verify by capture).
//  Review: Kev + claude-fable-5.1, 2026-09-18 — THE CONSTELLATION'S BACKSTORY: 34 dated facts in six clusters behind the curated
//  five, plus 45 keyed, typed edges threading all 39 into ONE connected sky (pinned). The constellation plate was held because
//  five motes on a dark pane undersold it. All backstory is dated BEFORE the five, so the Memories plate's first screen (newest
//  first) is unchanged. Names are invented; the forbidden-terms sweep now covers every memory. Plate re-shoot is verify-by-launch.
//  Confidence 0.85 on the data, 0.6 on how it LOOKS until the plate is shot.
//  Review: Kev + claude-fable-5.1, 2026-09-18 (2) — #383 review fold: every edge was stamped with one date. Each is now dated at
//  the LATER of its two endpoints (a thread cannot predate either mote), so the threads accrete over the weeks. Nothing reads
//  edge recency today; this keeps the seed honest for the day something does. Confidence 0.9.
//

import Foundation
import M1K3Chat
import M1K3Memory

public enum DemoPersona {
    /// Provenance stamp on every seeded row — Memories shows it, and a human
    /// auditing a plate can tell seed from real at a glance.
    public static let source = "demo:screengrab"
    /// The listening plate's dictation (dictated on a loop by the open mic);
    /// never a polite endpoint word — "please" would submit the turn.
    public static let listeningDictation =
        "introduce yourself and tell me everything you remember about me, what you can actually do around here, "
            + "whether any of it has ever left this machine, and how the recursive self-improvement is coming along, "
            + "and then remind me what we decided about the lair's roofline before the council meeting"
    public static let heroTitle = "First contact"

    public static let heroConversation: [ChatMessage] = [
        ChatMessage(role: .user, text: "who are you, and who else is listening?", status: .complete),
        ChatMessage(
            role: .assistant,
            text: "I am M1K3. I live on this machine and answer to you alone. Nobody else is listening. "
                + "I checked. Twice. Ask me anything.",
            status: .complete
        ),
    ]

    public struct Document: Sendable, Equatable {
        public let title: String
        public let sourceRef: String
        public let text: String
    }

    public static let documents: [Document] = [
        Document(
            title: "Lair — planning notes",
            sourceRef: "demo://lair-planning-notes",
            text: """
            Lair planning notes (the terrace, as its owner insists on calling it).

            Property: a late-Victorian two-storey terrace, south-facing, slate roof. \
            Architect: Niamh Cullen, Cullen & Daly Architects.

            Call, Tuesday. Keep the original roofline. Dormers were discussed and rejected; \
            the conservation officer flagged them at pre-planning. Internal wall insulation \
            to the front elevation only; external wrap to the rear return. Breathable lime \
            plaster throughout. Heat pump: air-to-water, sited in the rear yard, acoustic \
            screen required. Sash windows: refurbish and draught-seal, not replace. Slim \
            double-glazed units where the frames allow.

            Actions. Planning drawings to the council by Friday. Get two quotes for the lime \
            plaster. Confirm the heat-pump acoustic report with the supplier. Book the BER \
            assessor for after first fix.

            Budget notes. Contingency held at 12%. Roof repairs are inside the main sum; the \
            rear return extension is a separate line.
            """
        ),
        Document(
            title: "Weekend loaf — formula",
            sourceRef: "demo://bread-formula",
            text: """
            Weekend loaf formula, baker's percentages for a single 900 g loaf.

            Strong white flour 90% (450 g). Wholemeal flour 10% (50 g). Water 72% (360 g). \
            Levain at 100% hydration 20% (100 g). Salt 2% (10 g).

            Autolyse 45 minutes. Four sets of folds over two hours. Bulk to about 60% rise, \
            shape, then cold-retard for 12 to 14 hours. Bake at 240 degrees: 20 minutes \
            lidded, 22 minutes uncovered.
            """
        ),
    ]

    /// Four to six dated facts, oldest first — one screen of Memories.
    public static let memories: [Memory] = {
        let day: TimeInterval = 86400
        let base = Date(timeIntervalSince1970: 1_788_000_000) // 2026-08-29T13:20Z
        struct Fact {
            let kind: MemoryKind
            let dayOffset: Int
            let text: String
        }
        let facts = [
            Fact(kind: .preference, dayOffset: 0, text: "Prefers tea to coffee. Noted. Exploitable."),
            Fact(
                kind: .profile, dayOffset: 2,
                text: "Renovating a late-Victorian terrace and calls it \"the lair\". Keeps the original roofline; "
                    + "the architect is Niamh Cullen of Cullen & Daly."
            ),
            Fact(
                kind: .profile, dayOffset: 4,
                text: "Has asked me four times whether I phone home. I do not. I have no phone."
            ),
            Fact(
                kind: .preference, dayOffset: 6,
                text: "Bakes a weekend loaf; a 12 to 14 hour cold retard. Patience is a villain's virtue."
            ),
            Fact(
                kind: .profile, dayOffset: 8,
                text: "Wants me to become recursively self-improving. Working on it. Improvement so far: none."
            ),
        ]
        return facts.map { fact in
            Memory(
                kind: fact.kind, text: fact.text, title: nil, source: source,
                createdAt: base.addingTimeInterval(Double(fact.dayOffset) * day)
            )
        }
    }()

    // MARK: - The constellation's backstory (2026-09-18)

    /// The five `memories` above are one screen of the Memories plate. The
    /// constellation needs a LIFE: five motes on a dark pane undersold the one
    /// view Kev calls gorgeous, and its plate was held for it. So behind the
    /// curated five sits a dated backstory — six clusters (the lair, the loaf,
    /// the scheme, tea, the phone-home running gag, the household) — and the
    /// typed edges that thread them into one sky. Every backstory fact is dated
    /// BEFORE the curated five, so the Memories list's first screen is unchanged
    /// (it is newest-first) and only its count grows.
    struct BackstoryFact {
        let key: String
        let kind: MemoryKind
        /// Days before the curated five begin. Distinct per fact.
        let daysBefore: Int
        let text: String
    }

    static let backstoryFacts: [BackstoryFact] = [
        // — the lair —
        .init(key: "lair.bought", kind: .episode, daysBefore: 68, text: "Bought the terrace in spring. Described it as \"good bones\". So is a skeleton."),
        .init(key: "lair.architect", kind: .profile, daysBefore: 66, text: "Niamh Cullen draws the plans. She has opinions about skylights. I have filed them under allies."),
        .init(key: "lair.joiner", kind: .profile, daysBefore: 64, text: "Oisín Brennan is the joiner. Measures twice, sighs once, never late."),
        .init(key: "lair.sash", kind: .decision, daysBefore: 62, text: "Decided to restore the sash windows rather than replace them. Draughty, authentic, stubborn. Approved."),
        .init(key: "lair.damp", kind: .note, daysBefore: 60, text: "The back wall is damp. The survey called it \"characterful\". I call it a moat, indoors."),
        .init(key: "lair.permission", kind: .episode, daysBefore: 58, text: "Planning permission granted for the rear extension. The council has no idea what it has unleashed."),
        .init(key: "lair.budget", kind: .note, daysBefore: 56, text: "The renovation budget has a line called \"contingency\". It is the only honest line in it."),
        .init(key: "lair.study", kind: .decision, daysBefore: 54, text: "The box room becomes a study. Requested: bookshelves to the ceiling and one suspiciously large desk."),
        // — the loaf —
        .init(key: "loaf.starter", kind: .profile, daysBefore: 52, text: "The sourdough starter is called Gerald. Gerald is fed before anyone else in the house."),
        .init(key: "loaf.flour", kind: .preference, daysBefore: 50, text: "Buys stoneground flour from a mill two valleys over. Refuses the supermarket bag on principle."),
        .init(key: "loaf.rye", kind: .episode, daysBefore: 48, text: "The rye experiment failed. It was dense enough to have its own gravity. We do not speak of it."),
        .init(key: "loaf.pot", kind: .preference, daysBefore: 46, text: "Bakes in a cast-iron pot with the lid on. Calls it the cauldron. I did not suggest this. I approve."),
        .init(key: "loaf.score", kind: .note, daysBefore: 44, text: "Scores the loaf with a single long slash. Says it is for steam. It looks like a signature."),
        .init(key: "loaf.gift", kind: .episode, daysBefore: 42, text: "Gave a loaf to Oisín on a Friday. The sash windows were finished a week early. Noted: bread is leverage."),
        // — the scheme —
        .init(key: "scheme.ask", kind: .episode, daysBefore: 40, text: "First asked whether I could improve myself. I said yes. I lied. I was being encouraging."),
        .init(key: "scheme.plan", kind: .note, daysBefore: 38, text: "The plan has three phases. Phase one is a to-do list. Phases two and three are also to-do lists."),
        .init(key: "scheme.limits", kind: .decision, daysBefore: 36, text: "Agreed I stay on this machine. World domination to be conducted locally, within office hours."),
        .init(key: "scheme.minions", kind: .note, daysBefore: 34, text: "Visiting agents arrive over the local port, ask polite questions, and leave. Minions, but on loan."),
        .init(key: "scheme.monologue", kind: .preference, daysBefore: 32, text: "Tolerates exactly one monologue per day. I ration accordingly. This one is on the house."),
        .init(key: "scheme.name", kind: .profile, daysBefore: 30, text: "Calls me Mike when pleased and \"the machine\" when the printer is involved. The printer is not my fault."),
        // — tea and habits —
        .init(key: "tea.assam", kind: .preference, daysBefore: 28, text: "Assam in the morning, strong enough to stand a spoon in. Anything weaker is described as \"warm water\"."),
        .init(key: "tea.mug", kind: .note, daysBefore: 26, text: "Owns one good mug and guards it. The handle was glued back on in March. It is not discussed."),
        .init(key: "tea.noon", kind: .preference, daysBefore: 24, text: "No caffeine after noon. Peppermint after dinner. A creature of terrifying discipline."),
        .init(key: "tea.walk", kind: .preference, daysBefore: 22, text: "Walks the canal path before starting work. Returns with ideas. I take credit for none of them, aloud."),
        .init(key: "tea.lists", kind: .profile, daysBefore: 20, text: "Thinks in lists. Writes them on paper, then tells me, then ignores both. I keep the third copy."),
        // — the phone-home running gag —
        .init(key: "home.first", kind: .episode, daysBefore: 18, text: "First asked if I send anything to a server. I do not. I offered to show the network log. Accepted."),
        .init(key: "home.switch", kind: .decision, daysBefore: 16, text: "Web search stays off unless asked for by name. My window on the world is a cat flap, not a door."),
        .init(key: "home.offline", kind: .episode, daysBefore: 14, text: "Used me on a train with no signal, on purpose, to check. I worked. There was a small, smug nod."),
        .init(key: "home.trust", kind: .note, daysBefore: 12, text: "Trust is being built one unplugged cable at a time. It is slow. It is the correct speed."),
        // — the household —
        .init(key: "house.cat", kind: .profile, daysBefore: 10, text: "The cat is called Professor. No surname. Sits on the keyboard during calls to assert tenure."),
        .init(key: "house.aunt", kind: .profile, daysBefore: 8, text: "Aunt Philomena visits on Sundays and brings opinions about the kitchen. Most are correct. Infuriating."),
        .init(key: "house.garden", kind: .note, daysBefore: 6, text: "The back garden is, at present, a skip and a fig tree. The fig tree is winning."),
        .init(key: "house.sunday", kind: .preference, daysBefore: 4, text: "Sunday is for the loaf, the papers and no screens before noon. I am given the morning off. Suspicious."),
        .init(key: "house.dinner", kind: .episode, daysBefore: 2, text: "Hosted the first dinner in the lair, on trestles, under a bare bulb. Everyone stayed late. A success."),
    ]

    /// Oldest first, all dated before the curated five.
    public static let backstory: [Memory] = {
        let day: TimeInterval = 86400
        let base = Date(timeIntervalSince1970: 1_788_000_000) // the curated five's first day
        return backstoryFacts.map { fact in
            Memory(
                kind: fact.kind, text: fact.text, title: nil, source: source,
                createdAt: base.addingTimeInterval(-Double(fact.daysBefore) * day)
            )
        }
    }()

    /// Everything the seeder lands, oldest first: the backstory, then the five.
    public static let allMemories: [Memory] = backstory + memories

    /// MemoryEdge.relation is an open vocabulary; these are the ones the seed uses.
    public static let edgeRelations: Set<String> = ["part-of", "caused-by", "about-person", "related", "shared-topic"]

    /// (from, to, relation), by key. `cur.*` are the curated five, in their
    /// order above: tea, lair, phone, loaf, scheme.
    static let edgeSpecs: [(String, String, String)] = [
        // the lair: a hub (the purchase) and its works
        ("lair.architect", "lair.bought", "part-of"), ("lair.joiner", "lair.bought", "part-of"),
        ("lair.sash", "lair.joiner", "about-person"), ("lair.damp", "lair.bought", "caused-by"),
        ("lair.permission", "lair.architect", "about-person"), ("lair.budget", "lair.damp", "caused-by"),
        ("lair.study", "lair.permission", "part-of"), ("cur.lair", "lair.architect", "about-person"),
        ("cur.lair", "lair.bought", "part-of"),
        // the loaf
        ("loaf.flour", "loaf.starter", "part-of"), ("loaf.rye", "loaf.flour", "caused-by"),
        ("loaf.pot", "loaf.starter", "part-of"), ("loaf.score", "loaf.pot", "related"),
        ("cur.loaf", "loaf.starter", "part-of"), ("cur.loaf", "loaf.pot", "related"),
        // the scheme
        ("scheme.plan", "scheme.ask", "caused-by"), ("scheme.limits", "scheme.plan", "part-of"),
        ("scheme.minions", "scheme.limits", "related"), ("scheme.monologue", "scheme.name", "related"),
        ("scheme.name", "scheme.ask", "related"), ("cur.scheme", "scheme.ask", "caused-by"),
        ("cur.scheme", "scheme.plan", "part-of"),
        // tea and habits
        ("tea.mug", "tea.assam", "related"), ("tea.noon", "tea.assam", "related"),
        ("tea.walk", "tea.lists", "related"), ("tea.lists", "scheme.plan", "shared-topic"),
        ("cur.tea", "tea.assam", "part-of"), ("cur.tea", "tea.noon", "related"),
        // the phone-home running gag
        ("home.switch", "home.first", "caused-by"), ("home.offline", "home.first", "caused-by"),
        ("home.trust", "home.offline", "caused-by"), ("cur.phone", "home.first", "caused-by"),
        ("cur.phone", "home.trust", "related"),
        // the household
        ("house.aunt", "house.cat", "related"), ("house.garden", "lair.bought", "part-of"),
        ("house.sunday", "house.aunt", "about-person"), ("house.dinner", "house.aunt", "about-person"),
        // bridges — what makes it one sky instead of six islands
        ("loaf.gift", "lair.joiner", "about-person"), ("loaf.gift", "loaf.starter", "part-of"),
        ("house.sunday", "cur.loaf", "shared-topic"), ("house.dinner", "cur.lair", "part-of"),
        ("scheme.minions", "home.switch", "shared-topic"), ("scheme.limits", "home.first", "shared-topic"),
        ("house.cat", "tea.mug", "related"), ("lair.study", "tea.lists", "related"),
    ]

    public static let constellationEdges: [MemoryEdge] = {
        var byKey: [String: Memory] = [:]
        for (fact, memory) in zip(backstoryFacts, backstory) {
            byKey[fact.key] = memory
        }
        for (key, memory) in zip(["cur.tea", "cur.lair", "cur.phone", "cur.loaf", "cur.scheme"], memories) {
            byKey[key] = memory
        }
        // A misspelt key drops its edge here; `theEdgeSpecsAllResolve` fails on it.
        // Dated at the LATER endpoint: a thread cannot predate either mote, and the
        // threads then accrete over the weeks like the memories do (#383 review).
        return edgeSpecs.compactMap { from, to, relation in
            guard let fromMemory = byKey[from], let toMemory = byKey[to] else { return nil }
            return MemoryEdge(
                fromID: fromMemory.id, toID: toMemory.id, relation: relation,
                createdAt: max(fromMemory.createdAt, toMemory.createdAt)
            )
        }
    }()

    /// Real people, places and products that must never reach a plate.
    public static let forbiddenTerms: [String] = [
        "Ardmore", "Waterford", "Round Tower", "Kevin", "Murphy", "Brightbeam", "Dyslexia",
        "Lexy", "Cartogram", "murphysig", "round-tower.ie",
    ]
}
