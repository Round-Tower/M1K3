//
//  DistilledFactGraphAdapterTests.swift
//  M1K3MemoryChatBridgeTests
//
//  Pins the Chat↔Memory bridge: writing a distilled fact through the
//  DistilledFactGraphWriting seam lands a node tagged `distilled` in the
//  temporal graph — carrying the distiller's classification onto MemoryKind —
//  readable back via the MemoryStore. This is the behaviour that
//  makes chat memory auto-capture reach the graph (not just the corpus) — and it
//  now lives in the package so both shells share it.
//
//  Signed: Kev + claude-opus-4-8, 2026-07-07, Confidence 0.85, Prior: Unknown
//
//  Review (2026-07-08, Kev + claude-fable-5): kind now flows through the seam —
//  each DistilledFactKind must land as the matching MemoryKind (the rawValues
//  align by construction; this pins that they stay aligned).
//  Review: Kev + claude-opus-5.5, 2026-10-27 — #711: an injected `source` tags plain and revived writes; the
//  one-argument init still writes `distilled`. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-27 — #699: `.style` maps onto `MemoryKind.style` (the
//  uncatalogued kind in M1K3Memory/MemoryStyleKind.swift). Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-27 (#699 pre-push review fold) — `refileDistilledFact` re-files a live
//  node of another kind as style by the corpus's normalised identity, lineage kept, and declines a node that is
//  already style or a text nothing carries. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-27 (merge of master's #711 into #699) — an injected source also tags
//  a re-filed node. Confidence 0.85.
//

import M1K3Chat
import M1K3Memory
@testable import M1K3MemoryChatBridge
import Testing

struct DistilledFactGraphAdapterTests {
    @Test func writesDistilledFactAsATaggedNode() async throws {
        let store = try MemoryStore(path: nil)
        let adapter: any DistilledFactGraphWriting = DistilledFactGraphAdapter(store: store)

        try await adapter.writeDistilledFact(
            "Kev takes his coffee black", kind: .note, embedding: [0.1, 0.2, 0.3]
        )

        let all = try store.allMemories()
        let match = all.first { $0.text == "Kev takes his coffee black" }
        #expect(match != nil)
        #expect(match?.source == "distilled")
        #expect(match?.kind == .note)
    }

    @Test("every DistilledFactKind maps onto the matching MemoryKind constant")
    func kindMapsOntoMemoryKind() async throws {
        let store = try MemoryStore(path: nil)
        let adapter: any DistilledFactGraphWriting = DistilledFactGraphAdapter(store: store)

        let expected: [DistilledFactKind: MemoryKind] = [
            .profile: .profile, .preference: .preference,
            .decision: .decision, .episode: .episode, .note: .note,
            .style: .style,
        ]
        for kind in DistilledFactKind.allCases {
            try await adapter.writeDistilledFact(
                "fact classified as \(kind.rawValue)", kind: kind, embedding: [0.1, 0.2, 0.3]
            )
        }
        let all = try store.allMemories()
        for kind in DistilledFactKind.allCases {
            let match = all.first { $0.text == "fact classified as \(kind.rawValue)" }
            #expect(match?.kind == expected[kind])
        }
    }

    @Test("an injected source tags plain and revived nodes; the one-argument init still writes distilled")
    func sourceIsInjectable() async throws {
        let store = try MemoryStore(path: nil)
        let tagged = DistilledFactGraphAdapter(store: store, source: "import/chatgpt/2026-10-26")

        try await tagged.writeDistilledFact("Kev keeps bees", kind: .profile, embedding: [0.1, 0.2, 0.3])
        _ = try await tagged.reviveFact("Kev keeps hens", kind: .note, embedding: [0.3, 0.2, 0.1])

        let all = try store.allMemories()
        #expect(all.first { $0.text == "Kev keeps bees" }?.source == "import/chatgpt/2026-10-26")
        #expect(all.first { $0.text == "Kev keeps hens" }?.source == "import/chatgpt/2026-10-26")
        #expect(DistilledFactGraphAdapter(store: store).source == "distilled")
    }

    @Test("#699: a live node of another kind re-files as style by normalised text, its lineage kept")
    func refileMakesALiveNodeStyle() async throws {
        let store = try MemoryStore(path: nil)
        let adapter: any DistilledFactGraphWriting = DistilledFactGraphAdapter(store: store)
        try await adapter.writeDistilledFact("The user prefers short answers.", kind: .preference, embedding: [1, 0, 0])

        // The corpus dedupes on the normalised text, so the join here must too.
        let refiled = try await adapter.refileDistilledFact(
            "the user prefers short answers", as: .style, embedding: [1, 0, 0]
        )
        #expect(refiled)

        #expect(try store.liveStyleTexts() == ["The user prefers short answers."])
        #expect(try store.allMemories().count == 1)
        let all = try store.allMemories(includeSuperseded: true)
        let head = try #require(all.first { $0.supersededBy == nil })
        #expect(SupersessionChain.history(endingAt: head, in: all).map(\.kind) == [.preference, .style])
    }

    @Test("#699: a node that is already style, or a text no live node carries, is not re-filed")
    func refileDeclines() async throws {
        let store = try MemoryStore(path: nil)
        let adapter: any DistilledFactGraphWriting = DistilledFactGraphAdapter(store: store)
        try await adapter.writeDistilledFact("The user wants no bullet lists.", kind: .style, embedding: [1, 0, 0])

        let alreadyStyle = try await adapter.refileDistilledFact(
            "The user wants no bullet lists.", as: .style, embedding: [1, 0, 0]
        )
        let nothingCarriesIt = try await adapter.refileDistilledFact(
            "The user prefers metric.", as: .style, embedding: [0, 1, 0]
        )
        #expect(!alreadyStyle)
        #expect(!nothingCarriesIt)
        #expect(try store.allMemories(includeSuperseded: true).count == 1)
    }

    @Test("an injected source also tags a re-filed node, so forgetting the import puts the old kind back")
    func refileCarriesTheInjectedSource() async throws {
        let store = try MemoryStore(path: nil)
        try await DistilledFactGraphAdapter(store: store)
            .writeDistilledFact("The user prefers short answers.", kind: .preference, embedding: [1, 0, 0])
        let tag = "import/claude/2026-10-27"

        let refiled = try await DistilledFactGraphAdapter(store: store, source: tag)
            .refileDistilledFact("The user prefers short answers.", as: .style, embedding: [1, 0, 0])

        #expect(refiled)
        let head = try #require(try store.allMemories().first)
        #expect(head.kind == .style)
        #expect(head.source == tag)
        #expect(try store.forget(source: tag) == 1)
        #expect(try store.allMemories().map(\.kind) == [.preference])
    }
}
