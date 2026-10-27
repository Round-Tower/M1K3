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
//     `import/<provider>/<day>` in both stores. Then each conversation is filed once as a
//     `.conversation` knowledge item: searched and cited like a document, never a memory.
//
//  Both steps are async, cooperative about cancellation and report progress per conversation;
//  "never blocks the UI" is structural — the import UI runs them in a detached utility task, the
//  way MemoryExporter runs. Cancelling a commit returns what it finished (`wasCancelled`); the
//  next commit of the same bundle completes the rest without doubling anything (fact hashes and
//  conversation sourceRefs both dedupe). Nothing here touches the network.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-27, Confidence 0.8 (mechanics pinned with scripted
//  distillers and the hashing embedder; the real distiller's judgement on imported chats is owed
//  as a SelfTest arm).
//  Prior: none (new file).

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
    /// The provider conversation it came from; nil for an OKF fact.
    public let conversationID: String?
    /// The conversation's title, or the OKF fact's own title.
    public let sourceTitle: String?
    /// Why the review screen leaves it unticked, if it does.
    public let sensitivity: ImportSensitivity.Category?

    public init(
        id: Int, fact: DistilledFact, conversationID: String?, sourceTitle: String?,
        sensitivity: ImportSensitivity.Category?
    ) {
        self.id = id
        self.fact = fact
        self.conversationID = conversationID
        self.sourceTitle = sourceTitle
        self.sensitivity = sensitivity
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

public struct ImportReceipt: Sendable, Equatable {
    /// Facts newly written (exact duplicates of what was already known don't count).
    public var factsWritten: Int
    public var conversationsFiled: Int
    /// Conversations an earlier import (or an interrupted commit) had already filed.
    public var conversationsAlreadyFiled: Int
    /// Conversations that could not be filed (an embedder failure); the next commit retries them.
    public var conversationsFailed: Int
    /// The commit stopped early because its task was cancelled; the counts are what it finished.
    public var wasCancelled: Bool

    public init(
        factsWritten: Int = 0, conversationsFiled: Int = 0, conversationsAlreadyFiled: Int = 0,
        conversationsFailed: Int = 0, wasCancelled: Bool = false
    ) {
        self.factsWritten = factsWritten
        self.conversationsFiled = conversationsFiled
        self.conversationsAlreadyFiled = conversationsAlreadyFiled
        self.conversationsFailed = conversationsFailed
        self.wasCancelled = wasCancelled
    }
}

public struct ConversationImportPipeline: Sendable {
    /// Counts and error text only, never fact or conversation text.
    private static let log = M1K3Log.logger(.memoryDistill)
    /// OKF facts commit in batches of this many, so a large folder still reports progress and
    /// notices cancellation.
    static let factBatchSize = 50

    public let tag: ImportSourceTag
    private let coordinator: MemoryDistillationCoordinator
    private let ingester: DocumentIngester

    /// One coordinator, wired like the app's live distillation but writing `tag` into both stores.
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
            selfNames: selfNames
        )
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
        var seen: Set<String> = []
        func offer(_ fact: DistilledFact, conversationID: String?, title: String?) {
            // The same fact said in two conversations is one proposal (the same identity the
            // write path dedupes on).
            guard seen.insert(MemoryDistillationCoordinator.factSourceRef(fact.text)).inserted else { return }
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
                        offer(fact, conversationID: conversation.id, title: conversation.title)
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failed += 1
                Self.log.notice("import: distiller failed on one conversation: \(error.localizedDescription, privacy: .public)")
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

    /// Write `accepted` and file every conversation in `bundle`, oldest first, so a later
    /// restatement supersedes an earlier one. One progress step per OKF fact batch and per
    /// conversation. Cancellation stops between steps and returns the partial receipt.
    public func commit(
        _ accepted: [ImportProposal],
        from bundle: ImportBundle,
        progress: @Sendable (ImportProgress) -> Void = { _ in }
    ) async throws -> ImportReceipt {
        let conversations = bundle.chronologicalConversations
        let ids = Set(conversations.map(\.id))
        let byConversation = Dictionary(grouping: accepted.filter { $0.conversationID.map(ids.contains) == true }) {
            $0.conversationID ?? ""
        }
        let loose = accepted.filter { $0.conversationID.map(ids.contains) != true }
        let batches = stride(from: 0, to: loose.count, by: Self.factBatchSize).map {
            Array(loose[$0 ..< min($0 + Self.factBatchSize, loose.count)])
        }
        let total = batches.count + conversations.count
        var receipt = ImportReceipt()
        var completed = 0
        func step() {
            completed += 1
            progress(ImportProgress(phase: .committing, completed: completed, total: total))
        }

        for batch in batches {
            guard !Task.isCancelled else { return cancelled(receipt) }
            receipt.factsWritten += try await coordinator.store(batch.map(\.fact))
            step()
        }
        for conversation in conversations {
            guard !Task.isCancelled else { return cancelled(receipt) }
            if let facts = byConversation[conversation.id] {
                receipt.factsWritten += try await coordinator.store(facts.map(\.fact))
            }
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
                Self.log.notice("import: filing one conversation failed: \(error.localizedDescription, privacy: .public)")
            }
            step()
        }
        Self.log.notice(
            "import committed \(receipt.factsWritten) fact(s), filed \(receipt.conversationsFiled) conversation(s)"
        )
        return receipt
    }

    private func cancelled(_ receipt: ImportReceipt) -> ImportReceipt {
        var partial = receipt
        partial.wasCancelled = true
        Self.log.notice("import commit cancelled after \(partial.conversationsFiled) conversation(s)")
        return partial
    }
}
