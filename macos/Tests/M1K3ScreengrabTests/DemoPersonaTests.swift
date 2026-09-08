//
//  DemoPersonaTests.swift
//  M1K3ScreengrabTests
//
//  The persona is what a stranger sees on the store. It must be fictional and
//  it must tell the site's one story (the architect call). These pin both —
//  a real name or place slipping into a plate is the failure this exists for.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.85, Prior: Unknown
//

import Foundation
@testable import M1K3Screengrab
import Testing

struct DemoPersonaTests {
    @Test func nothingRealAnywhere() {
        let everything = (
            DemoPersona.memories.map(\.text)
                + DemoPersona.documents.flatMap { [$0.title, $0.text] }
                + DemoPersona.heroConversation.map(\.text)
        ).joined(separator: "\n").lowercased()
        for term in DemoPersona.forbiddenTerms {
            #expect(!everything.contains(term.lowercased()), "real-world term in the persona: \(term)")
        }
    }

    @Test func theHeroExchangeIsTheSitesTerminalDemo() {
        #expect(DemoPersona.heroConversation.count == 2)
        #expect(DemoPersona.heroConversation[0].role == .user)
        #expect(DemoPersona.heroConversation[0].text == "summarise yesterday's call with the architect")
        #expect(DemoPersona.heroConversation[1].role == .assistant)
        #expect(DemoPersona.heroConversation[1].text.contains("original roofline"))
        #expect(DemoPersona.heroConversation[1].text.contains("Friday"))
    }

    @Test func memoriesAreDatedBelievableAndFewEnoughForOneScreen() {
        #expect((4 ... 6).contains(DemoPersona.memories.count))
        let dates = DemoPersona.memories.map(\.createdAt)
        #expect(dates == dates.sorted(), "memories seed oldest → newest")
        #expect(Set(dates).count == dates.count, "each memory carries its own day")
        for m in DemoPersona.memories {
            #expect(m.text.count < 200)
            #expect(m.source == DemoPersona.source)
        }
    }

    @Test func documentsMirrorTheDemoCorpus() {
        let titles = DemoPersona.documents.map(\.title)
        #expect(titles.contains("Retrofit — planning notes"))
        #expect(titles.contains("Weekend loaf — formula"))
        for d in DemoPersona.documents {
            #expect(d.text.count > 200, "\(d.title) is too short to chunk")
            #expect(d.sourceRef.hasPrefix("demo://"))
        }
    }
}
