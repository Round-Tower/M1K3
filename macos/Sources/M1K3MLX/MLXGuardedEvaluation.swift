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
//

import Foundation
import M1K3Inference
import MLX

enum MLXGuardedEvaluation {
    /// Run `body` (every MLX evaluation inside it, on any task it creates) inside MLX's own error scope.
    static func run<R>(
        isolation _: isolated (any Actor)? = #isolation,
        _ body: () async throws -> R
    ) async throws -> R {
        // The body keeps its own isolation (it hops back to the caller's actor when called), so this box is
        // a hand-off of a closure that is already safe to call from anywhere, not a data race.
        nonisolated(unsafe) let work = body
        do {
            return try await withError { try await work() }
        } catch {
            throw translate(error, cancelled: Task.isCancelled)
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
