//
//  DocumentIngester.swift
//  M1K3Knowledge
//
//  Orchestrates the document path: pages → DocumentChunker → (optional embed via
//  EmbeddingService) → KnowledgeStore as a `.document` KnowledgeItem. The single
//  entry point Phase 4 ingest needs, sitting on top of the pure chunker + the
//  store. Embedder is optional: pass one (HashingEmbeddingService now, MLX later)
//  for vector/hybrid search, or omit it for FTS-only ingest with embeddings
//  backfilled afterwards.
//
//  Dedupe: if `sourceRef` is already indexed, ingest is a no-op and returns the
//  existing item id (the prior knowledge-server's sha256-dedupe pattern, generalised).
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.85, Prior: Unknown
//  Review: Kev + claude-opus-5.5, 2026-11-03 — the first App Store review: a scanned PDF indexed as its
//  title alone, then answered "no readable text". `ingestPDF` reads scanned pages with `recognizer`
//  (Vision by default) and reports progress; a file with no text anywhere throws `noReadableText`
//  instead of indexing an empty item; and an earlier EMPTY import of the same sourceRef is replaced, not
//  deduped (otherwise the scan could never be re-read). Confidence 0.8.

import Foundation

public struct DocumentIngester: Sendable {
    private let store: KnowledgeStore
    private let embedder: (any EmbeddingService)?
    private let recognizer: (any PageTextRecognizing)?

    /// `recognizer` reads scanned PDF pages; nil keeps PDFKit's text layer only.
    public init(
        store: KnowledgeStore,
        embedder: (any EmbeddingService)? = nil,
        recognizer: (any PageTextRecognizing)? = VisionPageTextRecognizer()
    ) {
        self.store = store
        self.embedder = embedder
        self.recognizer = recognizer
    }

    public struct IngestResult: Sendable, Equatable {
        public let itemID: UUID
        public let chunkCount: Int
        /// True when a matching `sourceRef` was already indexed (no new work).
        public let wasDeduped: Bool
        /// Scanned PDF pages read from their images, and any past the cap.
        public var scans: PDFTextExtractor.ScanReport = .none
    }

    /// Ingest extracted pages as a knowledge item. Returns the item id and
    /// chunk count. `kind`/`source` default to the classic document shape;
    /// the memory write path passes `.memory` + who wrote it (kind is
    /// provenance, not size — short facts chunk to a single chunk naturally).
    @discardableResult
    public func ingest(
        title: String,
        pages: [DocumentPage],
        sourceRef: String? = nil,
        kind: KnowledgeKind = .document,
        source: KnowledgeSource? = nil
    ) async throws -> IngestResult {
        if let sourceRef, let existing = try indexedWithText(sourceRef: sourceRef) {
            return existing
        }

        let documentChunks = DocumentChunker.chunk(pages: pages)
        let itemID = UUID()
        let item = KnowledgeItem(
            id: itemID, kind: kind, title: title, sourceRef: sourceRef, source: source
        )
        let knowledgeChunks = documentChunks.map { chunk in
            KnowledgeChunk(
                itemID: itemID,
                ordinal: chunk.chunkIndex,
                heading: chunk.heading,
                content: chunk.content
            )
        }

        let embeddings: [[Float]]?
        if let embedder, !knowledgeChunks.isEmpty {
            // B5 layer 3: chunks embed WITH their document title (EmbeddingText)
            // so title-carried context reaches the vector. Reindex composes
            // identically — one composition point, both write paths.
            embeddings = try await embedder.embedBatch(
                knowledgeChunks.map { EmbeddingText.forChunk(title: title, content: $0.content) }
            )
        } else {
            embeddings = nil
        }

        try store.index(item: item, chunks: knowledgeChunks, embeddings: embeddings)
        return IngestResult(itemID: itemID, chunkCount: knowledgeChunks.count, wasDeduped: false)
    }

    /// The earlier import of `sourceRef` as a dedupe result, when it holds text. An earlier import that
    /// indexed nothing (a scan before scans were read) is deleted so the file is read again.
    private func indexedWithText(sourceRef: String) throws -> IngestResult? {
        guard let existing = try store.itemID(forSourceRef: sourceRef) else { return nil }
        let existingCount = try store.chunks(forItem: existing).count
        guard existingCount > 0 else {
            _ = try store.deleteItem(id: existing)
            return nil
        }
        return IngestResult(itemID: existing, chunkCount: existingCount, wasDeduped: true)
    }

    public enum IngestError: Error, Sendable, Equatable, LocalizedError {
        /// The payload is markup (SVG/XML/HTML), not prose — indexing it
        /// pollutes FTS with tag noise (the "Artboard" finding).
        case markupNotProse
        /// No text anywhere, even after reading scanned pages: nothing is indexed.
        case noReadableText

        public var errorDescription: String? {
            switch self {
            case .markupNotProse:
                "This looks like raw markup (SVG/XML/HTML), not readable text — convert it to prose or PDF first."
            case .noReadableText:
                "M1K3 couldn’t find any text in it. "
                    + "If it’s a scan or a photo, the writing may be handwritten or too faint to read."
            }
        }
    }

    private static func hasText(_ text: String) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Ingest a single block of raw text as a one-page item.
    @discardableResult
    public func ingest(
        title: String,
        text: String,
        sourceRef: String? = nil,
        kind: KnowledgeKind = .document,
        source: KnowledgeSource? = nil
    ) async throws -> IngestResult {
        guard Self.hasText(text) else { throw IngestError.noReadableText }
        guard !MarkupGuard.looksLikeMarkup(text) else { throw IngestError.markupNotProse }
        return try await ingest(
            title: title,
            pages: [DocumentPage(pageNumber: 1, text: text)],
            sourceRef: sourceRef,
            kind: kind,
            source: source
        )
    }

    /// Ingest PDF bytes: extract pages (reading scanned ones), then chunk + embed + store. `progress`
    /// fires before each scanned page is read, so a long scan can say where it is.
    @discardableResult
    public func ingestPDF(
        title: String,
        data: Data,
        sourceRef: String? = nil,
        progress: (@Sendable (PDFTextExtractor.ScanProgress) -> Void)? = nil
    ) async throws -> IngestResult {
        // Dedupe before reading: a scan already indexed with text needs no second Vision pass.
        if let sourceRef, let existing = try indexedWithText(sourceRef: sourceRef) {
            return existing
        }
        let extracted = try await PDFTextExtractor.extract(data: data, recognizer: recognizer, progress: progress)
        guard extracted.pages.contains(where: { Self.hasText($0.text) }) else { throw IngestError.noReadableText }
        var result = try await ingest(title: title, pages: extracted.pages, sourceRef: sourceRef)
        result.scans = extracted.scans
        return result
    }
}
