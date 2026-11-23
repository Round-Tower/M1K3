//
//  LandedAnswer.swift
//  M1K3Chat
//
//  The answer a `send` actually produced, for the side effects that follow a turn (a page opening
//  beside the chat). A send that returns at once — superseded by a barge-in, or refused while the
//  chat is answering — produced nothing, and `messages.last` is then the PREVIOUS answer or one still
//  streaming. Capture `messages.last?.id` before the send and ask afterwards.
//
//  Signed: Kev + claude-opus-5-5, 2026-11-23, Confidence 0.85, Prior: Unknown (new file)

import Foundation

public enum LandedAnswer {
    /// The assistant message this send produced: new since `previousLastID`, finished (the chat is no
    /// longer responding and the status is `.complete`), and not cut short. Otherwise nil.
    public static func completed(
        in messages: [ChatMessage], after previousLastID: UUID?, isResponding: Bool
    ) -> ChatMessage? {
        guard !isResponding, let last = messages.last,
              last.role == .assistant, last.id != previousLastID,
              last.status == .complete, last.interrupted != true
        else { return nil }
        return last
    }
}
