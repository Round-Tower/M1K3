//
//  MemoryDistillationCoordinator.swift
//  M1K3Chat
//
//  Distilled facts → memory items, deduped twice on the way in:
//  1. EXACT — sourceRef = sha256 of the normalized fact; DocumentIngester
//     already no-ops on an existing sourceRef, so the same fact re-distilled
//     across sessions collapses to one row for free, forever.
//  2. SEMANTIC — embed the fact, vector-search stored memories. Since the
//     Tier-2 write-time repair (2026-07-30) a ≥ 0.90 twin is SUPERSEDED
//     rather than the new fact discarded: the MEMSTAT census proved the old
//     skip silently ate 3/10 corrections (the Dublin→Ardmore class), and a
//     restatement superseding its twin is only a harmless refresh. The live
//     set stays deduplicated either way — exactly one row per fact survives
//     in retrieval.
//
//  Signed: Kev + claude-fable-5, 2026-06-12, Confidence 0.85 (mechanism
//  test-pinned; the 0.90 dedupe bar is an empirical starting point —
//  refine from MEMEVAL self-similarity stats if it over/under-merges).
//  Prior: Unknown
//  Review: Kev + claude-fable-5, 2026-07-30 — Tier-2 write-time repair:
//  supersede-at-the-bar, un-supersede-on-reassert, corpus-twin re-kind with
//  the M2 divergence audit (scratch/dream-cycle/SPEC.md §2, evidence in
//  MEMSTAT-RESULTS.md).
//  Review: Kev + claude-fable-5.1, 2026-09-11, Confidence 0.85 — #284: distillAndStore now
//  applies the DistillationAttribution fence AFTER the parser's own validator + durability
//  filters — a trivial user turn skips the slice before the distiller is even called, and any
//  surviving fact unanchored in the user's own turns is dropped fail-closed (one `.info` line
//  per slice counts the drops).
//  Review: Kev + claude-fable-5.1, 2026-10-10 — the dedupe bar is `EmbedderFloors.dedupe` for the
//  embedder in use (0.90 stays for Qwen and hashing; EmbeddingGemma 2 carries its own), via
//  `semanticDedupeThreshold(for:)`.
//  Review: Kev + claude-fable-5.1, 2026-09-11 (review 10 fold on #288) — `selfNames` is injected
//  like every other collaborator (default: the account's names); tests pass `.none` and stop
//  depending on the machine's user name.
//  Review: Kev + claude-opus-5.5, 2026-10-27 — #711 (memory import): `distillAndStore` is now `store(propose(turns:))`,
//  byte-identical in behaviour, so an import can show the fenced proposals for review before anything is written and
//  then write the accepted ones through the SAME exact + semantic dedupe/supersede path (bar unchanged:
//  `semanticDedupeThreshold(for:)`). `corpusSource` (default `.distilled`) tags the rows; `forgetCorpus(source:in:)`
//  deletes one source's memory rows and restores every twin its ledger says they superseded. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold on #711) — `revivesSupersededFacts` (default
//  true, so live distillation is unchanged): an import passes false, because an old chat exactly restating a fact the
//  user has since corrected is history, not a repair, and its revive left no tag for Forget to undo (the graph and
//  corpus then disagreed). `forgetCorpus` deletes in one transaction (`deleteItems(ids:)` + `deleteMeta(keys:)`).
//  Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-27 — #699 Phase 1: a `.style` fact must ALSO pass StyleAskFence
//  (one user turn that anchors it reads as a request), because a stored style rides every system prompt;
//  the drops get their own `.info` count. `didWrite` (the `auditSink` closure shape) fires once with the
//  count when a slice wrote anything, so the app re-reads the style rows into the persona. Confidence 0.85.
//  Review: same day — `title(for:)` and `supersededLinkKey(_:)` are public, so the Memories editor's supersede
//  titles the new row and records the revive ledger exactly as `supersede` does. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — the corpus half of a Memories edit moved
//  here from the app as `applyEdit` (it re-implemented this file's supersede without its order, revive or audit):
//  the new wording is ingested FIRST, a same-identity edit moves nothing, an edit back to a retired wording
//  restores it, and a failure is logged and audited by ids. `title(for:)` and `supersededLinkKey(_:)` are
//  internal again. `didWrite` fires from a `defer`, so a slice that wrote facts and then threw still re-reads the
//  style. An asked-for style fact whose exact text is already live under another kind (a pre-#699 preference
//  row) re-files that graph node through the seam's `refileDistilledFact` instead of vanishing as a duplicate.
//  The edit, and the twin transition and ledger it shares with this file, live in MemoryCorpusEdit.swift;
//  the two fences are one `fenceDrop` helper. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-27 (merge of master's #711 into #699) — the #699 style fence joins
//  #284's in `propose`, so an import's review is fenced too; `didWrite` fires from `store`, the one write path
//  (a `defer` there, so the throw path still re-reads); `reassert` honours `revivesSupersededFacts` before the
//  style re-file, and `forgetCorpus` reads the ledger key that moved to MemoryCorpusEdit.swift. Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-10-27 — #699 contradiction fix (MEMSTAT: 7 of 8 style corrections under the
//  0.95 twin bar left both rows live): with no twin, a `.style` fact from the live writer retires the newest live
//  style row it covers on its axes (StyleAxis, StyleAxisSupersede.swift) through the same `supersede`, which now
//  takes a corpus id + graph text instead of a ChunkHit. The bar is untouched. `supersedesStyleByAxis` (default
//  true) gates it; the seam gains `liveStyleTexts()` (default []), since the corpus has no kind. Confidence 0.85.
//  Review: same day — `distillAndStore` stores a slice's style facts in the order the user said them
//  (`StyleAxis.inSaidOrder`), so "short… later, actually long" in one exit-path slice ends with long live.

