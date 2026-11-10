//
//  AttachmentStoreTests.swift
//  M1K3ChatTests
//
//  The attachment intake: whatever the user picks (Photos export, Desktop
//  screenshot, download) is COPIED into the app's own attachments directory
//  before the send, so the ImageAttachment URL the transcript persists stays
//  readable across relaunches and never points at a sandbox-scoped original.
//
//  Signed: Kev + claude-fable-5, 2026-07-19, Confidence 0.85 (red-first;
//  pure FileManager logic under a temp directory). Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-10-14 — store(data:) cases for the PhotosPicker (#604). Confidence 0.85.
//

import Foundation
@testable import M1K3Chat
import M1K3Inference
import M1K3Knowledge
import Testing

struct AttachmentStoreTests {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("attachment-store-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("stores a copy inside the attachments directory and returns its attachment")
    func storesCopy() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let original = temp.appendingPathComponent("photo.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: original)

        let store = AttachmentStore(directory: temp.appendingPathComponent("attachments"))
        let attachment = try store.store(originalURL: original)

        #expect(attachment.url.path.contains("attachments"))
        #expect(FileManager.default.fileExists(atPath: attachment.url.path))
        // The copy is independent of the original — deleting the source
        // must not break the stored attachment (the whole point).
        try FileManager.default.removeItem(at: original)
        #expect(FileManager.default.fileExists(atPath: attachment.url.path))
    }

    @Test("preserves the file extension (the VLM processor sniffs by type)")
    func preservesExtension() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let original = temp.appendingPathComponent("shot.jpeg")
        try Data([0xFF, 0xD8]).write(to: original)

        let store = AttachmentStore(directory: temp.appendingPathComponent("attachments"))
        let attachment = try store.store(originalURL: original)
        #expect(attachment.url.pathExtension == "jpeg")
    }

    @Test("two stores of the same file yield distinct attachment files")
    func distinctCopies() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let original = temp.appendingPathComponent("photo.png")
        try Data([0x89]).write(to: original)

        let store = AttachmentStore(directory: temp.appendingPathComponent("attachments"))
        let first = try store.store(originalURL: original)
        let second = try store.store(originalURL: original)
        #expect(first.url != second.url)
    }

    @Test("discard deletes the stored copies; a missing file is a quiet no-op")
    func discardDeletesCopies() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let original = temp.appendingPathComponent("photo.png")
        try Data([0x89]).write(to: original)
        let store = AttachmentStore(directory: temp.appendingPathComponent("attachments"))
        let kept = try store.store(originalURL: original)
        let removed = try store.store(originalURL: original)

        AttachmentStore.discard([removed])
        #expect(!FileManager.default.fileExists(atPath: removed.url.path))
        #expect(FileManager.default.fileExists(atPath: kept.url.path))
        // Discarding again (file already gone) must not throw or crash.
        AttachmentStore.discard([removed])
    }

    @Test("a missing source throws rather than fabricating an attachment")
    func missingSourceThrows() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = AttachmentStore(directory: temp.appendingPathComponent("attachments"))
        #expect(throws: (any Error).self) {
            _ = try store.store(originalURL: temp.appendingPathComponent("nope.png"))
        }
    }

    // MARK: - store(data:fileExtension:) — the Photos picker hands bytes, not a URL

    @Test("stores picked bytes as a file in the attachments directory, keeping the extension")
    func storesData() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = AttachmentStore(directory: temp.appendingPathComponent("attachments"))
        let bytes = Data([0x89, 0x50, 0x4E, 0x47, 0x01])

        let attachment = try store.store(data: bytes, fileExtension: "png")

        #expect(attachment.url.path.contains("attachments"))
        #expect(attachment.url.pathExtension == "png")
        #expect(try Data(contentsOf: attachment.url) == bytes)
    }

    @Test("a missing or odd extension never escapes the directory or yields a dotted name")
    func dataExtensionIsSanitised() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let directory = temp.appendingPathComponent("attachments")
        let store = AttachmentStore(directory: directory)

        let bare = try store.store(data: Data([1]), fileExtension: nil)
        #expect(bare.url.pathExtension.isEmpty)
        #expect(!bare.url.lastPathComponent.hasSuffix("."))

        let hostile = try store.store(data: Data([1]), fileExtension: "../../evil")
        #expect(hostile.url.deletingLastPathComponent().standardizedFileURL
            == directory.standardizedFileURL)
    }

    @Test("empty picked data throws rather than storing a zero-byte image")
    func emptyDataThrows() throws {
        let temp = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }
        let store = AttachmentStore(directory: temp.appendingPathComponent("attachments"))
        #expect(throws: (any Error).self) { try store.store(data: Data(), fileExtension: "png") }
    }

    /// iOS moves the app's data container when the app is updated or reinstalled, so a saved absolute
    /// path goes stale while the file is still there (Kev's phone, 2026-11-10: every photo went blank).
    @Test("a stored photo whose saved path has moved is found again by its file name")
    func reanchorsAMovedContainer() throws {
        let temp = try makeTempDirectory()
        let store = AttachmentStore(directory: temp.appendingPathComponent("attachments"))
        let kept = try store.store(data: Data([1, 2, 3]), fileExtension: "jpg")
        let stale = ImageAttachment(
            url: URL(fileURLWithPath: "/old-container/attachments").appendingPathComponent(kept.url.lastPathComponent)
        )
        #expect(store.reanchored(stale) == kept)
        #expect(store.reanchored(kept) == kept, "a path that still works is left alone")
        let gone = ImageAttachment(url: URL(fileURLWithPath: "/old-container/attachments/never-here.jpg"))
        #expect(store.reanchored(gone) == gone, "a file that is really gone is not invented")
    }

    @MainActor
    @Test("a session that adopts the store re-anchors the photos of the chat it shows, and of chats it opens")
    func theSessionReanchors() throws {
        let temp = try makeTempDirectory()
        let store = AttachmentStore(directory: temp.appendingPathComponent("attachments"))
        let kept = try store.store(data: Data([1, 2, 3]), fileExtension: "jpg")
        let stale = ImageAttachment(
            url: URL(fileURLWithPath: "/old-container/attachments").appendingPathComponent(kept.url.lastPathComponent)
        )
        let session = ChatSession(responder: EchoResponder())
        let asked = ChatMessage(role: .user, text: "What is this?", attachments: [stale], status: .complete)
        session.setActiveConversation(id: UUID(), messages: [asked], title: nil)
        #expect(session.messages.first?.attachments == [stale])

        session.adopt(attachmentStore: store)
        #expect(session.messages.first?.attachments == [kept])

        session.setActiveConversation(id: UUID(), messages: [asked], title: nil)
        #expect(session.messages.first?.attachments == [kept])
    }
}

private struct EchoResponder: RAGResponding {
    func answerStreaming(_: String) async throws -> (sources: [ChunkHit], stream: AsyncStream<String>) {
        ([], AsyncStream { $0.finish() })
    }
}
