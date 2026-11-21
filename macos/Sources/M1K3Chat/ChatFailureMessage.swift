//
//  ChatFailureMessage.swift
//  M1K3Chat
//
//  Maps a turn failure to a user-facing line. A transient network failure (the
//  most common real case — the on-device brain is still downloading, or the CDN
//  stalled) gets a calm, actionable message instead of a raw "The request timed
//  out." string, so the chat bubble explains itself rather than dead-ending.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-10, Confidence 0.9, Prior: Unknown
//  Review: claude-opus-5-5, 2026-11-21 — `emptyAnswer`: a stream that ended with nothing, unasked, is a failure the
//  person sees (an MLX error ends the stream, so it read as a blank answer). English, like the rest. Confidence 0.85.

import Foundation
import M1K3Inference

enum ChatFailureMessage {
    /// A turn whose stream ended with nothing, unasked (a provider ends its stream on an error rather than
    /// throwing): the answer's text, and the short reason under it.
    static let emptyAnswer = "Sorry — I couldn't answer that. Nothing came back from the brain; try again."
    static let emptyAnswerReason = "No answer came back."

    static func userFacing(for error: Error) -> String {
        if case let .providerUnavailable(message) = error as? InferenceError {
            return message
        }
        if RetryPolicy.isTransientNetworkError(error) {
            return "M1K3's brain is still downloading, or the network was slow. "
                + "Give it a moment and try again."
        }
        return "Sorry — I couldn't answer that. \(error.localizedDescription)"
    }
}
