//
//  GroundedSearchExclusionTests.swift
//  M1K3KnowledgeTests
//
//  `excludedKinds` on the FTS fallback (no embedder) must be applied IN THE
//  QUERY, not after `limit`: when Photos crowd the bm25 top-K, a post-filter
//  hands an MCP search an empty page while a matching document sits one row
//  below the cut (#523 second-pass review).
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.85, Prior: Unknown
//

import Foundation
@testable import M1K3Knowledge
import Testing

struct GroundedSearchExclusionTests {
    /// One long document chunk with a single "hydraulic", under a pile of
    /// short caption-only Photos that bm25 ranks above it.
    private func storeWithCrowdingPhotos(photos: Int) async throws -> KnowledgeStore {
        let store = try KnowledgeStore()
        let doc = UUID()
        let padding = (1 ... 40).map { "filler\($0)" }.joined(separator: " ")
        try store.index(
            item: KnowledgeItem(id: doc, kind: .document, title: "Plant Notes"),
            chunks: [KnowledgeChunk(itemID: doc, ordinal: 0, content: "\(padding) the hydraulic seal failed")],
            embeddings: nil
        )
        for n in 1 ... photos {
            try await ImageCaptionIngester(store: store)
                .ingest(caption: "hydraulic hydraulic hydraulic", attachmentFilename: "P\(n).jpg")
        }
        return store
    }

    @Test("Photos crowding the FTS top-K cannot starve a search that excludes them")
    func excludedPhotosDoNotStarveTheFTSPage() async throws {
        let store = try await storeWithCrowdingPhotos(photos: 6)
        // The fixture is real: unexcluded, the Photos fill the whole page.
        let crowded = try await GroundedSearch.run(store: store, embedder: nil, query: "hydraulic", limit: 3)
        #expect(crowded.count == 3)
        #expect(crowded.allSatisfy { $0.kind == .image })

        let withheld = try await GroundedSearch.run(
            store: store, embedder: nil, query: "hydraulic", limit: 3, excludedKinds: KnowledgeKind.withheldFromMCP
        )
        #expect(withheld.map(\.itemTitle) == ["Plant Notes"])
        #expect(!withheld.contains { $0.kind == .image })
    }

    @Test("searchFTS(excluding:) withholds in the query and still honours the hidden kinds")
    func searchFTSExcludingIsQuerySide() async throws {
        let store = try await storeWithCrowdingPhotos(photos: 6)
        let hits = try store.searchFTS(query: "hydraulic", limit: 2, excluding: [.image])
        #expect(hits.map(\.kind) == [.document])
        // Naming a kind AND excluding it is the empty set, never a leak.
        #expect(try store.searchFTS(query: "hydraulic", limit: 5, kinds: [.image], excluding: [.image]).isEmpty)
    }
}
