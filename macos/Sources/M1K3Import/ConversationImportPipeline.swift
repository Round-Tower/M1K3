//
//  ConversationImportPipeline.swift
//  M1K3Import
//
//  Bring your memory home (#711), in two steps with the user's review between them:
//
//  1. `propose` reads every conversation, oldest first, through the SAME distillation coordinator
//     live chat uses — in slices the distiller's own prompt cap holds, so a long conversation's
//     early turns are read too — and returns the facts that survive the #288 fence (anchored in
//     what the user said in that conversation, never the cloud assistant's offers). Nothing is
//     written. Each proposal carries its sensitivity class: the review screen leaves those
//     unticked by default. An OKF folder from another M1K3 is already facts and skips the
//     distiller.
//  2. `commit` writes the accepted facts through `MemoryDistillationCoordinator.store` — the one
//     write path, so an exact duplicate is a no-op and a restatement supersedes its live twin at
//     the embedder's own bar (`semanticDedupeThreshold(for:)`, never restated here) — tagged
//     `import/<provider>/<day>` in both stores, all of them BEFORE any transcript is filed (each
//     fact's twin search then scans the corpus as it stood, not one the import keeps growing).
//     An import never revives a superseded fact: an old chat restating what the user has since
//     corrected is history, not a repair. Then each conversation the caller chose (`filing`: the
//     review screen's decision, separate from the facts) is filed once as a `.conversation`
//     knowledge item: searched and cited like a document, never a memory.
//
//  Both steps are async, cooperative about cancellation and report progress per step; "never
//  blocks the UI" is structural — the import UI runs them in a detached utility task, the way
//  MemoryExporter runs. Cancelling a commit returns what it finished (`wasCancelled`), wherever the
//  cancel lands; a fact or a conversation that fails is counted and skipped. The next commit of
//  the same bundle completes the rest without doubling anything (fact hashes and conversation
//  sourceRefs both dedupe). Nothing here touches the network.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.8 (mechanics pinned with scripted
//  distillers and the hashing embedder; the real distiller's judgement on imported chats is owed
//  as a SelfTest arm).
//  Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — propose dedupes LAST-wins (a fact keeps its
//  first slot but moves to the newest conversation that said it, `statedIn` lists all of them), so A, B, A ends with A
//  live; commit takes an explicit `filing` (no default: unticking a sensitive fact meant nothing while its transcript
//  was filed anyway), writes every fact before any transcript, catches per fact (`factsFailed`; a cancel inside a
//  write returns the partial receipt), and builds its coordinator with `revivesSupersededFacts: false`. Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-10-27 (bot review fold, #732) — `statedIn` names each conversation once (two
//  slices of one long chat, or one slice that says a fact twice, listed it twice; the newest stays last), and every log
//  line carries an error's type, never its text (a distiller or embedder error can echo the prompt). Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-10-27 — #699, Kev's ruling: an imported style ask files as a PREFERENCE
//  (`filed`, applied to the review's proposals and again at commit), and the coordinator is built with
//  `supersedesStyleByAxis: false`, so an import never retires a live ask on its axis. Confidence 0.85.
//  Review: Kev + claude-opus-5.5, 2026-10-27 (pre-push review fold) — the flag is `retiresLiveStyle: false` and now
//  also covers the twin path: an imported preference at the bar of a live style row leaves it live (it superseded
//  it, kind-blind, and the ask left the style line). Pinned in ImportedStyleTests. Confidence 0.85.

import Foundation
import M1K3Chat
import M1K3Knowledge
import M1K3LogCore
import M1K3Memory
import M1K3MemoryChatBridge
import os

/// One fact offered for the user's review.
public struct ImportProposal: Sendable, Equatable, Identifiable {
    /// Position in the proposal list: stable for one `propose` run.
    public let id: Int
    public let fact: DistilledFact
    /// The newest provider conversation that stated it (the slot commit writes it in, so the
    /// latest statement wins); nil for an OKF fact.
    public let conversationID: String?
    /// Every conversation that stated it, once each, oldest first (`conversationID` is the last).
    /// What the review screen needs to keep a sensitive fact's transcripts unfiled too.
    public let statedIn: [String]
    /// The conversation's title, or the OKF fact's own title.
    public let sourceTitle: String?
    /// Why the review screen leaves it unticked, if it does.
    public let sensitivity: ImportSensitivity.Category?

