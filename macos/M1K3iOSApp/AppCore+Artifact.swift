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
    /// A code block's Open button: that block, in the sheet / side column.
    func openCodeBlock(language: String?, code: String) {
        guard let opened = ArtifactOpenPolicy.artifact(language: language, code: code) else { return }
        artifact = ArtifactFormatter.format(opened)
    }

    func closeArtifact() {
        artifact = nil
    }

    /// An answer has landed (typed, spoken or a look): the page it made opens by itself, as on the Mac.
    /// A stopped or failed answer opens nothing — a truncated block is no artifact.
    func surfaceLastAnswerArtifact() {
        guard let answer = chat.messages.last, answer.role == .assistant, answer.interrupted != true else { return }
        if case .failed = answer.status { return }
        guard let page = ArtifactOpenPolicy.autoOpen(inAnswer: answer.text) else { return }
        artifact = ArtifactFormatter.format(page)
        // A document the model wrapped in <artifact> tags lives in the view now; no-op for fenced blocks.
        chat.stripArtifactTagsFromLastMessage()
    }
}