import CryptoKit
import Foundation
import M1K3Agent
import M1K3Inference
import M1K3Knowledge
import os

/// The temporal memory GRAPH write seam, kept as a protocol so M1K3Chat stays
/// free of a hard M1K3Memory dependency (the app wires the concrete MemoryStore
/// adapter). This is THE fix for the divergent stores: distilled facts now reach
/// the graph through the same coordinator that writes the corpus, instead of the
/// corpus-only path that left the graph empty and `related_memory` edgeless.
public protocol DistilledFactGraphWriting: Sendable {
    /// Persist a newly distilled fact as a node in the memory graph, carrying
    /// the distiller's classification (the bridge maps it onto MemoryKind).
    /// Best-effort: the corpus write is the source of truth, so a graph-write
    /// failure must never fail distillation.
    ///
    /// Tier 2 (dream-cycle): `superseding` carries the FACT TEXT of the live
    /// node this write corrects — the seam stays string-typed (text is the
    /// join key the dual-write already shares across stores), so M1K3Chat
    /// never learns graph UUIDs. Nil = a plain insert.
    func writeDistilledFact(
        _ text: String, kind: DistilledFactKind, embedding: [Float], superseding oldFactText: String?
    ) async throws

    /// Un-supersede-on-reassert (Tier 2, spec finding #8): the user re-stated
    /// a fact whose graph node is superseded. Writes a fresh node with `text`
    /// that supersedes the chain's LIVE head, and returns that supplanted
    /// head's text so the caller can re-kind its corpus twin out of
    /// retrieval. Nil when no superseded chain matched (degraded to a plain
    /// write).
    func reviveFact(_ text: String, kind: DistilledFactKind, embedding: [Float]) async throws -> String?

    /// #699: the fact's text (normalised) is already a live node of another kind, as a pre-#699
    /// store filed "The user prefers short answers." under `preference`. Re-file it as `kind`,
    /// superseding that node (lineage kept). False when none matched or it already is `kind`.
    func refileDistilledFact(_ text: String, as kind: DistilledFactKind, embedding: [Float]) async throws -> Bool

