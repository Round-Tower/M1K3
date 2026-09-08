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
            text: "I am M1K3. I live on this Mac and answer to you alone. Nobody else is listening. "
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

    /// Real people, places and products that must never reach a plate.
    public static let forbiddenTerms: [String] = [
        "Ardmore", "Waterford", "Round Tower", "Kevin", "Murphy", "Brightbeam", "Dyslexia",
        "Lexy", "Cartogram", "murphysig", "round-tower.ie",
    ]
}
