//
//  MemoryCorpusEdit.swift
//  M1K3Chat
//
//  #699: the corpus half of a Memories edit, beside the two corpus primitives it shares with
//  MemoryDistillationCoordinator's supersede and revive: the twin's kind transition with its
//  divergence audit, and the "who corrected whom" ledger write. Split out of that file so
//  neither outgrows its lint bounds; the rules are the coordinator's, not a second copy.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (pinned in
//  MemoryCorpusEditTests over a real store). Prior: the ledger key and the twin transition
//  moved here from MemoryDistillationCoordinator.swift, whose signature carries their history.
//  Review: Kev + claude-opus-5.5, 2026-10-27 — #699 contradiction fix: `forgetCorpusTwins`, the corpus half of a
//  Memories forget, now mirrors the graph's undo (a twin the forgotten row superseded returns to retrieval), with
//  `restoreTwins` shared with `forgetCorpus` and the ledger read moved here beside its key. The style axis made a
//  forgotten correction common; without the restore the next restatement left two live rows. Confidence 0.85.
//

import Foundation
import M1K3Knowledge
import os

public extension MemoryDistillationCoordinator {
    /// What `applyEdit` did to the corpus.
    enum CorpusEdit: Equatable {
        /// The two wordings share one identity (case, spacing, closing punctuation): the
        /// live twin already answers to the new wording, so nothing moved.
        case unchanged
        /// The new wording is live in retrieval, and the old twin, if there was one, left it.
        case superseded
        /// The new wording could not be ingested. Nothing was demoted: the old twin stays
        /// live, and the divergence from the graph, which already holds the edit, is audited.
        case failed
    }

    /// The corpus half of a Memories edit, after the graph committed it as a supersede.
    /// The coordinator's own order: the new wording is ingested FIRST, and only once it is in
    /// does the old twin leave retrieval, so a failure never leaves the fact with no live
    /// twin. An edit back to a wording an earlier supersede retired restores that row, as
    /// `revive` does, rather than deduping onto a dead one. The ledger records old → new,
    /// so re-stating the old wording later restores it and demotes the edit. Failures log
    /// at `.error` with ids only and go to `auditSink`.
    static func applyEdit(
        from oldText: String,
        to newText: String,
        store: KnowledgeStore,
        ingester: DocumentIngester,
        auditSink: (@Sendable (String) -> Void)? = nil
    ) async -> CorpusEdit {
        let oldRef = factSourceRef(oldText)
        let newRef = factSourceRef(newText)
        guard oldRef != newRef else { return .unchanged }
        let oldTwinID = try? store.itemID(forSourceRef: oldRef)
        let newTwin: DocumentIngester.IngestResult
        do {
            newTwin = try await ingester.ingest(
                title: title(for: newText), text: newText, sourceRef: newRef, kind: .memory, source: .user
            )
        } catch {
            let line = "memory corpus/graph divergence [edit-ingest]: the edited wording failed to ingest after "
                + "graph commit; old twin \(oldTwinID?.uuidString ?? "none") stays live"
            log.error("\(line, privacy: .public)")
            auditSink?(line)
            return .failed
        }
        if newTwin.wasDeduped, (try? store.item(id: newTwin.itemID))?.kind == .memorySuperseded {
            transitionCorpusTwin(
                itemID: newTwin.itemID, to: .memory, context: "edit-restore",
                store: store, rekind: nil, auditSink: auditSink
            )
            try? store.deleteMeta(key: supersededLinkKey(newTwin.itemID))
        }
        if let oldTwinID, oldTwinID != newTwin.itemID {
            transitionCorpusTwin(
                itemID: oldTwinID, context: "edit-supersede", store: store, rekind: nil, auditSink: auditSink
            )
            recordSupersededLink(from: oldTwinID, to: newTwin.itemID, store: store)
        }
        return .superseded
    }

