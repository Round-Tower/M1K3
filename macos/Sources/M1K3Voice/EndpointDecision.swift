//
//  EndpointDecision.swift
//  M1K3Voice
//
//  The reason-carrying result of an endpoint check. Born from the 2026-08-15
//  log read: a whole voice session persisted exactly ONE endpointing breadcrumb
//  (the learned-cadence line), so "which branch took the user's turn, and after
//  how long an idle gap" — the first question in every "it cut me off" report —
//  was unanswerable. The decision is now a value the controller logs at
//  `.notice` (`.info`/`.debug` do not persist in OSLogStore — the standing
//  lesson), and the formatting is pure so the line's shape is test-pinned.
//
//  Signed: Kev + claude-fable-5, 2026-08-15, Confidence 0.9 (pure value +
//  formatter, test-pinned). Prior: the boolean-only SilenceEndpointer.
//

import Foundation

/// Why (and how) a listen ended. Produced by `SilenceEndpointer.decision(at:)`.
public struct EndpointDecision: Sendable, Equatable {
    public enum Reason: String, Sendable {
        /// Anti-hang backstop: `maxWait` from first speech elapsed.
        case maxWait = "max wait"
        /// The spoken submit button — a trailing "please" (see PoliteEndpoint).
        case politeWord = "polite word"
        /// A complete-sounding thought went idle past the silence threshold.
        case completeThought = "complete thought"
        /// A trailed-off thought exhausted the longer mid-thought hold.
        case midThoughtHold = "mid-thought hold"
    }

    public let reason: Reason
    /// How long the partial had been idle when the decision fired.
    public let idle: Duration
    /// The threshold that applied (including any learned-cadence floor), so the
    /// log shows how patient the loop actually was — not just that it ended.
    public let required: Duration

    public init(reason: Reason, idle: Duration, required: Duration) {
        self.reason = reason
        self.idle = idle
        self.required = required
    }

    /// One log line, shaped like the `voice turn:` timeline's.
    public var logLine: String {
        "voice endpoint: \(reason.rawValue) · idle \(Self.seconds(idle)) · required \(Self.seconds(required))"
    }

    private static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds)
            + Double(duration.components.attoseconds) * 1e-18
        return String(format: "%.1fs", value)
    }
}
