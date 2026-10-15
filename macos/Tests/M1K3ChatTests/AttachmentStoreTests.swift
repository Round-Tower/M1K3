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
}
