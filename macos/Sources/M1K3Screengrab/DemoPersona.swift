//
//  DemoPersona.swift
//  M1K3Screengrab
//
//  The fictional person whose M1K3 the store shows: a retrofit of a terrace
//  house with an invented architect, a bread formula for range. Lifted from
//  marketing/app-store/demo-corpus/ and CAPTURE-PLAN.md §0 so the site's
//  terminal demo, the README hero and the store listing all tell ONE story.
//  `forbiddenTerms` is the tripwire: nothing of Kev's, nowhere real.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.85, Prior: Unknown
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
        "summarise yesterday's call with the architect and pull out the action list for Friday's planning drawings, "
            + "then check whether the lime plaster quotes have come back and whether the heat pump survey is booked, "
            + "and remind me what we decided about the sash windows and the roofline before the council meeting"
    public static let heroTitle = "Call with the architect"

    public static let heroConversation: [ChatMessage] = [
        ChatMessage(role: .user, text: "summarise yesterday's call with the architect", status: .complete),
        ChatMessage(
            role: .assistant,
            text: "You agreed the retrofit keeps the original roofline; planning docs are due Friday. "
                + "Want the action list?",
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
            title: "Retrofit — planning notes",
            sourceRef: "demo://retrofit-planning-notes",
            text: """
            Retrofit planning notes.

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
            Fact(
                kind: .profile, dayOffset: 0,
                text: "Renovating a late-Victorian terrace; the retrofit keeps the original roofline."
            ),
            Fact(kind: .profile, dayOffset: 2, text: "The architect is Niamh Cullen of Cullen & Daly."),
            Fact(
                kind: .preference, dayOffset: 4,
                text: "Prefers breathable lime plaster over gypsum for the old walls."
            ),
            Fact(kind: .profile, dayOffset: 6, text: "Planning drawings are due to the council on Friday."),
            Fact(kind: .preference, dayOffset: 8, text: "Bakes a weekend loaf; likes a 12 to 14 hour cold retard."),
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
