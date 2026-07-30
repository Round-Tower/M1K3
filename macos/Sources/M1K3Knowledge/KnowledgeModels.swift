//
//  KnowledgeModels.swift
//  M1K3Knowledge
//
//  Domain-neutral knowledge model. A KnowledgeItem is anything M1K3 remembers —
//  a document, a logged call, a note — and owns ordered KnowledgeChunks that are
//  embedded and searched. Documents (Phase 4) and calls (Phase 7) both land here
//  so a single hybrid search spans everything the assistant knows.
//
//  Generalised from the prior knowledge-server's IndexedDocument/IndexedDocumentChunk (which were
//  domain-record/PDF-specific). GRDB record types; persistence lives in KnowledgeStore.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-06, Confidence 0.8, Prior: Unknown

import Foundation
import GRDB

/// What a knowledge item represents. Open-ended string-backed enum so new
/// sources (email, calendar, transcript) don't require a schema change.
public struct KnowledgeKind: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let document = KnowledgeKind(rawValue: "document")
    public static let call = KnowledgeKind(rawValue: "call")
    public static let note = KnowledgeKind(rawValue: "note")
    public static let memory = KnowledgeKind(rawValue: "memory")
    /// Index segregation (prompt-hardening v2): stored and embedded like any
    /// item, but invisible to every retrieval surface — search, grounding,
    /// listing — unless a caller names the kind explicitly. The home for
    /// internal QA/diagnostic/operational notes and for canary honeypot docs
    /// (see CanaryGuard): the prompt cannot stop retrieval surfacing a doc
    /// that is IN the index; only exclusion can.
    public static let quarantined = KnowledgeKind(rawValue: "quarantined")
}

/// Who wrote a knowledge item — the provenance half of the memory consent
/// story (Settings shows "you told me" vs "I noticed"). Open string-backed
/// like KnowledgeKind so new writers don't require a schema change.
public struct KnowledgeSource: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The user wrote it explicitly (the `remember` tool, manual entry).
    public static let user = KnowledgeSource(rawValue: "user")
    /// The background distillation loop extracted it from a conversation.
    public static let distilled = KnowledgeSource(rawValue: "distilled")
}

/// A unit of knowledge the assistant can retrieve over.
public struct KnowledgeItem: Identifiable, Equatable, Sendable, Codable {
    public var id: UUID
    public var kind: KnowledgeKind
    public var title: String
    /// Optional stable external identity (file sha256, call UUID, URL) used for
    /// dedupe. Two ingests of the same source collapse on this.
    public var sourceRef: String?
    /// Who wrote it (nil for legacy items and ordinary document ingests).
    public var source: KnowledgeSource?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        kind: KnowledgeKind,
        title: String,
        sourceRef: String? = nil,
        source: KnowledgeSource? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.sourceRef = sourceRef
        self.source = source
        self.createdAt = createdAt
    }
}

/// An ordered, embeddable slice of a KnowledgeItem's content.
public struct KnowledgeChunk: Identifiable, Equatable, Sendable, Codable {
    public var id: UUID
    public var itemID: UUID
    public var ordinal: Int
    public var heading: String?
    public var content: String

    public init(
        id: UUID = UUID(),
        itemID: UUID,
        ordinal: Int,
        heading: String? = nil,
        content: String
    ) {
        self.id = id
        self.itemID = itemID
        self.ordinal = ordinal
        self.heading = heading
        self.content = content
    }
}

/// A search result: a chunk plus where it came from and how it scored.
/// `similarity` is set on vector hits; `rrfScore` on fused hybrid hits.
public struct ChunkHit: Identifiable, Equatable, Sendable, Codable {
    public var id: UUID {
        chunkID
    }

    public var chunkID: UUID
    public var itemID: UUID
    public var itemTitle: String
    public var kind: KnowledgeKind
    public var heading: String?
    public var content: String
    public var similarity: Float?
    public var rrfScore: Double?
    /// When the parent item was learned (its `created_at`). Optional for
    /// payload compatibility — hits decoded from pre-Tier-1 archives carry
    /// nil and downstream renderers fall back to the undated line
    /// (scratch/dream-cycle/SPEC.md Tier 1).
    public var createdAt: Date?

    public init(
        chunkID: UUID,
        itemID: UUID,
        itemTitle: String,
        kind: KnowledgeKind,
        heading: String?,
        content: String,
        similarity: Float? = nil,
        rrfScore: Double? = nil,
        createdAt: Date? = nil
    ) {
        self.chunkID = chunkID
        self.itemID = itemID
        self.itemTitle = itemTitle
        self.kind = kind
        self.heading = heading
        self.content = content
        self.similarity = similarity
        self.rrfScore = rrfScore
        self.createdAt = createdAt
    }
}

// MARK: - GRDB persistence records

/// Row shape for `knowledge_items`. CodingKeys map camelCase properties to the
/// snake_case columns GRDB reads/writes.
struct ItemRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "knowledge_items"
    var id: String
    var kind: String
    var title: String
    var sourceRef: String?
    var source: String?
    var createdAt: Double

    enum CodingKeys: String, CodingKey {
        case id, kind, title, source
        case sourceRef = "source_ref"
        case createdAt = "created_at"
    }

    init(_ item: KnowledgeItem) {
        id = item.id.uuidString
        kind = item.kind.rawValue
        title = item.title
        sourceRef = item.sourceRef
        source = item.source?.rawValue
        createdAt = item.createdAt.timeIntervalSince1970
    }
}

/// Row shape for `knowledge_chunks`.
struct ChunkRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "knowledge_chunks"
    var id: String
    var itemID: String
    var ordinal: Int
    var heading: String?
    var content: String

    enum CodingKeys: String, CodingKey {
        case id, ordinal, heading, content
        case itemID = "item_id"
    }

    init(_ chunk: KnowledgeChunk) {
        id = chunk.id.uuidString
        itemID = chunk.itemID.uuidString
        ordinal = chunk.ordinal
        heading = chunk.heading
        content = chunk.content
    }
}