    /// #699: every live `.style` fact's text, newest first, the rows a new style ask may retire on its
    /// axis (`StyleAxis`). The corpus carries no kind, so the graph is the only place that knows.
    func liveStyleTexts() async throws -> [String]
}

public extension DistilledFactGraphWriting {
    /// Pre-Tier-2 convenience — a plain insert.
    func writeDistilledFact(_ text: String, kind: DistilledFactKind, embedding: [Float]) async throws {
        try await writeDistilledFact(text, kind: kind, embedding: embedding, superseding: nil)
    }

    /// A graph that cannot re-file re-files nothing.
    func refileDistilledFact(_: String, as _: DistilledFactKind, embedding _: [Float]) async throws -> Bool {
        false
    }

    /// A graph that files no style holds none.
    func liveStyleTexts() async throws -> [String] {
        []
    }
}

public struct MemoryDistillationCoordinator: Sendable {
    static let log = Logger(subsystem: M1K3Log.subsystem, category: "memory-distill")
    /// Cosine above which a stored memory counts as "already known" — the
    /// embedder's own bar (`EmbedderFloors.dedupe`): 0.90 was measured on
    /// Qwen3-Embedding (compatibles max 0.768); EmbeddingGemma 2's cone sits
    /// higher. MEMSTAT reports against this same lookup, never a copy.
    public static func semanticDedupeThreshold(for embedder: any EmbeddingService) -> Float {
        EmbedderFloors.forFingerprint(embedder.fingerprint).dedupe
    }

    static let maxTitleLength = 60

    private let distiller: any MemoryDistilling
    private let ingester: DocumentIngester
    let store: KnowledgeStore
    private let embedder: any EmbeddingService
    /// Optional: nil keeps the legacy corpus-only behaviour (tests, any caller
    /// that hasn't wired the graph yet).
    let graph: (any DistilledFactGraphWriting)?
    /// The corpus-twin kind transition (Tier 2). Injectable so the
    /// divergence-audit path (a re-kind failing AFTER the graph committed —
    /// spec fixture #9) is testable; nil uses `store.setKind` directly.
    private let rekind: (@Sendable (UUID, KnowledgeKind) throws -> Bool)?
    /// Receives one line per corpus/graph divergence (IDs + kinds only,
    /// never fact text) — the M2 typed-audit hook. The same line always
    /// goes to the security-relevant `.error` log regardless.
    private let auditSink: (@Sendable (String) -> Void)?
    /// Fired once, off the main actor, when a `store` (so a `distillAndStore`) wrote at least one fact, with
    /// the count (#699), including when a later fact threw after earlier ones landed: the
    /// app's hook to re-read the style rows into the persona. Any write may change them (a
    /// cross-kind supersede included), and a re-read that finds the same rows leaves the
    /// system prompt, and so the prefix cache, as it was.
    private let didWrite: (@Sendable (Int) -> Void)?
    /// The user's own names for the attribution fence — the account's in the
    /// app, `.none` in tests, so a suite never depends on who runs it
    /// (review 10 on #288: a tester surnamed Corkery would have lost "cork").
    private let selfNames: DistillationAttribution.UserNames
    /// Who every corpus row this coordinator writes says wrote it: `.distilled` for live
    /// distillation, an import's `import/<provider>/<date>` tag for #711, so one action can find
    /// (and forget) exactly what that import added.
    private let corpusSource: KnowledgeSource
    /// Whether an exact re-assertion of a superseded fact revives it (spec finding #8). Live
    /// chat: yes, the user repeating a fact they had corrected IS the repair. A memory import
    /// (#711): no — an old conversation is history, and reviving from it would undo a newer
    /// correction without a tag "forget this import" could find.
    private let revivesSupersededFacts: Bool
    /// #699: whether a new `.style` fact retires the newest live style it covers on its axis
    /// (`StyleAxis`). Live chat: yes, the user correcting how they want answers. A memory import:
    /// no — an old conversation's ask is history, and it files as a preference anyway.
    let supersedesStyleByAxis: Bool

