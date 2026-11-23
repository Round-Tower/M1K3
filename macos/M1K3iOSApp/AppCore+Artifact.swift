//
//  AppCore+Artifact.swift
//  M1K3iOS
//
//  1.6, code opens beside the chat on the phone and the iPad: the same decisions the Mac makes
//  (ArtifactOpenPolicy, in M1K3Preview) over the same views. `artifact` is what ChatScreen shows,
//  as a sheet in a compact window and as a column beside the chat in a regular one. The preview
//  is the sealed one (ArtifactSandboxPolicy): no scripts, no network.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.7 — pure decisions are tested in
//  M1K3PreviewTests; the sheet and the side column are verify-on-device. Prior: Unknown (new file).

import Foundation
import M1K3Chat
import M1K3Preview

extension AppCore {
    /// What ChatScreen shows: the opened page, only in the conversation it was opened in. A new chat, a switch
    /// or a delete changes `chat.activeConversationID`, so no stale page sits beside the wrong transcript.
    var artifact: CodeArtifact? {
        artifactScope?.visible(in: chat.activeConversationID)
    }

    /// A code block's Open button: that block, in the sheet / side column.
    func openCodeBlock(language: String?, code: String) {
        guard let opened = ArtifactOpenPolicy.artifact(language: language, code: code) else { return }
        artifactScope = ScopedArtifact(ArtifactFormatter.format(opened), conversationID: chat.activeConversationID)
    }

    func closeArtifact() {
        artifactScope = nil
    }

    /// A typed or spoken turn landed: the page it made opens by itself, as on the Mac. Only the answer THIS send
    /// produced counts (`previousLastID` is the transcript's last message before it): a send that returned at once
    /// leaves the previous answer or a still-streaming one as `messages.last`, and a truncated block is no artifact.
    func surfaceLandedAnswerArtifact(after previousLastID: UUID?) {
        guard let answer = LandedAnswer.completed(
            in: chat.messages, after: previousLastID, isResponding: chat.isResponding
        ), let page = ArtifactOpenPolicy.autoOpen(inAnswer: answer.text) else { return }
        artifactScope = ScopedArtifact(ArtifactFormatter.format(page), conversationID: chat.activeConversationID)
        // A document the model wrapped in <artifact> tags lives in the view now; no-op for fenced blocks.
        chat.stripArtifactTagsFromLastMessage()
    }
}
