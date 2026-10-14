//
//  AttachmentStore.swift
//  M1K3Chat
//
//  Copies a user-picked image into the app's own attachments directory before
//  a send, so the `ImageAttachment` URL the transcript persists survives
//  relaunches and never points at a sandbox-scoped original the app can't
//  reopen (a security-scoped picker URL is only readable inside the picker's
//  access window). UUID filenames keep repeated sends of the same file
//  distinct; the original's extension is preserved because type sniffing
//  downstream (the VLM processor / QuickLook thumbnails) reads it.
//
//  Signed: Kev + claude-fable-5, 2026-07-19, Confidence 0.85 (TDD'd against a
//  temp directory: copy, independence-from-original, extension, distinctness,
//  missing-source throw). Prior: Unknown
//  Review: Kev + claude-opus-5-5, 2026-10-14 — store(data:fileExtension:) for the iOS PhotosPicker (#604). Confidence 0.85.
//

import Foundation
import M1K3Inference

/// Intake for chat image attachments: copy in, hand back the attachment.
public struct AttachmentStore: Sendable {
    private let directory: URL

    /// `directory` is created on first store if absent (e.g.
    /// `Application Support/attachments` inside the container).
    public init(directory: URL) {
        self.directory = directory
    }

    /// Copy the file at `originalURL` into the attachments directory and
    /// return the attachment pointing at the COPY. Throws if the source
    /// doesn't exist or the copy fails — never fabricates an attachment.
    public func store(originalURL: URL) throws -> ImageAttachment {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = originalURL.pathExtension
        let name = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        let destination = directory.appendingPathComponent(name)
        try FileManager.default.copyItem(at: originalURL, to: destination)
        return ImageAttachment(url: destination)
    }

    /// Write picked bytes (the Photos picker hands data, not a URL) into the
    /// attachments directory and return the attachment. The extension is
    /// reduced to alphanumerics so a hostile or odd value can't leave the
    /// directory; none means no extension. Empty data throws: a zero-byte
    /// image is never an attachment.
    public func store(data: Data, fileExtension: String?) throws -> ImageAttachment {
        guard !data.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = String((fileExtension ?? "").filter { $0.isASCII && ($0.isLetter || $0.isNumber) })
        let name = ext.isEmpty ? UUID().uuidString : "\(UUID().uuidString).\(ext)"
        let destination = directory.appendingPathComponent(name)
        try data.write(to: destination, options: .atomic)
        return ImageAttachment(url: destination)
    }

    /// Delete stored copies. We OWN these files (they are our container-side
    /// copies, never the user's originals), so removal is safe by
    /// construction; a missing file is a quiet no-op (idempotent — a
    /// double-discard or an already-swept orphan must never throw). Called
    /// when a pending attachment is removed before send, and when a
    /// conversation is deleted — the privacy stance says a deleted photo
    /// leaves the container, not just the transcript. (PR #62 round-2 fold.)
    public static func discard(_ attachments: [ImageAttachment]) {
        for attachment in attachments {
            try? FileManager.default.removeItem(at: attachment.url)
        }
    }
}
