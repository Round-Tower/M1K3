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
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — failure doubles: `FailingEmbedder` (a plain error
//  or a CancellationError on a marker word) and `CancellingDistiller`; the harness takes an embedder, and `pipeline`
//  can swap it for a retry over the same stores. Confidence 0.85.

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

/// Throws `CancellationError` for every slice: a cancel that lands inside the distiller.
struct CancellingDistiller: MemoryDistilling {
    func distill(turns _: [ChatTurn]) async throws -> [DistilledFact] {
        throw CancellationError()
    }
}

/// The hashing embedder, except that any text containing `marker` throws: a plain error, or a
/// `CancellationError` (a cancel landing inside an embed, mid-write).
struct FailingEmbedder: EmbeddingService {
    struct Failure: Error {}

    let marker: String
    var cancels = false
    private let base = HashingEmbeddingService()

    init(marker: String, cancels: Bool = false) {
        self.marker = marker
        self.cancels = cancels
    }

    var dimension: Int {
        base.dimension
    }

    var fingerprint: String {
        base.fingerprint
    }

    func embed(_ text: String) async throws -> [Float] {
        guard !text.contains(marker) else {
            if cancels { throw CancellationError() }
            throw Failure()
        }
        return try await base.embed(text)
    }

    func isAvailable() async -> Bool {
        true
    }
}

/// `count` words that belong to `index` alone, for facts that must NOT be semantic twins under the
/// hashing embedder. A varying part with a shared suffix (`t12x0` … `t12x5`) is not enough: the
/// embedder's bucket is FNV-1a mod 256, whose low 8 bits only ever read their own low 8 bits, so two
/// indexes that reach the same state after `t12` collide on every token at once (1,200 facts over
/// 256 states superseded each other). Each word here is an independent pseudo-random string.
func distinctWords(_ index: Int, count: Int = 6) -> String {
    func mix(_ value: UInt64) -> UInt64 {
        var mixed = value
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
    // Seeded THROUGH the mixer: a seed of index × step would make index i's stream index i+1's,
    // shifted by one word.
    var state = mix(UInt64(truncatingIfNeeded: index) &+ 0x2545_F491_4F6C_DD1D)
    func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        return mix(state)
    }
    return (0 ..< count).map { _ in
        String((0 ..< 7).map { _ in Character(UnicodeScalar(UInt8(97 + next() % 26))) })
    }.joined(separator: " ")
}

/// 20 shared filler tokens so a one-word swap stays at cosine 0.95 under the hashing embedder.
let filler = "alpha beta gamma delta epsilon zeta eta theta iota kappa "
    + "lambda mu nu xi omicron rho sigma tau upsilon"

struct ImportHarness {
    let knowledge: KnowledgeStore
    let memory: MemoryStore
    let embedder: any EmbeddingService
    let tag: ImportSourceTag

    init(
        tag: ImportSourceTag = ImportSourceTag(provider: .chatgpt, date: utcDate(2026, 10, 26)),
        embedder: any EmbeddingService = HashingEmbeddingService()
    ) throws {
        knowledge = try KnowledgeStore()
        memory = try MemoryStore()
        self.tag = tag
        self.embedder = embedder
    }

    func pipeline(
        _ distiller: any MemoryDistilling, tag: ImportSourceTag? = nil, embedder: (any EmbeddingService)? = nil
    ) -> ConversationImportPipeline {
        ConversationImportPipeline(
            tag: tag ?? self.tag,
            knowledgeStore: knowledge,
            memoryStore: memory,
            embedder: embedder ?? self.embedder,
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