    public init(
        distiller: any MemoryDistilling,
        ingester: DocumentIngester,
        store: KnowledgeStore,
        embedder: any EmbeddingService,
        graph: (any DistilledFactGraphWriting)? = nil,
        rekind: (@Sendable (UUID, KnowledgeKind) throws -> Bool)? = nil,
        auditSink: (@Sendable (String) -> Void)? = nil,
        didWrite: (@Sendable (Int) -> Void)? = nil,
        corpusSource: KnowledgeSource = .distilled,
        revivesSupersededFacts: Bool = true,
        supersedesStyleByAxis: Bool = true,
        selfNames: DistillationAttribution.UserNames = DistillationAttribution.systemUserNames
    ) {
        self.distiller = distiller
        self.ingester = ingester
        self.store = store
        self.embedder = embedder
        self.graph = graph
        self.rekind = rekind
        self.auditSink = auditSink
        self.didWrite = didWrite
        self.selfNames = selfNames
        self.corpusSource = corpusSource
        self.revivesSupersededFacts = revivesSupersededFacts
        self.supersedesStyleByAxis = supersedesStyleByAxis
    }

    /// Distill the slice and store what's new. Returns the number of facts
    /// actually written (dedupe skips don't count). Rethrows distiller
    /// failure so the caller withholds the watermark and retries the slice.
    /// `store(propose(turns:))`, with the slice's style facts in the order the
    /// user said them (`StyleAxis.inSaidOrder`, #699): the later write is the
    /// newer ask, and a whole chat can arrive as one slice.
    @discardableResult
    public func distillAndStore(turns: [ChatTurn]) async throws -> Int {
        let facts = try await propose(turns: turns)
        let userTurns = turns.filter { $0.role == .user }.map(\.text)
        return try await store(StyleAxis.inSaidOrder(facts, userTurns: userTurns, selfNames: selfNames))
    }

    /// Distill the slice and return the facts that survive the fence, writing
    /// NOTHING — the review half of a memory import (#711), where the user
    /// ticks what to keep before `store` runs. Rethrows distiller failure.
    ///
    /// #284 attribution fence, applied AFTER MemoryFactParser's own validator +
    /// durability filters: a trivial user turn (a bare greeting) never even
    /// reaches the distiller — nothing the user said could anchor anything —
    /// and any surviving fact that shares no real content with something the
    /// user actually said is dropped fail-closed.
    ///
    /// #699: a `.style` fact also needs an explicit ask (`StyleAskFence`): it
    /// renders into every system prompt, so it must come from a request the
    /// user made, never from how they behave.
    public func propose(turns: [ChatTurn]) async throws -> [DistilledFact] {
        guard !DistillationAttribution.userContributionIsTrivial(turns: turns) else {
            Self.log.info("distillation skipped: user contribution trivial (\(turns.count) turn(s))")
            return []
        }
        let facts = try await distiller.distill(turns: turns)
        guard !facts.isEmpty else {
            Self.log.info("distilled 0 facts from \(turns.count) turn(s)")
            return []
        }
        let userTurns = turns.filter { $0.role == .user }.map(\.text)
        var dropped: [FenceDrop: Int] = [:]
        var fenced: [DistilledFact] = []
        for fact in facts {
            if let drop = fenceDrop(fact, userTurns: userTurns) {
                dropped[drop, default: 0] += 1
            } else {
                fenced.append(fact)
            }
        }
        if let count = dropped[.unanchored] {
            Self.log.info("distillation dropped \(count) unanchored fact(s)")
        }
        if let count = dropped[.unasked] {
            Self.log.info("distillation dropped \(count) style fact(s) the user never asked for")
        }
        return fenced
    }

