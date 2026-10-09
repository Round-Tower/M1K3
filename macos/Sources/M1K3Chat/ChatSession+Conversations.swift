//
//  ChatSession+Conversations.swift
//  M1K3Chat
//
//  Conversation management: the history drawer's surface. Cross-file
//  same-module extension (ChatSession.swift stays focused on the streaming
//  reducer); state mutations route through the main class's internal members.
//
//  Every entry point is guarded by `isResponding` — a turn in flight owns the
//  transcript. Empty conversations are never persisted (lazy rows), so
//  "New chat" twice in a row costs nothing and lists nothing.
//
//  Signed: Kev + claude-fable-5, 2026-06-11, Confidence 0.9 (every transition
//  and guard test-pinned incl. the title/switch race). Prior: Unknown.
//  Review: Kev + claude-fable-5.1, 2026-10-09 — a delete reports the discarded attachments
//  (`onAttachmentsDiscarded`), gated exactly like the file discard, so Photo memories cascade.
//

import Foundation
import M1K3Inference

public extension ChatSession {
    /// Summaries for the drawer, most recent first. Reads through the session
    /// so views can key off `historyRevision` for refresh.
    func conversationSummaries() -> [ConversationSummary] {
        guard let history else { return [] }
        return (try? history.list()) ?? []
    }

    /// Archive the current conversation (it's already persisted — rows write
    /// on send) and start a fresh empty one. No-op when there's nothing to
    /// archive or a turn is in flight.
    func startNewConversation() {
        guard !isResponding, !messages.isEmpty else { return }
        // The conversation is being left — distill its undistilled turns.
        scheduleDistillationIfNeeded()
        beginConversation(id: UUID(), messages: [], title: nil)
    }

    /// Switch to another stored conversation. The current one is already
    /// persisted; an empty unsaved one simply evaporates (never listed).
    func switchTo(_ id: UUID) {
        guard !isResponding, id != activeConversationID, let history else { return }
        guard let loaded = (try? history.loadMessages(id: id)) ?? nil else { return }
        let title = ((try? history.list()) ?? []).first { $0.id == id }?.title
        // Leaving the current conversation — same exit semantics as New chat.
        scheduleDistillationIfNeeded()
        beginConversation(id: id, messages: loaded, title: title)
    }

    /// Delete a conversation. Deleting the ACTIVE one starts a fresh empty
    /// session (mirrors delete-then-new); a pending title for the deleted row
    /// no-ops at the store (setTitle ignores unknown ids).
    ///
    /// Attachment files go WITH the conversation: the transcript row holds the
    /// only references to the container-side image copies, so they're
    /// collected BEFORE the row is deleted and discarded after — a deleted
    /// sensitive photo leaves the disk, not just the drawer.
    func deleteConversation(_ id: UUID) {
        guard !isResponding, let history else { return }
        let doomed = id == activeConversationID
            ? messages
            : (try? history.loadMessages(id: id)) ?? []
        let attachments = doomed.compactMap(\.attachments).flatMap(\.self)
        let rowDeleted = (try? history.delete(id: id)) ?? false
        if id == activeConversationID {
            // The in-memory transcript resets regardless of the row's fate,
            // so the files go with it either way — a surviving orphan row
            // will list with broken thumbnails, which the drawer's next
            // delete attempt cleans up; the photo being GONE wins here.
            // DELIBERATELY asymmetric with the non-active branch below (which
            // gates discard on rowDeleted): don't "fix" the difference — the
            // active/inactive branches optimise for opposite privacy failures.
            // Both directions are test-pinned (activeDeleteSweepsFilesEvenIf
            // RowDeleteFails / failedDeleteKeepsAttachmentFiles).
            AttachmentStore.discard(attachments)
            reportDiscarded(attachments)
            beginConversation(id: UUID(), messages: [], title: nil)
        } else {
            // Non-active: discard ONLY if the row actually went. A failed DB
            // delete leaves the conversation listed — its thumbnails must not
            // be broken by an eager file sweep (the inverse privacy failure:
            // row survives, photo gone).
            if rowDeleted {
                AttachmentStore.discard(attachments)
                reportDiscarded(attachments)
            }
            noteHistoryChanged()
        }
    }
}

extension ChatSession {
    /// The delete cascade for caption memory -- only when something went.
    func reportDiscarded(_ attachments: [ImageAttachment]) {
        guard !attachments.isEmpty else { return }
        onAttachmentsDiscarded?(attachments)
    }

    /// One mutation point for "the transcript now shows conversation X".
    /// Internal — the main file's stored properties stay private(set) to
    /// everything except these two files.
    func beginConversation(id: UUID, messages: [ChatMessage], title: String?) {
        setActiveConversation(id: id, messages: messages, title: title)
        noteHistoryChanged()
    }
}
