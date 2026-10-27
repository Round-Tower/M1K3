//
//  StyleAxisSupersede.swift
//  M1K3Chat
//
//  #699, the contradiction MEMSTAT found (docs/evals/2026-10-27-memstat-style.txt): 7 of 8 style
//  corrections sit under EmbeddingGemma's 0.95 twin bar, which must never drop, so "short" and
//  "long, detailed" both stayed live and the style line said both. This is the coordinator's
//  second key, for `.style` only: a new style fact from the LIVE writer retires the newest live
//  style row whose axes (`StyleAxis`) it covers, through the same Tier-2 supersede a twin takes,
//  so the lineage is kept, a restatement revives and a forget undoes. One victim per write
//  (a graph supersede names one row); MemoryStore.swift is untouched (no migration).
//
//  The corpus has no kind, so the graph (`liveStyleTexts`) says which rows are style; the corpus
//  victim is the row with that text's fact identity, which an edited row also carries. No graph,
//  no axis work. An import never does it (`supersedesStyleByAxis: false`).
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (pinned over the real stores in
//  StyleAxisSupersedeTests; the cue table's recall on live asks is unmeasured). Prior: none (new file).
//

import Foundation
import M1K3Knowledge

extension MemoryDistillationCoordinator {
    /// The live style row a new style fact retires on its axis.
    struct StyleAxisVictim {
        /// The graph node's text: the supersede's join key.
        let text: String
        /// Its live corpus twin, or nil when the corpus holds none (the graph supersede still runs).
        let corpusItemID: UUID?
    }

    /// The newest live `.style` row `fact` covers on its axes, or nil: not a style fact, not the live
    /// writer, no graph, no vector to seed the new node, or nothing covered. A failed read is no victim.
    func styleAxisVictim(for fact: DistilledFact, vector: [Float]?) async -> StyleAxisVictim? {
        guard supersedesStyleByAxis, fact.kind == .style, let graph, vector != nil else { return nil }
        let live: [String]
        do {
            live = try await graph.liveStyleTexts()
        } catch {
            let kind = String(describing: type(of: error))
            Self.log.notice("style axis read failed (no supersede): \(kind, privacy: .public)")
            return nil
        }
        guard let text = StyleAxis.newestRetired(by: fact.text, amongNewestFirst: live) else { return nil }
        let twinID = (try? store.itemID(forSourceRef: Self.factSourceRef(text))).flatMap { $0 }
        let liveTwinID = twinID.flatMap { id in (try? store.item(id: id))?.kind == .memory ? id : nil }
        return StyleAxisVictim(text: text, corpusItemID: liveTwinID)
    }
}