    /// Write `facts` through the one memory write path: exact dedupe on the
    /// normalized-text sourceRef, semantic supersede at the embedder's own bar,
    /// revive on an exact re-assertion of a superseded fact, and the graph
    /// dual-write. Returns the number of facts written (dedupe skips don't
    /// count). The caller owns attribution: pass `propose`'s output, or facts
    /// the user stated outright (an OKF import from another M1K3).
    @discardableResult
    public func store(_ facts: [DistilledFact]) async throws -> Int {
        guard !facts.isEmpty else { return 0 }
        var written = 0
        // Fires on the throw path too: facts written before a later one threw are in the stores.
        defer { if written > 0 { didWrite?(written) } }
        for fact in facts {
            // Embed ONCE: the same vector finds the semantic twin AND seeds
            // the graph node, so the repair costs no extra embed.
            let vector = await embed(fact.text)
            // Tier 2 (dream-cycle): a ≥ bar twin is SUPERSEDED, never eaten.
            // MEMSTAT (2026-07-30) measured 3/10 corrections silently
            // discarded by the old `continue`, and no cosine bar separates
            // correction from restatement — while a misclassified restatement
            // supersede is only a harmless refresh. Compatibles never reach
            // the bar (measured max 0.768), so false supersedes stay
            // structurally impossible at this threshold.
            let twin = try vector.flatMap { try semanticTwin($0) }

            let result = try await ingester.ingest(
                title: Self.title(for: fact.text),
                text: fact.text,
                sourceRef: Self.factSourceRef(fact.text),
                kind: .memory,
                source: corpusSource
            )
            if result.wasDeduped {
                if try await reassert(fact, itemID: result.itemID, vector: vector) { written += 1 }
                continue
            }
            written += 1
            if let twin {
                await supersede(
                    corpusItemID: twin.itemID, graphText: twin.content, with: fact, newItemID: result.itemID,
                    vector: vector, reason: .twin
                )
            } else if let victim = await styleAxisVictim(for: fact, vector: vector) {
                // #699: a style correction under the twin bar retires the ask it corrects (StyleAxis).
                await supersede(
                    corpusItemID: victim.corpusItemID, graphText: victim.text, with: fact, newItemID: result.itemID,
                    vector: vector, reason: .styleAxis
                )
            } else {
                Self.log.info("remembered: \(LogPreview.preview(fact.text, max: 80), privacy: .public)")
                await dualWriteToGraph(fact, vector: vector)
            }
        }
        Self.log.info("distillation wrote \(written)/\(facts.count) fact(s)")
        return written
    }

    /// Why a fence dropped a fact.
    private enum FenceDrop { case unanchored, unasked }

    /// #284's anchor rule, then (#699) the explicit-ask rule a style fact also needs: it
    /// renders into every system prompt. Nil when the fact passes.
    private func fenceDrop(_ fact: DistilledFact, userTurns: [String]) -> FenceDrop? {
        guard DistillationAttribution.isAnchored(fact: fact.text, userTurns: userTurns, selfNames: selfNames) else {
            return .unanchored
        }
        guard fact.kind == .style else { return nil }
        let asked = StyleAskFence.isExplicitAsk(fact: fact.text, userTurns: userTurns, selfNames: selfNames)
        return asked ? nil : .unasked
    }

    /// Exact re-assertion. A superseded row is the user's REPAIR: revive it (spec finding #8),
    /// unless this writer never revives (an import, #711). An asked-for style fact re-files a
    /// live row of another kind (#699). Anything else is a true duplicate. True when it wrote.
    private func reassert(_ fact: DistilledFact, itemID: UUID, vector: [Float]?) async throws -> Bool {
        if try store.item(id: itemID)?.kind == .memorySuperseded {
            guard revivesSupersededFacts else {
                Self.log.debug("skip (exact dup of a superseded fact; this writer never revives)")
                return false
            }
            try await revive(fact, itemID: itemID, vector: vector)
            return true
        }
        if fact.kind == .style, await refileAsStyle(fact, vector: vector) { return true }
        Self.log.debug("skip (exact dup): \(LogPreview.preview(fact.text, max: 60), privacy: .public)")
        return false
    }

