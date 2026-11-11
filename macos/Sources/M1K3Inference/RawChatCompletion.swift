//
//  RawChatCompletion.swift
//  M1K3Inference
//
//  The messages-in, tokens-out seam behind the Local API (M1K3's brains for
//  other apps on this Mac). The sibling of `RawCompletionProviding`, and raw in
//  the same structural sense: no persona, no cached persona prefix, no tools,
//  no retrieval, no memory. The caller's own system message is the whole
//  system prompt.
//
//  It differs from the older raw seam in three ways the Local API needs:
//  - it takes a conversation, not one string;
//  - a failure THROWS. The older seam ends its stream on an error, which a
//    client would read as a successful empty answer;
//  - it says how the answer ended and how many tokens it took, where the
//    runtime knows.
//
//  An `as?` capability seam: every façade forwards it (SwappableInferenceProvider
//  here, RuntimeInferenceProvider in the app), pinned by RawChatCompletionTests.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.8, Prior: none (new file)
//  Context: Kev, 2026-11-11: "1 more release before then with our current
//  work, and the server. Swiss army Mike!" The design was challenged first:
//  raw brains only, its own listener and token, failures surfaced.
//

import Foundation

public struct RawChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable {
        case system, user, assistant
    }

    public let role: Role
    public let content: String

    public init(_ role: Role, _ content: String) {
        self.role = role
        self.content = content
    }
}

/// One validated chat request: an optional system prompt and turns that end on
/// the user's question.
public struct RawChatRequest: Sendable, Equatable {
    public enum Invalid: Error, Sendable, Equatable, CaseIterable {
        case empty, noUserTurn, mustEndOnUser, blankMessage, badMaxTokens

        public var message: String {
            switch self {
            case .empty: "messages must not be empty"
            case .noUserTurn: "messages must include a user message"
            case .mustEndOnUser: "the last message must be from the user"
            case .blankMessage: "a message has no text content"
            case .badMaxTokens: "max_tokens must be a positive integer"
            }
        }
    }

    /// The caller's system prompt: every system message, in order. Nil when none was sent.
    public let system: String?
    /// The user and assistant turns in order, ending on a user turn.
    public let turns: [RawChatMessage]
    /// A ceiling the provider clamps to its own cap: a caller can shorten, never lengthen.
    public let maxTokens: Int?
    public let temperature: Double?

    public var messages: [RawChatMessage] {
        (system.map { [RawChatMessage(.system, $0)] } ?? []) + turns
    }

    /// The question being answered.
    public var question: String {
        turns.last?.content ?? ""
    }

    /// Everything before the question.
    public var earlier: [RawChatMessage] {
        Array(turns.dropLast())
    }

    public init(messages: [RawChatMessage], maxTokens: Int?, temperature: Double? = nil) throws {
        guard !messages.isEmpty else { throw Invalid.empty }
        guard messages.allSatisfy({ !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw Invalid.blankMessage }
        let systems = messages.filter { $0.role == .system }.map(\.content)
        let turns = messages.filter { $0.role != .system }
        guard turns.contains(where: { $0.role == .user }) else { throw Invalid.noUserTurn }
        guard turns.last?.role == .user else { throw Invalid.mustEndOnUser }
        if let maxTokens, maxTokens < 1 { throw Invalid.badMaxTokens }
        system = systems.isEmpty ? nil : systems.joined(separator: "\n\n")
        self.turns = turns
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public struct RawChatFinish: Sendable, Equatable {
    public enum Reason: String, Sendable, Equatable {
        /// The model finished its answer.
        case stop
        /// The answer hit the token ceiling.
        case length
    }

    public let reason: Reason
    /// Nil where the runtime does not say (Apple's model).
    public let promptTokens: Int?
    public let completionTokens: Int?

    public init(reason: Reason, promptTokens: Int?, completionTokens: Int?) {
        self.reason = reason
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

public enum RawChatEvent: Sendable, Equatable {
    /// The next piece of the answer (a delta, never a snapshot).
    case delta(String)
    /// The last event of a successful stream.
    case finished(RawChatFinish)
}

public typealias RawChatStream = AsyncThrowingStream<RawChatEvent, any Error>

/// A provider that can answer a conversation with nothing of M1K3's own in context.
public protocol RawChatCompleting: Sendable {
    /// Deltas, then one `.finished`. Throws when the generation fails: never an
    /// empty success. Nil when the capability is unavailable right now (a façade
    /// whose active backend does not conform). Cancelling the consumer stops the
    /// generation.
    func completeRawChat(_ request: RawChatRequest) -> RawChatStream?
}

/// Why a raw chat failed, in terms a server can turn into a status a client understands.
public enum RawChatFailure: Error, Sendable, Equatable {
    /// The conversation does not fit the brain's context window.
    case contextTooLong
    /// The runtime declined the content (Apple's guardrail, an unsupported language).
    case refused
    /// The runtime is rate-limited, timed out or down for the moment: try again.
    case busy
    /// Anything else.
    case failed

    public init(apple failure: AFMFailure) {
        switch failure {
        case .contextOverflow: self = .contextTooLong
        case .guardrailViolation, .unsupportedLanguage: self = .refused
        case .rateLimited, .daemonUnavailable, .timeout: self = .busy
        case .unknown: self = .failed
        }
    }
}

public enum RawChatPrompt {
    /// The conversation as ONE prompt, for a runtime with no way to seed earlier
    /// turns: a labelled preamble, then the question. A single-turn request is
    /// the question alone.
    public static func flattened(_ request: RawChatRequest) -> String {
        guard !request.earlier.isEmpty else { return request.question }
        let lines = request.earlier.map { turn in
            "\(turn.role == .user ? "User" : "Assistant"): \(turn.content)"
        }
        return "Earlier in this conversation:\n" + lines.joined(separator: "\n") + "\n\nUser: " + request.question
    }
}

extension SwappableInferenceProvider: RawChatCompleting {
    public func completeRawChat(_ request: RawChatRequest) -> RawChatStream? {
        (active as? RawChatCompleting)?.completeRawChat(request)
    }
}