    public init(
        id: Int, fact: DistilledFact, conversationID: String?, sourceTitle: String?,
        sensitivity: ImportSensitivity.Category?, statedIn: [String]? = nil
    ) {
        self.id = id
        self.fact = fact
        self.conversationID = conversationID
        self.sourceTitle = sourceTitle
        self.sensitivity = sensitivity
        self.statedIn = statedIn ?? conversationID.map { [$0] } ?? []
    }

    /// The review screen's default tick: everything except a sensitive class.
    public var acceptedByDefault: Bool {
        sensitivity == nil
    }
}

public struct ImportProgress: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case proposing
        case committing
    }

    public let phase: Phase
    public let completed: Int
    public let total: Int
    /// Conversations the distiller failed on so far (skipped, not fatal).
    public let failed: Int

    public init(phase: Phase, completed: Int, total: Int, failed: Int = 0) {
        self.phase = phase
        self.completed = completed
        self.total = total
        self.failed = failed
    }
}

/// Which conversations `commit` files as cited `.conversation` knowledge. Filing is separate from
/// accepting facts: a transcript holds every sentence, including the ones the user unticked, so the
/// review screen decides (and the copy says transcripts are filed).
public enum ConversationFiling: Sendable, Equatable {
    case all
    /// Memories only: no transcript is filed.
    case none
    /// Only these conversation ids.
    case only(Set<String>)

    func includes(_ id: String) -> Bool {
        switch self {
        case .all: true
        case .none: false
        case let .only(ids): ids.contains(id)
        }
    }
}

public struct ImportReceipt: Sendable, Equatable {
    /// Facts newly written (exact duplicates of what was already known don't count).
    public var factsWritten: Int
    /// Accepted facts whose write failed (an embedder or store error); skipped, the rest go on.
    public var factsFailed: Int
    public var conversationsFiled: Int
    /// Conversations an earlier import (or an interrupted commit) had already filed.
    public var conversationsAlreadyFiled: Int
    /// Conversations that could not be filed (an embedder failure); the next commit retries them.
    public var conversationsFailed: Int
    /// The commit stopped early because its task was cancelled; the counts are what it finished.
    public var wasCancelled: Bool

    public init(
        factsWritten: Int = 0, factsFailed: Int = 0, conversationsFiled: Int = 0, conversationsAlreadyFiled: Int = 0,
        conversationsFailed: Int = 0, wasCancelled: Bool = false
    ) {
        self.factsWritten = factsWritten
        self.factsFailed = factsFailed
        self.conversationsFiled = conversationsFiled
        self.conversationsAlreadyFiled = conversationsAlreadyFiled
        self.conversationsFailed = conversationsFailed
        self.wasCancelled = wasCancelled
    }
}

public struct ConversationImportPipeline: Sendable {
    /// Counts and error type names only, never fact, conversation or error text (an error from the
    /// distiller or the embedder can echo the prompt it was given).
    private static let log = M1K3Log.logger(.memoryDistill)
    /// Accepted facts commit in batches of this many, one progress step each, so a large import
    /// still reports progress and notices cancellation.
    static let factBatchSize = 50

    public let tag: ImportSourceTag
    private let coordinator: MemoryDistillationCoordinator
    private let ingester: DocumentIngester

    /// One coordinator, wired like the app's live distillation but writing `tag` into both stores
    /// and never reviving a superseded fact.
    public init(
        tag: ImportSourceTag,
        knowledgeStore: KnowledgeStore,
        memoryStore: MemoryStore,
        embedder: any EmbeddingService,
        distiller: any MemoryDistilling,
        selfNames: DistillationAttribution.UserNames = DistillationAttribution.systemUserNames
    ) {
        self.tag = tag
        ingester = DocumentIngester(store: knowledgeStore, embedder: embedder)
        coordinator = MemoryDistillationCoordinator(
            distiller: distiller,
            ingester: ingester,
            store: knowledgeStore,
            embedder: embedder,
            graph: DistilledFactGraphAdapter(store: memoryStore, source: tag.graphSource),
            corpusSource: tag.knowledgeSource,
            revivesSupersededFacts: false,
            retiresLiveStyle: false,
            selfNames: selfNames
        )
    }

