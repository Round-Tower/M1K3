//
//  MLXGuardedEvaluation.swift
//  M1K3MLX
//
//  An MLX error with no handler in scope is a `fatalError`. On the phone that is the background exit:
//  iOS refuses GPU work there, and a generation step already in flight (a prefill chunk, one decode step)
//  submits a command buffer that fails with `Insufficient Permission (to submit GPU work from background)`
//  (#858, Kev's iPhone 17 Pro, 2026-11-16: `MLX/ErrorHandler.swift:345: Fatal error: [METAL] Command buffer
//  execution failed`, signal 5, 0.4 s after the background event).
//
//  Every entry that drives an MLX evaluation for a brain (a plain turn, a seeded turn, a tool step, a look,
//  a read, a caption, the persona warm, the weights load) runs inside `run`. MLX's handler is a TASK-LOCAL:
//  mlx-swift-lm's `generate` creates its decode task from the calling task, so the scope reaches the loop,
//  and `container.perform` hops actors inside the same task. The scope therefore has to ENCLOSE the call and
//  stay open until the stream has been drained, which is why callers wrap the whole drain, not the
//  `generate(...)` call alone. A failure surfaces when the scope ends as a Swift throw.
//
//  What the throw becomes (`translate`): while the turn is being cancelled (the background exit stops the
//  turn first) the refusal is the stop's own fallout, so it is a `CancellationError` and the turn reads as
//  stopped; any other MLX failure is `InferenceError.generationFailed`, which the existing failure copy
//  already handles. A non-MLX error passes through untouched. A successful run is unchanged, and so is the
//  Mac: there a failure is rare, and a throw is still better than a trap.
//
//  Signed: Kev + claude-opus-5.5, 2026-11-16, Confidence 0.7, Prior: none (new file).
//  Context: #858; the same shape as `KokoroGuardedRead` (build 544) and `EmbeddingGemma2Guard`.
//  Open: owed on a phone: leave the app at ~1 s, ~3 s and mid-decode on Lil and read that the turn ends
//  stopped with no crash (MLX cannot run under `swift test`). Whether the Metal error sticks after one
//  failure (Kokoro's did not) is unverified for the brains.
//  Review: Kev + claude-opus-5.5, 2026-11-17 (#862) — `run` counts itself in `MLXEvaluationCounter`, so the phone's
//  background shed can wait for any evaluation still running (a title, a distillation), not only the chat turn.
//  The Open's phone half is closed: leaving mid-turn on Lil ended stopped with no crash, 3 of 3 on Kev's 17 Pro
//  (2026-11-16, #861). Whether the Metal error sticks after one failure stays unmeasured. Confidence 0.8.
//  Review: claude-opus-5-5, 2026-11-21 — the scope writes MLX's message to `MLXFailureLedger` before it
//  translates, and `installRecordingHandler` does the same for an error outside every scope, then traps as
//  before. 15 iPhone crash logs (1.1.0 to 1.4.0, mostly A13 phones on Pocket) carried no message at all.
//  Debug-only drills (`-forceMLXError`, `-forceMLXCrash`) for the device check. Confidence 0.8.
//

import Foundation
import M1K3Inference
import M1K3LogCore
import MLX
import Synchronization

public enum MLXGuardedEvaluation {
    /// Run `body` (every MLX evaluation inside it, on any task it creates) inside MLX's own error scope.
    static func run<R>(
        counting counter: MLXEvaluationCounter = .shared,
        recording ledger: MLXFailureLedger = .standard,
        isolation _: isolated (any Actor)? = #isolation,
        _ body: () async throws -> R
    ) async throws -> R {
        // The body keeps its own isolation (it hops back to the caller's actor when called), so this box is
        // a hand-off of a closure that is already safe to call from anywhere, not a data race.
        nonisolated(unsafe) let work = body
        // Counted for the whole scope, so the phone's background shed can wait for ANY evaluation still on the
        // GPU (a title, a distillation), not only the chat turn (#862).
        counter.enter()
        defer { counter.leave() }
        do {
            return try await withError {
                #if DEBUG
                    try MLXFailureDrill.failIfAsked()
                #endif
                return try await work()
            }
        } catch {
            let cancelled = Task.isCancelled
            // MLX's own message, written down before anything else, so the next report can say what failed
            // (15 iPhone crash logs on 2026-11-21, none with it). A stopped turn's refusal is the stop's
            // fallout, and the body's own throw isn't MLX's: neither is a failure to report.
            if !cancelled, case let .caught(message)? = error as? MLXError {
                ledger.record(message)
            }
            throw translate(error, cancelled: cancelled)
        }
    }

