//
//  VoicePolisher.swift
//  M1K3Voice
//
//  The polish pass at the endpoint (#852): given the live final text and the utterance's captured
//  audio, run the accurate pass under a hard time budget and apply VoicePolishPolicy. Shared by the
//  Mac and iOS shells, which call `polished` right before `VoiceTurnPreparer.prepare` (NameRepair
//  runs on whatever this returns). Never throws and never waits past the budget: every failure
//  path returns the live text.
//
//  One `.notice` per turn (category `stt`): reason, timing and word counts public, the words
//  private (they are the user's speech).
//
//  Signed: Kev + claude-opus-5-5, 2026-11-16, Confidence 0.75 (budget race and fallbacks are
//  pinned by tests with fake passes; the real pass is AppleBufferTranscriber). Prior: Unknown.
//  Review: claude-opus-5-5, 2026-11-16 (code-quality review fold, #852) — `race` is cancellation-aware (a cancelled
//  turn returns `.failed` at once and cancels the pass), the timer and the pass are both cancelled by whichever
//  result lands first (`FirstResult`, tested). Confidence 0.75.

import Foundation
import os

public struct VoicePolisher: Sendable {
    /// One accurate pass over an utterance's audio. Throws when it can't serve (no asset, no locale).
    public typealias Pass = @Sendable (UtteranceAudio) async throws -> String

    public struct Outcome: Sendable, Equatable {
        public let text: String
        public let changed: Bool
        /// nil when the polished text was used.
        public let reason: VoicePolishPolicy.Reason?
        public let seconds: Double
    }

    private static let log = Logger(subsystem: "app.m1k3", category: "stt")

    private let enabled: Bool
    private let budgetSeconds: Double
    private let pass: Pass

    public init(
        enabled: Bool = VoicePolishPolicy.enabled(),
        budgetSeconds: Double = VoicePolishPolicy.budgetSeconds,
        pass: @escaping Pass
    ) {
        self.enabled = enabled
        self.budgetSeconds = budgetSeconds
        self.pass = pass
    }

    /// The shipped pass: SpeechTranscriber in accurate mode over the buffered audio.
    public static func apple(locale: Locale = .current, enabled: Bool = VoicePolishPolicy.enabled()) -> VoicePolisher {
        VoicePolisher(enabled: enabled) { audio in
            try await AppleBufferTranscriber.transcribe(audio, locale: locale)
        }
    }

    public var isEnabled: Bool {
        enabled
    }

    /// The text the turn should carry: the polished one, or `live` untouched. Logs the breadcrumb.
    public func polished(live: String, audio: UtteranceAudio?) async -> String {
        guard enabled else { return live }
        let outcome = await run(live: live, audio: audio)
        let reason = outcome.reason?.rawValue ?? "used"
        let before = VoicePolishPolicy.wordCount(live)
        let after = VoicePolishPolicy.wordCount(outcome.text)
        Self.log.notice(
            """
            polish pass: \(reason, privacy: .public) changed=\(outcome.changed, privacy: .public) \
            \(Int(outcome.seconds * 1000), privacy: .public) ms words \(before, privacy: .public)→\(after, privacy: .public) \
            audio \(audio?.seconds ?? 0, format: .fixed(precision: 1), privacy: .public) s \
            live: \(live, privacy: .private) polished: \(outcome.text, privacy: .private)
            """
        )
        return outcome.text
    }

    /// The decision without the logging, for tests and the eval.
    public func run(live: String, audio: UtteranceAudio?) async -> Outcome {
        guard enabled else { return Outcome(text: live, changed: false, reason: .off, seconds: 0) }
        guard !live.isEmpty else { return Outcome(text: live, changed: false, reason: .noLiveText, seconds: 0) }
        if let skip = VoicePolishPolicy.skipReason(audio: audio) {
            return Outcome(text: live, changed: false, reason: skip, seconds: 0)
        }
        guard let audio else { return Outcome(text: live, changed: false, reason: .noAudio, seconds: 0) }
        let clock = ContinuousClock()
        let start = clock.now
        let result = await Self.race(seconds: budgetSeconds) { try await pass(audio) }
        let elapsed = clock.now - start
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        switch VoicePolishPolicy.decide(live: live, result: result) {
        case let .use(text):
            return Outcome(text: text, changed: text != live, reason: nil, seconds: seconds)
        case let .keep(reason):
            return Outcome(text: live, changed: false, reason: reason, seconds: seconds)
        }
    }

    /// `operation`, abandoned after `seconds`. A timeout cancels the operation but does not wait for
    /// it: a pass that ignores cancellation must still never hold the turn. Cancelling the caller
    /// (the turn was superseded) ends the race at once as a failure and cancels the operation too.
    static func race(
        seconds: Double, _ operation: @escaping @Sendable () async throws -> String
    ) async -> VoicePolishPolicy.PassResult {
        let first = FirstResult()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                first.install(continuation)
                let work = Task {
                    do {
                        try first.deliver(.text(await operation()))
                    } catch {
                        first.deliver(.failed)
                    }
                }
                let timer = Task {
                    try? await Task.sleep(for: .seconds(seconds))
                    first.deliver(.timedOut)
                }
                // Whichever result lands first, the timer and the pass both stop.
                first.onDelivered {
                    timer.cancel()
                    work.cancel()
                }
            }
        } onCancel: {
            first.deliver(.failed)
        }
    }
}

/// Resumes its continuation once, with whichever result arrives first; a result that lands before
/// the continuation is installed (a cancel at the very start) is held for it.
final class FirstResult: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<VoicePolishPolicy.PassResult, Never>?
    private var result: VoicePolishPolicy.PassResult?
    private var cleanup: (@Sendable () -> Void)?

    init() {}

    func install(_ continuation: CheckedContinuation<VoicePolishPolicy.PassResult, Never>) {
        let ready = lock.withLock { () -> VoicePolishPolicy.PassResult? in
            if result == nil { self.continuation = continuation }
            return result
        }
        if let ready { continuation.resume(returning: ready) }
    }

    /// Runs `cleanup` when a result lands (immediately if one already has).
    func onDelivered(_ cleanup: @escaping @Sendable () -> Void) {
        let alreadyDone = lock.withLock {
            if result == nil { self.cleanup = cleanup }
            return result != nil
        }
        if alreadyDone { cleanup() }
    }

    /// True when this result was the first.
    @discardableResult
    func deliver(_ new: VoicePolishPolicy.PassResult) -> Bool {
        let (won, continuation, cleanup) = lock.withLock {
            () -> (Bool, CheckedContinuation<VoicePolishPolicy.PassResult, Never>?, (@Sendable () -> Void)?) in
            guard result == nil else { return (false, nil, nil) }
            result = new
            defer { self.continuation = nil; self.cleanup = nil }
            return (true, self.continuation, self.cleanup)
        }
        guard won else { return false }
        continuation?.resume(returning: new)
        cleanup?()
        return true
    }
}
