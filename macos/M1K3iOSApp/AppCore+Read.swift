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
//  Context: Kev, 2026-11-14: "Context ingestion & compression / sanitization, and analysis
//  without system prompt - similar to vision"; "Instructions only pal. Yes to the Keep This workflow."
//

import Foundation
import M1K3Chat
import M1K3Inference

extension AppCore {
    /// Read one text and answer one question about it, on this phone.
    func read(_ question: String, source: ReadSource) async {
        guard isReady, !chat.isResponding else { return }
        avatar.setActivity(.thinking)
        beginAutoSpeakSession()
        guard await chat.read(question, source: source, reader: reader) else {
            cancelAutoSpeak()
            avatar.resetToIdle()
            return
        }
        settleTypedTurn()
    }

    /// Another question about the last read's text, on this phone.
    func readAgain(_ question: String) async {
        guard isReady, !chat.isResponding, chat.lastRead != nil else { return }
        avatar.setActivity(.thinking)
        beginAutoSpeakSession()
        guard await chat.readAgain(question, reader: reader) else {
            cancelAutoSpeak()
            avatar.resetToIdle()
            return
        }
        settleTypedTurn()
    }
}
