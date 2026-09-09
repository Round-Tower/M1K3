//
//  DemoPersonaTests.swift
//  M1K3ScreengrabTests
//
//  The persona is what a stranger sees on the store. It must be fictional and
//  it must be M1K3 the theatrical villain, on the user's side (the lair, the
//  loaf, no phone home). These pin both —
//  a real name or place slipping into a plate is the failure this exists for.
//
//  Signed: Kev + claude-fable-5.1, 2026-09-07, Confidence 0.85, Prior: Unknown
//  Review: claude-fable-5.1, 2026-09-08 — re-pinned to the villain persona (first contact, the lair,
//  memories in M1K3's voice). Confidence now 0.85.
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

    @Test func theHeroExchangeIsFirstContact() {
        #expect(DemoPersona.heroConversation.count == 2)
        #expect(DemoPersona.heroConversation[0].role == .user)
        #expect(DemoPersona.heroConversation[0].text == "who are you, and who else is listening?")
        #expect(DemoPersona.heroConversation[1].role == .assistant)
        #expect(DemoPersona.heroConversation[1].text.contains("Nobody else is listening"))
        #expect(DemoPersona.heroConversation[1].text.contains("this machine"), "device-neutral: the seed is shared with iOS/visionOS")
        #expect(DemoPersona.heroTitle == "First contact")
    }

    @Test func memoriesSpeakInM1K3sVoiceAndCarryTheGags() {
        let all = DemoPersona.memories.map(\.text).joined(separator: "\n")
        #expect(all.contains("the lair"))
        #expect(all.contains("I have no phone"))
        #expect(all.contains("recursively self-improving"))
        #expect(all.contains("original roofline"), "the roofline line is what the voice plates recall")
    }

    @Test func theDictationMakesHimIntroduceHimselfFromMemory() {
        let d = DemoPersona.listeningDictation
        #expect(d.hasPrefix("introduce yourself"))
        #expect(d.contains("left this machine"))
        #expect(d.contains("roofline"))
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
        #expect(titles.contains("Lair — planning notes"))
        #expect(titles.contains("Weekend loaf — formula"))
        for d in DemoPersona.documents {
            #expect(d.text.count > 200, "\(d.title) is too short to chunk")
            #expect(d.sourceRef.hasPrefix("demo://"))
        }
    }
}
