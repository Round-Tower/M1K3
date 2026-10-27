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
//  no axis work. An import never does it (`retiresLiveStyle: false`), and for that writer a twin at
//  the bar that is a live style row is no twin either (`retirableTwin`): Kev's ruling is that an
//  import never retires a live ask, and the twin path is kind-blind.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.85 (pinned over the real stores in
//  StyleAxisSupersedeTests; the cue table's recall on live asks is unmeasured). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — `retirableTwin` closes the twin half of
//  "an import never retires a live ask" (an imported preference at the bar superseded the live style row, and
//  the ask left the style line); a failed read keeps both rows. Pinned in ImportedStyleTests. Confidence 0.85.
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
        guard retiresLiveStyle, fact.kind == .style, let graph, vector != nil else { return nil }
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

    /// The twin this writer may supersede. The live writer: any (the Tier-2 rule, kind-blind). A writer
    /// that never retires a live ask (an import): none whose graph row is a live `.style`, so both rows
    /// stay live, the imported one a preference. No graph: the twin (there is no style line to protect).
    /// A failed read keeps both rows: "never" is the rule.
    func retirableTwin(_ twin: ChunkHit?) async -> ChunkHit? {
        guard let twin, !retiresLiveStyle, let graph else { return twin }
        let identity = MemoryFactNormalizer.normalize(twin.content)
        do {
            let live = try await graph.liveStyleTexts()
            let isLiveStyle = live.contains { MemoryFactNormalizer.normalize($0) == identity }
            if isLiveStyle { Self.log.notice("style kept: an imported twin of a live stated style retires nothing") }
            return isLiveStyle ? nil : twin
        } catch {
            let kind = String(describing: type(of: error))
            Self.log.notice("style read failed (the twin stays live): \(kind, privacy: .public)")
            return nil
        }
    }
}