    /// #699: the corpus twin is text-keyed, so it already answers; the graph node is re-filed
    /// as style so the persona reads it. Best-effort: a failure leaves the row as it was.
    private func refileAsStyle(_ fact: DistilledFact, vector: [Float]?) async -> Bool {
        guard let graph, let vector else { return false }
        do {
            let refiled = try await graph.refileDistilledFact(fact.text, as: fact.kind, embedding: vector)
            if refiled { Self.log.notice("memory re-filed: 1 live fact is now a stated style") }
            return refiled
        } catch {
            Self.log.notice("graph re-file failed (the row stands): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    // MARK: - Forgetting one source (#711)

    /// Forget every corpus MEMORY row `source` wrote (an import's
    /// `import/<provider>/<date>` tag) and put back what those rows corrected:
    /// each `.memorySuperseded` twin whose ledger entry names a forgotten row
    /// returns to `.memory` and loses the entry — the corpus mirror of
    /// `MemoryStore.forget(id:)` un-superseding in the graph. Restores run
    /// BEFORE the deletes because the ledger names the corrector by id. Other
    /// kinds carrying the tag (an import's `.conversation` items) are the
    /// caller's to delete. The rows and their ledger entries go in one
    /// transaction each. Returns the number of rows removed.
    @discardableResult
    public static func forgetCorpus(source: KnowledgeSource, in store: KnowledgeStore) throws -> Int {
        let doomed = try Set(store.itemIDs(source: source, kinds: [.memory, .memorySuperseded]))
        guard !doomed.isEmpty else { return 0 }
        let restored = try restoreTwins(correctedBy: doomed, in: store)
        let removed = try store.deleteItems(ids: Array(doomed))
        try store.deleteMeta(keys: doomed.map(supersededLinkKey))
        log.notice("corpus source forgotten: \(removed) memory row(s) removed, \(restored) restored")
        return removed
    }

    // MARK: - Tier 2: write-time repair

    /// Why a write supersedes a live row.
    enum SupersedeReason {
        /// A semantic twin at the embedder's dedupe bar (Tier 2).
        case twin
        /// #699: a style ask on the same axis (`StyleAxis`), under the bar.
        case styleAxis
    }

    /// The new fact corrects (or restates) the live row whose graph node carries
    /// `graphText` and whose corpus twin is `corpusItemID` (nil: no live twin to move):
    /// graph gets a supersede write joined by fact text, then the twin's corpus row
    /// leaves retrieval via the `.memorySuperseded` re-kind. Order is deliberate — graph
    /// commit FIRST, corpus transition second — so a failure between the two
    /// lands in the audited divergence path (spec fixture #9), never as a
    /// live corpus row whose graph node is secretly superseded going
    /// unnoticed.
    private func supersede(
        corpusItemID: UUID?, graphText: String, with fact: DistilledFact, newItemID: UUID, vector: [Float]?,
        reason: SupersedeReason
    ) async {
        if let graph, let vector {
            do {
                try await graph.writeDistilledFact(
                    fact.text, kind: fact.kind, embedding: vector, superseding: graphText
                )
            } catch {
                Self.log.notice("graph supersede failed (corpus write stands): \(error.localizedDescription, privacy: .public)")
            }
        }
        if let corpusItemID {
            transitionCorpusTwin(itemID: corpusItemID, context: "supersede")
            recordSupersededLink(from: corpusItemID, to: newItemID)
        }
        switch reason {
        case .twin: Self.log.notice("memory superseded: 1 fact corrected at write time")
        case .styleAxis: Self.log.notice("style superseded: 1 stated style replaced on its axis")
        }
    }

    // MARK: - The corpus supersede ledger (its key and write: MemoryCorpusEdit.swift, shared with the edit)

    private func recordSupersededLink(from oldItemID: UUID, to newItemID: UUID) {
        Self.recordSupersededLink(from: oldItemID, to: newItemID, store: store)
    }

    private func supersededLink(for itemID: UUID) -> UUID? {
        Self.supersededLink(for: itemID, in: store)
    }

    /// Exact re-assertion of a superseded fact: the graph writes a fresh node
    /// over the chain's live head, the existing corpus row returns to
    /// retrieval, and the supplanted head's own corpus twin leaves it.
    private func revive(_ fact: DistilledFact, itemID: UUID, vector: [Float]?) async throws {
        if let graph, let vector {
            do {
                // The graph resolves its own chain head; the corpus supplant
                // below deliberately does NOT use this return value — the
                // ledger works graph-less (PR #87 review finding 1).
                _ = try await graph.reviveFact(fact.text, kind: fact.kind, embedding: vector)
            } catch {
                Self.log.notice("graph revive failed (corpus restore proceeds): \(error.localizedDescription, privacy: .public)")
            }
        }
        transitionCorpusTwin(itemID: itemID, to: .memory, context: "revive-restore")
        if let correctorID = supersededLink(for: itemID) {
            transitionCorpusTwin(itemID: correctorID, context: "revive-supplant")
            // Flip the ledger: the demoted corrector can itself be revived.
            recordSupersededLink(from: correctorID, to: itemID)
            try? store.deleteMeta(key: Self.supersededLinkKey(itemID))
        }
        Self.log.notice("memory revived: 1 superseded fact restored by re-assertion")
    }

    /// The corpus-twin kind transition, with the M2 divergence audit: by the
    /// time this runs the GRAPH has already committed, so a failure here means
    /// the two stores disagree — logged at `.error` (IDs + kinds only, never
    /// text) and mirrored to the audit sink. Self-heals on the next
    /// supersede/revive touching the same fact; never throws.
    private func transitionCorpusTwin(
        itemID: UUID, to kind: KnowledgeKind = .memorySuperseded, context: String
    ) {
        Self.transitionCorpusTwin(
            itemID: itemID, to: kind, context: context, store: store, rekind: rekind, auditSink: auditSink
        )
    }

    /// The top live memory twin at/above the dedupe bar, if any.
    private func semanticTwin(_ vector: [Float]) throws -> ChunkHit? {
        // limit 20, not 5: searchVector ranks across ALL kinds, and a stack of
        // similar document chunks would crowd a true memory twin out of a
        // narrow top-K before the kind filter ever saw it.
        try store.searchVector(queryVector: vector, limit: 20).first {
            $0.kind == .memory && ($0.similarity ?? 0) >= Self.semanticDedupeThreshold(for: embedder)
        }
    }

    /// Embed for dedup + graph seed. Returns nil (logged) on failure so a
    /// degenerate embedder doesn't silently read as "no duplicates" — the corpus
    /// write still proceeds (fail-open), only dedup + the graph seed are skipped.
    private func embed(_ fact: String) async -> [Float]? {
        do { return try await embedder.embed(fact) } catch {
            Self.log.notice("embed failed — dedup + graph-write skipped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Mirror a freshly-written fact into the memory graph. Best-effort: a graph
    /// failure is logged, never thrown — the corpus already holds the fact.
    private func dualWriteToGraph(_ fact: DistilledFact, vector: [Float]?) async {
        guard let graph, let vector else { return }
        do { try await graph.writeDistilledFact(fact.text, kind: fact.kind, embedding: vector) } catch {
            Self.log.notice("graph dual-write failed (corpus write stands): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Stable identity for the exact-dedupe layer: hash of the normalized
    /// fact, so capitalisation/punctuation variants collapse. Public — the
    /// MCP `remember` path uses the same identity so an agent remembering
    /// the same text twice collapses to one row.
    public static func factSourceRef(_ fact: String) -> String {
        let normalized = MemoryFactNormalizer.normalize(fact)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "memory-fact:\(hex)"
    }

    /// Short facts ARE their titles; long ones cut at a word boundary.
    static func title(for fact: String) -> String {
        guard fact.count > maxTitleLength else { return fact }
        let prefix = fact.prefix(maxTitleLength)
        let cut = prefix.lastIndex(of: " ").map { prefix[..<$0] } ?? prefix
        return String(cut) + "…"
    }
}
