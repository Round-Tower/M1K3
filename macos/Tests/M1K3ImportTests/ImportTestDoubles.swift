//
//  ImportTestDoubles.swift
//  M1K3ImportTests
//
//  Distiller doubles and an in-memory harness for the #711 pipeline tests: both stores in memory,
//  the hashing embedder (whose cosines are engineerable: k shared tokens of n gives k/n), and the
//  same coordinator wiring the app's live distillation uses, for seeding "what was already known".
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85.
//  Prior: none (new file).

import Foundation
import M1K3Chat
import M1K3Import
import M1K3Knowledge
import M1K3Memory
import M1K3MemoryChatBridge

/// Returns the same facts for every slice.
struct ScriptedDistiller: MemoryDistilling {
    let facts: [DistilledFact]

    init(_ texts: [String]) {
        facts = texts.map { DistilledFact(text: $0) }
    }

    func distill(turns _: [ChatTurn]) async throws -> [DistilledFact] {
        facts
    }
}

/// Records every slice it is handed.
actor SpyDistiller: MemoryDistilling {
    private(set) var calls: [[ChatTurn]] = []
    let facts: [DistilledFact]

    init(_ texts: [String] = []) {
        facts = texts.map { DistilledFact(text: $0) }
    }

    func distill(turns: [ChatTurn]) async throws -> [DistilledFact] {
        calls.append(turns)
        return facts
    }
}

/// Throws on any slice whose user text contains "boom"; otherwise echoes each user turn as a fact.
struct FlakyDistiller: MemoryDistilling {
    struct Boom: Error {}

    func distill(turns: [ChatTurn]) async throws -> [DistilledFact] {
        let said = turns.filter { $0.role == .user }.map(\.text)
        if said.contains(where: { $0.contains("boom") }) { throw Boom() }
        return said.map { DistilledFact(text: $0) }
    }
}

/// 20 shared filler tokens so a one-word swap stays at cosine 0.95 under the hashing embedder.
let filler = "alpha beta gamma delta epsilon zeta eta theta iota kappa "
    + "lambda mu nu xi omicron rho sigma tau upsilon"

struct ImportHarness {
    let knowledge: KnowledgeStore
    let memory: MemoryStore
    let embedder = HashingEmbeddingService()
    let tag: ImportSourceTag

    init(tag: ImportSourceTag = ImportSourceTag(provider: .chatgpt, date: utcDate(2026, 10, 26))) throws {
        knowledge = try KnowledgeStore()
        memory = try MemoryStore()
        self.tag = tag
    }

    func pipeline(_ distiller: any MemoryDistilling, tag: ImportSourceTag? = nil) -> ConversationImportPipeline {
        ConversationImportPipeline(
            tag: tag ?? self.tag,
            knowledgeStore: knowledge,
            memoryStore: memory,
            embedder: embedder,
            distiller: distiller,
            selfNames: .none
        )
    }

    /// What the app's live distillation would have written before the import: `.distilled` rows in
    /// both stores, through the same coordinator + bridge adapter.
    func seedLive(_ fact: String, said: String) async throws {
        let coordinator = MemoryDistillationCoordinator(
            distiller: ScriptedDistiller([fact]),
            ingester: DocumentIngester(store: knowledge, embedder: embedder),
            store: knowledge,
            embedder: embedder,
            graph: DistilledFactGraphAdapter(store: memory),
            selfNames: .none
        )
        try await coordinator.distillAndStore(turns: [ChatTurn(role: .user, text: said)])
    }

    func corpusItem(titled prefix: String) throws -> KnowledgeItem? {
        try (knowledge.allItems(kind: .memory, limit: 1000) + knowledge.allItems(kind: .memorySuperseded, limit: 1000))
            .first { $0.title.hasPrefix(prefix) }
    }

    /// The corpus row for one fact's exact text (its normalized-text sourceRef), any kind.
    func corpusItem(forFact text: String) throws -> KnowledgeItem? {
        try knowledge.itemID(forSourceRef: MemoryDistillationCoordinator.factSourceRef(text))
            .flatMap { try knowledge.item(id: $0) }
    }

    func graphRow(_ text: String) throws -> Memory? {
        try memory.allMemories(includeSuperseded: true, limit: 1000).first { $0.text == text }
    }
}

/// One conversation from (role, text) pairs, dated so commit order is deterministic.
func conversation(_ id: String, at seconds: Double = 1_760_000_000, _ messages: [(ImportedRole, String)]) -> ImportedConversation {
    ImportedConversation(
        id: id, title: "Conversation \(id)", createdAt: Date(timeIntervalSince1970: seconds),
        messages: messages.map { ImportedMessage(role: $0.0, text: $0.1) }
    )
}

/// Thread-safe progress + footprint recorder for the `@Sendable` progress callback.
final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ImportProgress] = []

    func record(_ progress: ImportProgress) {
        lock.withLock { events.append(progress) }
    }

    func all() -> [ImportProgress] {
        lock.withLock { events }
    }
}
