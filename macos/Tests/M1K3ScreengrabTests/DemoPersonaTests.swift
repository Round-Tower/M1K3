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
//  Review: Kev + claude-fable-5.1, 2026-09-18 — five pins for the constellation backstory: a life not a list, the curated five
//  stay the newest, every edge key resolves, edges well-formed, and no lonely motes in ONE connected sky. Confidence 0.9.
//  Review: Kev + claude-fable-5.1, 2026-09-18 (2) — one more pin: an edge is dated at its later endpoint (red on 44 of 45). Confidence 0.9.
//

import Foundation
@testable import M1K3Screengrab
import Testing

struct DemoPersonaTests {
    @Test func nothingRealAnywhere() {
        let everything = (
            DemoPersona.allMemories.map(\.text)
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

    // MARK: - The constellation's backstory (2026-09-18)

    @Test func theBackstoryIsALifeNotAList() {
        let story = DemoPersona.backstory
        #expect((28 ... 40).contains(story.count), "enough motes to read as a life; few enough to stay legible")
        let dates = story.map(\.createdAt)
        #expect(dates == dates.sorted(), "oldest → newest")
        #expect(Set(dates).count == dates.count, "each memory carries its own moment")
        for m in story {
            #expect(m.text.count < 200)
            #expect(m.source == DemoPersona.source)
        }
        // More than one kind, or the constellation is one colour.
        #expect(Set(story.map(\.kind)).count >= 3)
    }

    @Test func theCuratedFiveStayTheNewestSoTheMemoriesPlateIsUnchanged() throws {
        let newestBackstory = try #require(DemoPersona.backstory.map(\.createdAt).max())
        let oldestCurated = try #require(DemoPersona.memories.map(\.createdAt).min())
        #expect(newestBackstory < oldestCurated)
        #expect(DemoPersona.allMemories.count == DemoPersona.backstory.count + DemoPersona.memories.count)
        #expect(Array(DemoPersona.allMemories.suffix(DemoPersona.memories.count)) == DemoPersona.memories)
        #expect(Set(DemoPersona.allMemories.map(\.id)).count == DemoPersona.allMemories.count)
    }

    @Test func theEdgeSpecsAllResolve() {
        // Edges are written by KEY; a misspelt key silently drops its edge at build.
        #expect(DemoPersona.constellationEdges.count == DemoPersona.edgeSpecs.count)
        #expect(Set(DemoPersona.backstoryFacts.map(\.key)).count == DemoPersona.backstoryFacts.count, "duplicate key")
        #expect(Set(DemoPersona.backstoryFacts.map(\.daysBefore)).count == DemoPersona.backstoryFacts.count)
    }

    @Test func theEdgesAreWellFormed() {
        let ids = Set(DemoPersona.allMemories.map(\.id))
        let edges = DemoPersona.constellationEdges
        #expect(edges.count >= 30)
        var seen: Set<String> = []
        for edge in edges {
            #expect(ids.contains(edge.fromID) && ids.contains(edge.toID), "an edge points outside the seed")
            #expect(edge.fromID != edge.toID, "a memory related to itself")
            #expect(DemoPersona.edgeRelations.contains(edge.relation), "unknown relation: \(edge.relation)")
            #expect(seen.insert("\(edge.fromID)>\(edge.toID)>\(edge.relation)").inserted, "duplicate edge")
        }
    }

    @Test func anEdgeIsNeverOlderThanTheMemoriesItJoins() {
        // A thread cannot predate either mote. Each edge is dated at the LATER of
        // its two endpoints — so if edge recency ever feeds layout or opacity, the
        // seed tells the truth instead of 45 edges all claiming one moment.
        let dates = Dictionary(uniqueKeysWithValues: DemoPersona.allMemories.map { ($0.id, $0.createdAt) })
        for edge in DemoPersona.constellationEdges {
            let from = dates[edge.fromID] ?? .distantFuture
            let to = dates[edge.toID] ?? .distantFuture
            #expect(edge.createdAt == max(from, to))
        }
        #expect(Set(DemoPersona.constellationEdges.map(\.createdAt)).count > 10, "the threads accrete over the weeks")
    }

    @Test func noLonelyMotesAndOneSky() {
        // Every memory is threaded to something, and the threads join into ONE
        // connected sky — clusters, with bridges between them. Five loose dots on
        // a dark pane is the plate this seed exists to replace.
        let all = DemoPersona.allMemories
        var neighbours: [UUID: Set<UUID>] = [:]
        for edge in DemoPersona.constellationEdges {
            neighbours[edge.fromID, default: []].insert(edge.toID)
            neighbours[edge.toID, default: []].insert(edge.fromID)
        }
        for memory in all {
            #expect(!(neighbours[memory.id] ?? []).isEmpty, "lonely mote: \(memory.text.prefix(40))")
        }
        var reached: Set<UUID> = []
        var frontier = all.first.map { [$0.id] } ?? []
        while let next = frontier.popLast() {
            guard reached.insert(next).inserted else { continue }
            frontier.append(contentsOf: neighbours[next] ?? [])
        }
        #expect(reached.count == all.count, "the sky is in \(all.count - reached.count)+ pieces")
    }
}
