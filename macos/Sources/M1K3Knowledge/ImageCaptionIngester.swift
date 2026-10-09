//
//  ImageCaptionIngester.swift
//  M1K3Knowledge
//
//  Caption memory (Stream D, 1.1 slice). When the user taps "Remember this
//  photo" on a chat image, a neutral caption is written (M1K3Chat's
//  ImageCaptionPolicy owns the prompt) and lands here as a `.image` item.
//
//  The item is a REFERENCE, never a copy: `sourceRef` is
//  `attachment:<filename>` -- the FILENAME only, because an absolute container
//  URL does not survive an iOS update. A re-send of the same attachment
//  dedupes on it (DocumentIngester's sourceRef rule) and the conversation
//  delete cascade (`forget`) keys on it.
//
//  Captions are model-written, so they carry `KnowledgeSource.captioned` and
//  ride both launch sweeps (`KnowledgeKind.launchSweepKinds`).
//
//  Signed: Kev + claude-fable-5.1, 2026-10-09, Confidence 0.8, Prior: Unknown

import Foundation

public struct ImageCaptionIngester: Sendable {
    private let store: KnowledgeStore
    private let ingester: DocumentIngester

    public init(store: KnowledgeStore, embedder: (any EmbeddingService)? = nil) {
        self.store = store
        ingester = DocumentIngester(store: store, embedder: embedder)
    }

    public enum CaptionError: Error, Sendable, Equatable {
        /// Nothing usable came back from the captioner.
        case emptyCaption
    }

    /// How many characters of the caption head the row (and a citation).
    public static let titleLimit = 60

    /// `attachment:<filename>` -- takes a bare filename or a full path and keeps
    /// the last component either way.
    public static func sourceRef(forAttachment pathOrFilename: String) -> String {
        "attachment:" + (pathOrFilename as NSString).lastPathComponent
    }

    /// The first `titleLimit` characters of the caption, trimmed.
    public static func title(forCaption caption: String) -> String {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(titleLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    public func ingest(
        caption: String, attachmentFilename: String
    ) async throws -> DocumentIngester.IngestResult {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CaptionError.emptyCaption }
        return try await ingester.ingest(
            title: Self.title(forCaption: trimmed),
            text: trimmed,
            sourceRef: Self.sourceRef(forAttachment: attachmentFilename),
            kind: .image,
            source: .captioned
        )
    }

    /// The delete cascade: remove the Photo item of each attachment. Only
    /// `.image` items are touched (a document that happens to share a ref is
    /// not ours to delete). Returns how many were removed.
    @discardableResult
    public func forget(attachments: [String]) throws -> Int {
        var removed = 0
        for attachment in attachments {
            guard let id = try store.itemID(forSourceRef: Self.sourceRef(forAttachment: attachment)),
                  let item = try store.item(id: id), item.kind == .image else { continue }
            if try store.deleteItem(id: id) { removed += 1 }
        }
        return removed
    }
}
