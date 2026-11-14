//
//  AppCore+Read.swift
//  M1K3iOS
//
//  The read on the phone: a file sent from the composer is read with instructions
//  only (`ChatSession.read`): no persona, no tools, no history, on this device,
//  display-only. The look's wrapper shape (AppCore+Look), without a camera.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-14, Confidence 0.7 (the turn is pinned in
//  ChatSessionReadTests; this wrapper is compile-checked and owes a try in the hand).
//  Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-11-14 (the summoned pass on #833) — `read`/`readAgain` say whether they
//  started, so ChatScreen hands back a question it could not read instead of dropping it, and both check the
//  window themselves rather than trusting the route. Confidence 0.7 (compile-checked; owes a try in the hand).
//  Context: Kev, 2026-11-14: "Context ingestion & compression / sanitization, and analysis
//  without system prompt - similar to vision"; "Instructions only pal. Yes to the Keep This workflow."
//

import Foundation
import M1K3Chat
import M1K3Inference

extension AppCore {
    /// Read one text and answer one question about it, on this phone. False when it could not
    /// start (a turn in flight, or a brain that cannot read here): the caller hands the words and
    /// the file back. A brain that cannot read never sees the text (`ChatSession.runRead` checks
    /// the window, and the façade fails the stream for Brain at Home and Private Cloud).
    func read(_ question: String, source: ReadSource) async -> Bool {
        guard isReady, !chat.isResponding, reader.readContextTokens > 0 else { return false }
        avatar.setActivity(.thinking)
        beginAutoSpeakSession()
        guard await chat.read(question, source: source, reader: reader) else {
            cancelAutoSpeak()
            avatar.resetToIdle()
            return false
        }
        settleTypedTurn()
        return true
    }

    /// Another question about the last read's text, on this phone. False as for `read`.
    func readAgain(_ question: String) async -> Bool {
        guard isReady, !chat.isResponding, chat.lastRead != nil, reader.readContextTokens > 0 else { return false }
        avatar.setActivity(.thinking)
        beginAutoSpeakSession()
        guard await chat.readAgain(question, reader: reader) else {
            cancelAutoSpeak()
            avatar.resetToIdle()
            return false
        }
        settleTypedTurn()
        return true
    }
}