    /// `GenerationActivity.during` with the scope inside it: the hold and the guard end together.
    static func during<R>(
        _ reason: String,
        isolation _: isolated (any Actor)? = #isolation,
        _ body: () async throws -> R
    ) async throws -> R {
        try await GenerationActivity.shared.during(reason) { try await run(body) }
    }

    /// The error a caller sees for what the scope caught. Pure, so a test can drive it without Metal.
    static func translate(_ error: Error, cancelled: Bool) -> Error {
        guard case let .caught(message)? = error as? MLXError else { return error }
        mlxTTFTLog.notice("MLX error caught (cancelled=\(cancelled, privacy: .public)): \(message, privacy: .public)")
        if cancelled { return CancellationError() }
        return InferenceError.generationFailed("MLX: \(message)")
    }
}

public extension MLXGuardedEvaluation {
    /// The process-wide handler for an MLX error OUTSIDE every guarded scope (the iPhone; the Mac's
    /// `MLXExitGuard` installs its own and records the same way): write MLX's message to the ledger, then trap
    /// exactly as mlx-swift's default does. A guarded scope's task-local handler still wins inside it.
    /// Install once at launch, before any MLX use.
    static func installRecordingHandler() {
        installGlobalHandler { message, _ in
            let text = message.map { String(cString: $0) } ?? "unknown MLX error"
            MLXFailureLedger.standard.record(text)
            fatalError(text)
        }
    }

    /// `MLX.setErrorHandler` is deprecated in favour of the task-scoped `withErrorHandler`, but a task-scoped
    /// handler can't reach an evaluation no scope encloses. The protocol hop calls the deprecated global
    /// installer without a warning on every build (moved here from `MLXExitGuard`, so both shells share it).
    static func installGlobalHandler(
        _ handler: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
    ) {
        (GlobalHandlerShim.self as GlobalHandlerInstaller.Type).install(handler)
    }
}

private protocol GlobalHandlerInstaller {
    static func install(_ handler: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void)
}

private enum GlobalHandlerShim: GlobalHandlerInstaller {
    @available(*, deprecated)
    static func install(_ handler: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void) {
        MLX.setErrorHandler(handler)
    }
}

#if DEBUG
    /// Debug-only drills for a device check of the two paths (2026-11-21), armed `armDelay` after the first guarded
    /// scope (past the weights load and the persona warm): `-forceMLXError YES` raises a real MLX error inside EVERY
    /// scope from then on, so the persona prefix's inline fallback fails too and the turn ends on "couldn't answer"
    /// with "Send a report" (fired once, the prefix failed and the turn answered inline, on Kev's 17 Pro);
    /// `-forceMLXCrash YES` raises one outside every scope, once (the recording handler writes it, then traps; the
    /// next launch's report carries it).
    enum MLXFailureDrill {
        static let armDelay: TimeInterval = 30
        private static let state = Mutex<(firstScope: Date?, fired: Bool)>((nil, false))

        static func failIfAsked(defaults: UserDefaults = .standard, now: Date = Date()) throws {
            let crash = defaults.bool(forKey: "forceMLXCrash")
            guard crash || defaults.bool(forKey: "forceMLXError") else { return }
            let fire = state.withLock { drill -> Bool in
                let first = drill.firstScope ?? now
                drill.firstScope = first
                guard now.timeIntervalSince(first) >= armDelay, !(crash && drill.fired) else { return false }
                drill.fired = true
                return true
            }
            guard fire else { return }
            if crash {
                // A detached task carries no task-local handler: this reaches the global one.
                Task.detached { eval(mismatchedSum()) }
                return
            }
            try withError { eval(mismatchedSum()) }
        }

        /// A broadcast MLX rejects ([2, 5] + [3, 5]): a genuine MLX error through MLX's own handler, no GPU.
        private static func mismatchedSum() -> MLXArray {
            MLXArray(0 ..< 10, [2, 5]) + MLXArray(0 ..< 15, [3, 5])
        }
    }
#endif

/// How many MLX evaluations are inside `MLXGuardedEvaluation.run` right now, process-wide. Every brain evaluation
/// (generate, stream, tool step, look, read, caption, warm, load) passes through that scope, so this is the
/// precise "is the GPU still busy with a brain" signal. `GenerationActivity` is not: `LocalAgent` holds it for a
/// whole agent run, tool waits and Mini or Home turns included. An instance, so a test counts on its own.
final class MLXEvaluationCounter: Sendable {
    static let shared = MLXEvaluationCounter()

    private let count = Mutex<Int>(0)

    var current: Int {
        count.withLock { $0 }
    }

    var any: Bool {
        current > 0
    }

    func enter() {
        count.withLock { $0 += 1 }
    }

    func leave() {
        count.withLock { $0 -= 1 }
    }
}
