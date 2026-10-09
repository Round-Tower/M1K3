//
//  PhotoMemoryTests.swift
//  M1K3ChatTests
//
//  The shared "Remember this photo" model both shells bind to: row state
//  (looking / remembered / failed), single-flight per attachment, refusal by
//  brain name WITHOUT touching the provider, ingest into the knowledge store,
//  and the forget cascade.
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.8, Prior: Unknown
//  Review: Kev + claude-fable-5.1, 2026-10-09 (#523 second-pass fold) — a forget the store refuses is no longer
//  swallowed: it logs, returns 0, and the row keeps reading the store (still remembered — the truth).

import Foundation
@testable import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import Testing

private final class FakeCaptioner: InferenceProvider, ImageCaptioning, @unchecked Sendable {
    let name = "fake"
    let isAvailable = true
    private let lock = NSLock()
    private(set) var calls = 0
    var reply = "A whiteboard with three pricing tiers."
    var gate: (@Sendable () async -> Void)?

    func generate(prompt _: String) async throws -> String {
        ""
    }

    func generateStreaming(prompt _: String) -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }

    func caption(image _: ImageAttachment, prompt _: String) async throws -> String {
        lock.withLock { calls += 1 }
        await gate?()
        return reply
    }
}

@MainActor
struct PhotoMemoryTests {
    private let image = ImageAttachment(url: URL(fileURLWithPath: "/containers/x/attachments/W1.png"))

    private func makeMemory(
        provider: FakeCaptioner, tier: BrainTier = .lil, store: KnowledgeStore
    ) -> PhotoMemory {
        PhotoMemory(
            provider: { provider }, tier: { tier },
            ingester: ImageCaptionIngester(store: store, embedder: HashingEmbeddingService())
        )
    }

    @Test("remembering captions the photo and stores a Photo item keyed on the filename")
    func remembers() async throws {
        let store = try KnowledgeStore()
        let memory = makeMemory(provider: FakeCaptioner(), store: store)
        #expect(memory.state(for: image) == nil)
        await memory.remember(image)
        #expect(memory.state(for: image) == .remembered)
        let id = try #require(try store.itemID(forSourceRef: "attachment:W1.png"))
        #expect(try store.item(id: id)?.kind == .image)
    }

    @Test("a wrong brain is refused by name and the provider is never called")
    func refusesByName() async throws {
        let provider = FakeCaptioner()
        let store = try KnowledgeStore()
        let memory = makeMemory(provider: provider, tier: .mini, store: store)
        await memory.remember(image)
        guard case let .failed(message) = memory.state(for: image) else {
            Issue.record("expected a failed state")
            return
        }
        #expect(message.contains("Switch to Lil"))
        #expect(provider.calls == 0)
        #expect(try store.allItems(kind: .image).isEmpty)
    }

    @Test("an unusable caption fails visibly and stores nothing")
    func unusableStoresNothing() async throws {
        let provider = FakeCaptioner()
        provider.reply = "I can't describe this."
        let store = try KnowledgeStore()
        let memory = makeMemory(provider: provider, store: store)
        await memory.remember(image)
        guard case .failed = memory.state(for: image) else {
            Issue.record("expected failed")
            return
        }
        #expect(try store.allItems(kind: .image).isEmpty)
    }

    @Test("a second tap while looking does not start a second caption")
    func singleFlight() async throws {
        let provider = FakeCaptioner()
        let release = AsyncStream<Void>.makeStream()
        provider.gate = { for await _ in release.stream {
            return
        } }
        let store = try KnowledgeStore()
        let memory = makeMemory(provider: provider, store: store)
        let first = Task { await memory.remember(image) }
        while memory.state(for: image) != .looking {
            await Task.yield()
        }
        await memory.remember(image)
        release.continuation.yield()
        await first.value
        #expect(provider.calls == 1)
        #expect(memory.state(for: image) == .remembered)
    }

    @Test("an already-remembered photo reads as remembered from the store, and a re-tap does no work")
    func rememberedFromStore() async throws {
        let provider = FakeCaptioner()
        let store = try KnowledgeStore()
        try await ImageCaptionIngester(store: store)
            .ingest(caption: "Earlier caption.", attachmentFilename: "W1.png")
        let memory = makeMemory(provider: provider, store: store)
        #expect(memory.state(for: image) == .remembered)
        await memory.remember(image)
        #expect(provider.calls == 0)
    }

    @Test("forgetting clears the state and removes the item")
    func forgets() async throws {
        let store = try KnowledgeStore()
        let memory = makeMemory(provider: FakeCaptioner(), store: store)
        await memory.remember(image)
        let count = memory.forget([image])
        #expect(count == 1)
        #expect(memory.state(for: image) == nil)
        #expect(try store.allItems(kind: .image).isEmpty)
    }

    @Test("a forget the store refuses is reported, not swallowed: 0 removed, still remembered, shell notified")
    func forgetFailureIsHonest() async throws {
        struct StoreRefused: Error {}
        let store = try KnowledgeStore()
        let memory = PhotoMemory(
            provider: { FakeCaptioner() }, tier: { .lil },
            ingester: ImageCaptionIngester(store: store, embedder: HashingEmbeddingService()),
            forgetter: { _ in throw StoreRefused() }
        )
        await memory.remember(image)
        var changes = 0
        memory.onChange = { changes += 1 }
        let removed = memory.forget([image])
        #expect(removed == 0)
        // The store still holds the Photo, and the row says so -- never a quiet "gone".
        #expect(memory.state(for: image) == .remembered)
        #expect(try store.allItems(kind: .image).count == 1)
        #expect(changes == 1)
    }

    @Test("a Photo deleted from the Documents list resets the row to the plain action -- the store is the truth")
    func storeDeleteResetsRow() async throws {
        let store = try KnowledgeStore()
        let memory = makeMemory(provider: FakeCaptioner(), store: store)
        await memory.remember(image)
        #expect(memory.state(for: image) == .remembered)
        let id = try #require(try store.itemID(forSourceRef: "attachment:W1.png"))
        #expect(try store.deleteItem(id: id))
        #expect(memory.state(for: image) == nil)
    }

    @Test("onChange fires after a remember and after a forget")
    func notifiesShell() async throws {
        let store = try KnowledgeStore()
        let memory = makeMemory(provider: FakeCaptioner(), store: store)
        var changes = 0
        memory.onChange = { changes += 1 }
        await memory.remember(image)
        _ = memory.forget([image])
        #expect(changes == 2)
    }
}