    /// The corpus half of a Memories forget, after the graph forgot the rows: delete the twin of
    /// each of `texts`, and put back what those twins corrected (each `.memorySuperseded` twin
    /// whose ledger entry names one of them returns to `.memory`), the corpus mirror of
    /// `MemoryStore.forget(id:)` un-superseding in the graph. Without it, forgetting a correction
    /// brought the ask back in the graph while its twin stayed out of retrieval, and the next
    /// restatement revived it a second time: two live graph rows for one ask, said twice in the
    /// style line (#699). Best-effort, never throws: the graph forget has committed. Returns the
    /// corpus ids deleted, in `texts` order.
    static func forgetCorpusTwins(of texts: [String], in store: KnowledgeStore) -> [UUID] {
        var twins: [UUID] = []
        for text in texts {
            guard let id = (try? store.itemID(forSourceRef: factSourceRef(text))).flatMap({ $0 }),
                  !twins.contains(id)
            else { continue }
            twins.append(id)
        }
        guard !twins.isEmpty else { return [] }
        do {
            try restoreTwins(correctedBy: Set(twins), in: store)
        } catch {
            log.error("memory forget: restoring the rows a forgotten twin corrected failed")
        }
        let deleted = twins.filter { (try? store.deleteItem(id: $0)) == true }
        try? store.deleteMeta(keys: deleted.map(supersededLinkKey))
        return deleted
    }
}

// MARK: - The corpus primitives the supersede, the revive and the edit share

extension MemoryDistillationCoordinator {
    /// CORPUS-side record of "who corrected whom" (meta table, IDs only).
    /// This — not the graph — is what revive() reads to find the corrector it
    /// must demote: the graph is best-effort/optional (nil for corpus-only
    /// callers, and for the live app whenever memory.sqlite failed to open),
    /// and a repair that depends on it would leave two contradicting live
    /// rows exactly in the degraded state that needs the repair most
    /// (PR #87 review finding 1).
    static func supersededLinkKey(_ itemID: UUID) -> String {
        "memory.superseded-by:\(itemID.uuidString)"
    }

    /// The row that superseded `itemID`, from the ledger; nil when none is recorded.
    static func supersededLink(for itemID: UUID, in store: KnowledgeStore) -> UUID? {
        (try? store.meta(key: supersededLinkKey(itemID))).flatMap { $0 }.flatMap(UUID.init(uuidString:))
    }

    /// Every `.memorySuperseded` twin whose ledger names one of `correctors` (and is not itself one)
    /// returns to `.memory` and loses its entry: what a forget of the correctors undoes. Returns the count.
    @discardableResult
    static func restoreTwins(correctedBy correctors: Set<UUID>, in store: KnowledgeStore) throws -> Int {
        var restored = 0
        for twin in try store.allItems(kind: .memorySuperseded, limit: Int.max) where !correctors.contains(twin.id) {
            guard let corrector = supersededLink(for: twin.id, in: store), correctors.contains(corrector) else {
                continue
            }
            if try store.setKind(id: twin.id, newKind: .memory) {
                try store.deleteMeta(key: supersededLinkKey(twin.id))
                restored += 1
            }
        }
        return restored
    }

    static func recordSupersededLink(from oldItemID: UUID, to newItemID: UUID, store: KnowledgeStore) {
        do {
            try store.setMeta(key: supersededLinkKey(oldItemID), value: newItemID.uuidString)
        } catch {
            log.error("supersede-ledger write failed for item \(oldItemID.uuidString, privacy: .public)")
        }
    }

    static func transitionCorpusTwin(
        itemID: UUID,
        to kind: KnowledgeKind = .memorySuperseded,
        context: String,
        store: KnowledgeStore,
        rekind: (@Sendable (UUID, KnowledgeKind) throws -> Bool)?,
        auditSink: (@Sendable (String) -> Void)?
    ) {
        let outcome: Bool
        do {
            outcome = try rekind.map { try $0(itemID, kind) } ?? store.setKind(id: itemID, newKind: kind)
        } catch {
            outcome = false
        }
        guard !outcome else { return }
        let line = "memory corpus/graph divergence [\(context)]: item \(itemID.uuidString) "
            + "failed transition to \(kind.rawValue) after graph commit"
        log.error("\(line, privacy: .public)")
        auditSink?(line)
    }
}
