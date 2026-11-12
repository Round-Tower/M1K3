//
//  PrivateCloudRawChat.swift
//  M1K3Agent
//
//  Private Cloud Compute as a raw chat, for the surfaces that lend it to other
//  apps on this Mac (ADR 0011; the policy is `PrivateCloudLending`). It carries
//  the caller's own words and nothing of M1K3's: the caller's system text is
//  the instructions, its turns are the prompt (`RawChatPrompt.flattened`: the
//  seam takes two strings and no history). No persona, memory, knowledge or
//  tools, and nothing is written anywhere.
//
//  The seam has no options, so a caller's `max_tokens` and `temperature` are
//  not honoured here and no token counts come back.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-12, Confidence 0.75 (pinned against a
//  fake backend; the real service behind it is verify-by-launch on a store-lane
//  build), Prior: none (new file).
//

import Foundation
import M1K3Inference
import M1K3LanguageModel

public enum PrivateCloudRawChat {
    /// Deltas, then one `.finished`. A failure throws as a `RawChatFailure`, after any text that arrived.
    /// The send starts when this is called, not when the stream is first read: call it only once the call
    /// is going ahead.
    public static func stream(_ request: RawChatRequest, backend: any PrivateCloudAnswering) -> RawChatStream {
        let instructions = request.system ?? ""
        let prompt = RawChatPrompt.flattened(request)
        return RawChatStream { continuation in
            let task = Task {
                var sent = ""
                do {
                    for try await snapshot in backend.answer(instructions: instructions, prompt: prompt) {
                        if let piece = RawChatPrompt.delta(sent: &sent, snapshot: snapshot) {
                            continuation.yield(.delta(piece))
                        }
                    }
                    if Task.isCancelled {
                        continuation.finish() // the consumer went away: nobody is told anything
                    } else if sent.isEmpty {
                        // Never an empty success: a stream that ends with no text is a failure.
                        continuation.finish(throwing: RawChatFailure.failed)
                    } else {
                        continuation.yield(.finished(RawChatFinish(reason: .stop, promptTokens: nil, completionTokens: nil)))
                        continuation.finish()
                    }
                } catch is CancellationError where Task.isCancelled {
                    continuation.finish()
                } catch is CancellationError {
                    // Cancelled on the backend's side, not by this caller: a cut answer must not read as whole.
                    continuation.finish(throwing: RawChatFailure.failed)
                } catch {
                    continuation.finish(throwing: failure(for: PrivateCloudError.failure(for: error)))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A call that is not served: the stream throws at once, so the client is told why.
    public static func refused(_ failure: RawChatFailure) -> RawChatStream {
        RawChatStream { $0.finish(throwing: failure) }
    }

    /// What a call is told when the offer is listed but cannot serve it; nil when it can go ahead.
    public static func refusal(for offer: PrivateCloudLending.Offer) -> RawChatFailure? {
        switch offer {
        case .ready: nil
        case .unavailable, .notOffered: .unavailable
        case .exhausted: .limitReached
        }
    }

    /// One whole answer (the last snapshot), for a tool call. Throws the backend's own `PrivateCloudError`.
    public static func ask(prompt: String, instructions: String, backend: any PrivateCloudAnswering) async throws -> String {
        var answer = ""
        for try await snapshot in backend.answer(instructions: instructions, prompt: prompt) {
            answer = snapshot
        }
        // A cancelled backend can end its stream quietly: a cut answer is never handed back as whole.
        try Task.checkCancellation()
        return answer
    }

    public static func failure(for failure: PrivateCloudFailure) -> RawChatFailure {
        switch failure {
        case .rateLimited: .busy
        case .network, .unavailable: .unavailable
        case .quotaLimitReached: .limitReached
        case .other: .failed
        }
    }
}
