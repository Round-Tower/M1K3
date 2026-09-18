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

import Foundation
import M1K3Inference

enum ChatFailureMessage {
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