    /// #699, Kev's ruling (2026-10-27): a style ask found in an import files as a PREFERENCE, listed in
    /// Memories but never riding the system prompt and never retiring a live ask (the coordinator's
    /// `retiresLiveStyle: false`: no axis supersede, and a live style twin at the bar stays live). An old
    /// chat's "shorter, please" is history, not what the user wants now (OKF's style→note is the same rule).
    static func filed(_ fact: DistilledFact) -> DistilledFact {
        fact.kind == .style ? DistilledFact(text: fact.text, kind: .preference) : fact
    }

    // MARK: - Propose

    /// The facts worth keeping from `bundle`, for review. Writes nothing. One progress step per
    /// conversation; a conversation the distiller fails on is counted and skipped. Throws
    /// `CancellationError` when cancelled — a partial proposal list is no use to a review screen.
    public func propose(
        _ bundle: ImportBundle,
        progress: @Sendable (ImportProgress) -> Void = { _ in }
    ) async throws -> [ImportProposal] {
        var proposals: [ImportProposal] = []
        var slot: [String: Int] = [:]
        func offer(_ fact: DistilledFact, conversationID: String?, title: String?) {
            // The same fact said in two conversations is one proposal (the same identity the
            // write path dedupes on). LAST wins: it keeps its first slot in the list, but moves to
            // the newest conversation that said it, so commit writes it where the user said it
            // last (A, B, A ends with A live, not B).
            let key = MemoryDistillationCoordinator.factSourceRef(fact.text)
            if let index = slot[key] {
                let earlier = proposals[index]
                // One entry per conversation: two slices of one long chat (or one slice that says
                // it twice) still name that conversation once, and the newest stays last.
                var statedIn = earlier.statedIn
                if let conversationID {
                    statedIn.removeAll { $0 == conversationID }
                    statedIn.append(conversationID)
                }
                proposals[index] = ImportProposal(
                    id: earlier.id, fact: earlier.fact, conversationID: conversationID ?? earlier.conversationID,
                    sourceTitle: title ?? earlier.sourceTitle, sensitivity: earlier.sensitivity,
                    statedIn: statedIn
                )
                return
            }
            slot[key] = proposals.count
            proposals.append(ImportProposal(
                id: proposals.count, fact: fact, conversationID: conversationID, sourceTitle: title,
                sensitivity: ImportSensitivity.category(of: fact.text)
            ))
        }

        let conversations = bundle.chronologicalConversations
        var failed = 0
        for (index, conversation) in conversations.enumerated() {
            try Task.checkCancellation()
            do {
                for slice in Self.slices(of: conversation.chatTurns) {
                    for fact in try await coordinator.propose(turns: slice) {
                        offer(Self.filed(fact), conversationID: conversation.id, title: conversation.title)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed += 1
                Self.log.notice("import: distiller failed on one conversation: \(Self.kind(of: error), privacy: .public)")
            }
            progress(ImportProgress(phase: .proposing, completed: index + 1, total: conversations.count, failed: failed))
        }
        for fact in bundle.facts {
            offer(DistilledFact(text: fact.text, kind: fact.kind), conversationID: nil, title: fact.title)
        }
        Self.log.notice("import proposed \(proposals.count) fact(s) from \(conversations.count) conversation(s), \(failed) failed")
        return proposals
    }

    /// Consecutive runs of turns that each fit one distiller prompt
    /// (`MemoryDistillationPrompt.maxTotalChars`, charged per `line(for:)` exactly as `build`
    /// charges it). A run with no real user turn is skipped downstream as trivial.
    static func slices(of turns: [ChatTurn]) -> [[ChatTurn]] {
        var slices: [[ChatTurn]] = []
        var current: [ChatTurn] = []
        var size = 0
        for turn in turns {
            let cost = MemoryDistillationPrompt.line(for: turn).count
            if !current.isEmpty, size + cost > MemoryDistillationPrompt.maxTotalChars {
                slices.append(current)
                current = []
                size = 0
            }
            current.append(turn)
            size += cost
        }
        if !current.isEmpty {
            slices.append(current)
        }
        return slices
    }

    // MARK: - Commit

    /// Write `accepted`, then file the conversations `filing` names, both oldest first, so a later
    /// restatement supersedes an earlier one. Facts whose conversation isn't in `bundle` (an OKF
    /// fact, a memories-only import) go first. One progress step per batch of facts and per filed
    /// conversation. A cancel — between steps or inside a write — returns the partial receipt; a
    /// fact or conversation that fails is counted and skipped.
    public func commit(
        _ accepted: [ImportProposal],
        from bundle: ImportBundle,
        filing: ConversationFiling,
        progress: @Sendable (ImportProgress) -> Void = { _ in }
    ) async throws -> ImportReceipt {
        let conversations = bundle.chronologicalConversations
        var position: [String: Int] = [:]
        for (index, conversation) in conversations.enumerated() where position[conversation.id] == nil {
            position[conversation.id] = index
        }
        let facts = accepted.enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.conversationID.flatMap { position[$0] } ?? -1
                let right = rhs.element.conversationID.flatMap { position[$0] } ?? -1
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .map { Self.filed($0.element.fact) }
        let batches = stride(from: 0, to: facts.count, by: Self.factBatchSize).map {
            Array(facts[$0 ..< min($0 + Self.factBatchSize, facts.count)])
        }
        let toFile = conversations.filter { filing.includes($0.id) }
        let total = batches.count + toFile.count
        var receipt = ImportReceipt()
        var completed = 0
        func step() {
            completed += 1
            progress(ImportProgress(phase: .committing, completed: completed, total: total))
        }

        // Every fact before any transcript: each twin search scans the corpus as it stood, not one
        // this import keeps growing with thousands of transcript chunks.
        for batch in batches {
            guard !Task.isCancelled else { return cancelled(receipt) }
            for fact in batch {
                do {
                    receipt.factsWritten += try await coordinator.store([fact])
                } catch is CancellationError {
                    return cancelled(receipt)
                } catch {
                    receipt.factsFailed += 1
                    Self.log.notice("import: writing one fact failed: \(Self.kind(of: error), privacy: .public)")
                }
            }
            step()
        }
        for conversation in toFile {
            guard !Task.isCancelled else { return cancelled(receipt) }
            do {
                let filed = try await ingester.ingest(
                    title: conversation.title,
                    pages: conversation.pages,
                    sourceRef: tag.conversationSourceRef(id: conversation.id),
                    kind: .conversation,
                    source: tag.knowledgeSource
                )
                if filed.wasDeduped {
                    receipt.conversationsAlreadyFiled += 1
                } else {
                    receipt.conversationsFiled += 1
                }
            } catch is CancellationError {
                return cancelled(receipt)
            } catch {
                receipt.conversationsFailed += 1
                Self.log.notice("import: filing one conversation failed: \(Self.kind(of: error), privacy: .public)")
            }
            step()
        }
        Self.log.notice("""
        import committed \(receipt.factsWritten) fact(s) (\(receipt.factsFailed) failed), \
        filed \(receipt.conversationsFiled) conversation(s)
        """)
        return receipt
    }

    /// What a failure log may say about `error`: its type's name, never its text.
    private static func kind(of error: any Error) -> String {
        String(describing: type(of: error))
    }

    private func cancelled(_ receipt: ImportReceipt) -> ImportReceipt {
        var partial = receipt
        partial.wasCancelled = true
        Self.log.notice("""
        import commit cancelled after \(partial.factsWritten) fact(s), \
        \(partial.conversationsFiled) conversation(s)
        """)
        return partial
    }
}
