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
//  Review: Kev + claude-opus-5.5, 2026-10-27 — #699: `.style` maps onto `MemoryKind.style` (the
//  uncatalogued kind in M1K3Memory/MemoryStyleKind.swift). Confidence 0.85.
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
}
