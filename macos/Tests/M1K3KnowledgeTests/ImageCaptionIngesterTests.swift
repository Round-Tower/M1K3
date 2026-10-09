//
//  ImageCaptionIngesterTests.swift
//  M1K3KnowledgeTests
//
//  Caption memory (Stream D, 1.1 slice): a neutral caption of a chat photo is
//  ingested as a string-backed `.image` ("Photo") item. The challenger's
//  safeguards are pinned here: the kind is in grounding and in BOTH launch
//  sweeps, never donated to Spotlight, sourceRef is the attachment FILENAME
//  (not an absolute container path), and the cascade keys on that ref.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.8, Prior: Unknown

import Foundation
@testable import M1K3Knowledge
import Testing

struct ImageCaptionIngesterTests {
    private let caption = "A whiteboard listing three pricing tiers: Free, Pro at 12 euro, Team at 40 euro."

    @Test func ingestsAsPhotoKindWithModelWrittenSource() async throws {
        let store = try KnowledgeStore()
        let ingester = ImageCaptionIngester(store: store, embedder: HashingEmbeddingService())
        let result = try await ingester.ingest(caption: caption, attachmentFilename: "A1B2.jpg")
        let item = try #require(try store.item(id: result.itemID))
        #expect(item.kind == .image)
        #expect(item.kind.rawValue == "image")
        #expect(item.source == .captioned)
        #expect(item.sourceRef == "attachment:A1B2.jpg")
    }

    @Test func sourceRefKeepsTheFilenameOnly() {
        #expect(ImageCaptionIngester.sourceRef(forAttachment: "/var/mobile/Containers/X/A1B2.jpg") == "attachment:A1B2.jpg")
        #expect(ImageCaptionIngester.sourceRef(forAttachment: "A1B2.jpg") == "attachment:A1B2.jpg")
    }

    @Test func resendOfTheSameAttachmentDedupes() async throws {
        let store = try KnowledgeStore()
        let ingester = ImageCaptionIngester(store: store, embedder: HashingEmbeddingService())
        let first = try await ingester.ingest(caption: caption, attachmentFilename: "A1B2.jpg")
        let second = try await ingester.ingest(caption: "Something else", attachmentFilename: "A1B2.jpg")
        #expect(second.wasDeduped)
        #expect(second.itemID == first.itemID)
        #expect(try store.allItems(kind: .image).count == 1)
    }

    @Test func retrievableByACaptionWordThroughGrounding() async throws {
        let store = try KnowledgeStore()
        let embedder = HashingEmbeddingService()
        try await ImageCaptionIngester(store: store, embedder: embedder)
            .ingest(caption: caption, attachmentFilename: "A1B2.jpg")
        let hits = try store.searchFTS(query: "whiteboard pricing", limit: 5)
        #expect(hits.contains { $0.kind == .image })
        let vector = try await embedder.embedQuery("the whiteboard photo about pricing")
        let grounded = try store.searchGrounding(query: "whiteboard pricing", queryVector: vector)
        #expect(grounded.contains { $0.kind == .image })
    }

    @Test func titleIsTheFirst60CharactersOfTheCaption() {
        let title = ImageCaptionIngester.title(forCaption: caption)
        #expect(title.count <= 60)
        #expect(caption.hasPrefix(title.trimmingCharacters(in: .whitespaces)))
        #expect(ImageCaptionIngester.title(forCaption: "  \n Short one.  ") == "Short one.")
    }

    @Test func blankCaptionIsRefused() async throws {
        let store = try KnowledgeStore()
        let ingester = ImageCaptionIngester(store: store)
        await #expect(throws: ImageCaptionIngester.CaptionError.self) {
            try await ingester.ingest(caption: "  \n ", attachmentFilename: "A.jpg")
        }
    }

    @Test func forgetRemovesTheItemByAttachment() async throws {
        let store = try KnowledgeStore()
        let ingester = ImageCaptionIngester(store: store)
        try await ingester.ingest(caption: caption, attachmentFilename: "A1B2.jpg")
        try await ingester.ingest(caption: "A cat on a sofa.", attachmentFilename: "C3D4.jpg")
        let removed = try ingester.forget(attachments: ["/x/y/A1B2.jpg", "never-captioned.jpg"])
        #expect(removed == 1)
        #expect(try store.itemID(forSourceRef: "attachment:A1B2.jpg") == nil)
        #expect(try store.itemID(forSourceRef: "attachment:C3D4.jpg") != nil)
    }

    @Test func forgetOnlyTouchesPhotoItems() async throws {
        let store = try KnowledgeStore()
        try await DocumentIngester(store: store).ingest(
            title: "Doc", text: "plain", sourceRef: "attachment:A1B2.jpg"
        )
        let removed = try ImageCaptionIngester(store: store).forget(attachments: ["A1B2.jpg"])
        #expect(removed == 0)
    }

    // MARK: - Kind wiring (challenger safeguards)

    @Test func imageIsInGroundingAndBothSweeps() {
        #expect(KnowledgeStore.groundingDocumentKinds.contains(.image))
        #expect(KnowledgeKind.launchSweepKinds.contains(.image))
    }

    @Test func everyRetrievableStaticKindIsInTheLaunchSweep() {
        let retrievable = Set(KnowledgeKind.allStaticKinds).subtracting(KnowledgeKind.hiddenFromRetrieval)
        #expect(Set(KnowledgeKind.launchSweepKinds) == retrievable)
    }

    @Test func imageIsNeverDonatedToSpotlight() {
        #expect(SpotlightDonorPolicy.entry(for: KnowledgeItem(kind: .image, title: "A whiteboard")) == nil)
    }

    @Test func photoLabel() {
        #expect(KnowledgeKind.image.displayLabel == "Photo")
        #expect(KnowledgeKind.document.displayLabel == "Document")
    }

    @Test func modelThinkingSweepReachesPhotos() async throws {
        let store = try KnowledgeStore()
        try await ImageCaptionIngester(store: store)
            .ingest(caption: "<think>hmm the image shows", attachmentFilename: "T.jpg")
        let moved = try store.quarantineModelThinking()
        #expect(moved.count == 1)
    }
}
