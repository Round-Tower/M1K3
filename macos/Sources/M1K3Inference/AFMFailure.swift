//
//  AFMFailure.swift
//  M1K3Inference
//
//  What went wrong on a Mini (Apple Foundation Models) turn, as a countable
//  class rather than a sentence.
//
//  Before this, `AppleFoundationModelsProvider` had no Logger at all and
//  `generateStreaming` ended in `catch { continuation.finish() }`. Four very
//  different failures — the prompt didn't fit, the content was refused, the
//  on-device daemon had fallen over, the model simply produced nothing — were
//  one indistinguishable empty stream, on the tier that is the first-run
//  default. Each of those has a DIFFERENT fix, and the log could not tell them
//  apart, so every diagnosis of #102/#111 was downstream of a guess.
//
//  Kept pure and separate from the OS adapter so the mapping is unit-pinned
//  (AFMFailureTests); the adapter itself stays verified-by-compile per its own
//  documented convention.
//
//  Signed: Kev + claude-opus-5, 2026-08-09, Confidence 0.85, Prior: Unknown
//  Context: macos/docs/NEXT_SESSION.md #102. Only the overflow phrasing is
//  quoted verbatim from a live throw; the others are recognised from SDK case
//  names and the 2026-08-03 daemon collapse, so `.unknown` is deliberately the
//  honest floor rather than a best guess.
//

import Foundation

/// A coarse, countable classification of an Apple Foundation Models failure.
public enum AFMFailure: String, Sendable, Equatable, CaseIterable {
    /// The prompt did not fit the context window. Fix: shrink the prompt.
    case contextOverflow = "context-overflow"
    /// Apple's safety guardrail refused the content. Fix: not a size problem —
    /// do NOT respond by trimming a prompt that fits.
    case guardrailViolation = "guardrail"
    /// The on-device model daemon is unavailable, typically the rate-collapse
    /// seen under back-to-back turns (ModelManagerServices exhaustion). Fix:
    /// pace the caller; nothing about the prompt is wrong.
    case daemonUnavailable = "daemon-unavailable"
    /// Apple's rate limiter fired (macOS 27 typed `LanguageModelError.rateLimited`).
    /// Distinct from `.daemonUnavailable` (the daemon fell over vs the quota is
    /// spent). Fix: back off.
    case rateLimited = "rate-limited"
    /// The generation timed out (macOS 27 typed `LanguageModelError.timeout`).
    case timeout
    /// Unrecognised. Deliberately not folded into a neighbouring class — an
    /// honest "we don't know" is worth more than a confident misdiagnosis, and
    /// a rising `unknown` count is itself the signal to come back here.
    case unknown

    /// Classify from an error's text. Ordered most-specific-first so a throw
    /// carrying several phrases lands on the most actionable class rather than
    /// whichever check happened to run first.
    public static func classify(_ description: String) -> AFMFailure {
        let text = description.lowercased()
        // Hoisted to a local rather than a multi-line `if` condition: swiftformat
        // wraps such a condition's brace onto its own line and swiftlint's
        // opening_brace rule then rejects it. The two tools disagree; a named
        // condition satisfies both and reads better anyway.
        let isOverflow = text.contains("exceeds the maximum allowed context size")
            || text.contains("exceededcontextwindowsize")
        if isOverflow {
            return .contextOverflow
        }
        if text.contains("guardrail") {
            return .guardrailViolation
        }
        if text.contains("modelmanagererror") || text.contains("sensitivecontentanalysisml") {
            return .daemonUnavailable
        }
        return .unknown
    }

    /// Classify from a thrown error. Checks the typed `LanguageModelError` enum
    /// (macOS 27) first; falls back to string matching for daemon errors and
    /// other throws the SDK doesn't surface as typed cases.
    public static func classify(error: any Error) -> AFMFailure {
        #if compiler(>=6.4)
            if #available(macOS 27.0, iOS 27.0, visionOS 27.0, *) {
                if let typed = error as? LanguageModelError {
                    return from(typed)
                }
            }
        #endif
        return classify(String(describing: error))
    }
}

#if compiler(>=6.4)
    @_weakLinked import FoundationModels

    extension AFMFailure {
        @available(macOS 27.0, iOS 27.0, visionOS 27.0, *)
        static func from(_ error: LanguageModelError) -> AFMFailure {
            switch error {
            case .contextSizeExceeded:
                return .contextOverflow
            case .guardrailViolation, .refusal:
                return .guardrailViolation
            case .rateLimited:
                return .rateLimited
            case .timeout:
                return .timeout
            default:
                return .unknown
            }
        }
    }
#endif
