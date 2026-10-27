//
//  MemoryStyleKindTests.swift
//  M1K3MemoryTests
//
//  #699 Phase 1: the `style` kind — how the user asked to be answered (length, format,
//  register), stored in the graph like any fact and read back newest first for the
//  persona's style line. Pins that it is its own kind, that it stays OUT of the
//  catalogued vocabulary (MCP `remember` can't write it), that the read is newest
//  first over the WHOLE live set (no 500-row window can drop an old ask), that it
//  survives the store being reopened at the same path (a relaunch), and that an edit
//  is a supersede whose lineage the "How I learned this" section can show.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85, Prior: none (new file)
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — visibility is the other half of consent:
//  the Memories list (`reviewableMemories`) carries every live style row however far past the 500-row window it
//  sits, so an ask that rides every prompt can always be seen and forgotten. Confidence 0.85.
//

import Foundation
import M1K3Memory
import Testing

struct MemoryStyleKindTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func style(_ text: String, at date: Date, source: String = "distilled") -> Memory {
        Memory(kind: .style, text: text, source: source, createdAt: date)
    }

    @Test("style is its own kind, stored as the string \"style\"")
    func styleIsItsOwnKind() {
        #expect(MemoryKind.style.rawValue == "style")
        #expect(MemoryKind.style != .preference)
    }

    @Test("style stays out of the catalogued vocabulary: an MCP or App Intents label can't write it")
    func styleIsNotCatalogued() {
        #expect(!MemoryKind.catalogued.contains(.style))
        #expect(MemoryKind(catalogued: "style") == .note)
        #expect(MemoryKind(catalogued: " Style ") == .note)
    }

    @Test("live style texts read newest first and skip every other kind")
    func styleTextsNewestFirst() throws {
        let store = try MemoryStore(path: nil)
        try store.remember(style("The user prefers short answers.", at: t0), embedding: [1, 0, 0])
        try store.remember(
            Memory(kind: .preference, text: "The user prefers tea.", source: "distilled", createdAt: t0 + 30),
            embedding: [0, 1, 0]
        )
        try store.remember(style("The user wants no bullet lists.", at: t0 + 60), embedding: [0, 0, 1])

        #expect(try store.liveStyleTexts() == ["The user wants no bullet lists.", "The user prefers short answers."])
    }

    @Test("a store with no style rows reads empty")
    func noStyleReadsEmpty() throws {
        let store = try MemoryStore(path: nil)
        #expect(try store.liveStyleTexts().isEmpty)
        try store.remember(
            Memory(kind: .note, text: "The user lives in Cork.", source: "distilled", createdAt: t0),
            embedding: [1, 0, 0]
        )
        #expect(try store.liveStyleTexts().isEmpty)
    }

    @Test("an old style ask is never windowed out by newer memories (allMemories defaults to 500)")
    func oldStyleSurvivesABigStore() throws {
        let store = try MemoryStore(path: nil)
        try store.remember(style("The user prefers short answers.", at: t0), embedding: [1, 0, 0])
        for index in 0 ..< 501 {
            try store.remember(
                Memory(kind: .note, text: "note \(index)", source: "distilled", createdAt: t0 + Double(index + 1)),
                embedding: [0, 1, Float(index)]
            )
        }
        #expect(try !store.allMemories().contains { $0.kind == .style }) // the default window misses it
        #expect(try store.liveStyleTexts() == ["The user prefers short answers."])
    }

    @Test("style rows survive the store being reopened at the same path (a relaunch)")
    func styleSurvivesAReopen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m1k3-style-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("memory.sqlite").path

        do {
            let store = try MemoryStore(path: path)
            try store.remember(style("The user prefers short answers.", at: t0), embedding: [1, 0, 0])
            try store.remember(style("The user wants no bullet lists.", at: t0 + 60), embedding: [0, 0, 1])
        }
        let reopened = try MemoryStore(path: path)
        #expect(try reopened.liveStyleTexts() == ["The user wants no bullet lists.", "The user prefers short answers."])
    }

    @Test("an edit supersedes: the old text leaves the live set, the lineage keeps it, \"user:edit\" reads as told")
    func editIsASupersede() throws {
        let store = try MemoryStore(path: nil)
        let old = style("The user prefers short answers.", at: t0)
        try store.remember(old, embedding: [1, 0, 0])
        let edited = style("The user prefers answers of three sentences or fewer.", at: t0 + 60, source: "user:edit")
        try store.rememberConnected(edited, embedding: [1, 0.1, 0], supersedes: old.id)

        #expect(try store.liveStyleTexts() == ["The user prefers answers of three sentences or fewer."])
        let lineage = try SupersessionChain.history(endingAt: edited, in: store.allMemories(includeSuperseded: true))
        #expect(lineage.map(\.text) == [
            "The user prefers short answers.", "The user prefers answers of three sentences or fewer.",
        ])
        #expect(MemoryProvenance(source: "user:edit") == .youToldMe)
    }

    @Test("the Memories list carries every live style row, even one 600 newer rows push out of the window")
    func listShowsAnOldStyleRow() throws {
        let store = try MemoryStore(path: nil)
        let old = style("The user prefers short answers.", at: t0)
        try store.remember(old, embedding: [1, 0, 0])
        for index in 0 ..< 600 {
            try store.remember(
                Memory(kind: .note, text: "note \(index)", source: "distilled", createdAt: t0 + Double(index + 1)),
                embedding: [0, 1, Float(index)]
            )
        }
        #expect(try !store.allMemories(limit: 500).contains { $0.id == old.id }) // the window misses it

        let listed = try store.reviewableMemories(limit: 500)

        #expect(listed.count == 501)
        #expect(listed.last?.id == old.id) // newest first, the old ask at the end
        #expect(listed.filter { $0.id == old.id }.count == 1)
        #expect(try store.liveStyleMemories().map(\.id) == [old.id])
    }

    @Test("a list window that already holds the style rows is returned as it is, never doubled")
    func listWithinTheWindowIsUnchanged() throws {
        let store = try MemoryStore(path: nil)
        try store.remember(style("The user prefers short answers.", at: t0), embedding: [1, 0, 0])
        try store.remember(
            Memory(kind: .note, text: "The user lives in Cork.", source: "distilled", createdAt: t0 + 30),
            embedding: [0, 1, 0]
        )
        #expect(try store.reviewableMemories() == store.allMemories())
        #expect(try store.reviewableMemories(includeSuperseded: true) == store.allMemories(includeSuperseded: true))
    }
}
