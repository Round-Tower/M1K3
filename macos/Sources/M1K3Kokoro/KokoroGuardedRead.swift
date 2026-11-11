//
//  KokoroGuardedRead.swift
//  M1K3Kokoro
//
//  Reading values out of MLX is where a GPU failure surfaces: `asArray` forces
//  the evaluation, and an MLX error with no handler in scope is a `fatalError`.
//  On the phone that was a crash: a tester's 1.3.0 (544) report, 2026-11-05,
//  shows the app in the background (iOS refuses GPU work there), voice audio
//  being torn down on one thread, and on another
//      KokoroSynthesizer.produceChunks → MLXArray.asArray → mlx_array_eval
//      → _mlx_error → ErrorHandler.dispatch → _assertionFailure.
//  The background exit cancels speech, but a sentence already on the inference
//  queue runs to its read.
//
//  Every read in this module goes through here: the evaluation runs inside
//  MLX's own error scope, the scope is checked BEFORE the bytes are touched (a
//  failed evaluation leaves no data to copy), and the failure is a Swift throw
//  the speech stream already knows how to end on.
//
//  Signed: Kev + claude-fable-5.2, 2026-11-11, Confidence 0.7, Prior: none (new file).
//  Context: found by the first run of tools/asc/feedback.py (#748) on build 544.
//  Open: the MLX message is not in the crash log, so "GPU work refused in the
//  background" is the reading of the evidence, not a captured error. The guard
//  holds for any MLX failure that surfaces at a read. Two things are owed on a phone: whether MLX's
//  Metal error stays set after one failure (speech would then fall back to the system voice until a
//  relaunch), and the background case itself. The brains' own generation has no such scope
//  (mlx-swift-lm), and a turn still generating at the background exit is the
//  same shape: not fixed here.
//

import Foundation
@preconcurrency import MLX

enum KokoroGuardedRead {
    /// Evaluate `array` and copy its values out. Throws `MLXError` when the evaluation fails.
    static func values<T: HasDType>(_ array: MLXArray, as type: T.Type) throws -> [T] {
        try withError { failure in
            array.eval()
            try failure.check()
            let copied = array.asArray(type)
            try failure.check() // the copy can evaluate again (a strided view made contiguous)
            return copied
        }
    }

    /// Force an evaluation with no read (the weights at load). Throws when it fails.
    static func evaluate(_ arrays: some Any) throws {
        try withError { failure in
            MLX.eval(arrays)
            try failure.check()
        }
    }

    /// Run a forward pass so that an MLX error anywhere inside it throws when the scope ends.
    static func scope<R>(_ body: () throws -> R) throws -> R {
        try withError { _ in try body() }
    }

    /// Verify-by-launch (MLX runs only inside the app): force an MLX error inside the scope and say what
    /// happened. A trap here would be the bug this file exists to prevent.
    ///
    /// It runs on a plain dispatch queue, as `infer` does: MLX's error scope is a task-local, and off a Swift
    /// task it rides the thread. It forces a shape error, raised where the op is built. A GPU failure is
    /// raised at the evaluation instead, on the same thread (MLX rethrows a Metal error to the thread that
    /// waits), but that path cannot be forced here: it is owed on a phone.
    static func selfCheck() -> String {
        DispatchQueue(label: "app.m1k3.kokoro.guard-check").sync {
            do {
                let sum: [Float] = try scope {
                    let mismatched = MLXArray(0 ..< 10, [2, 5]) + MLXArray(0 ..< 15, [3, 5])
                    return try values(mismatched.asType(.float32), as: Float.self)
                }
                return "✗ kokoro guarded read: an MLX error did not throw (\(sum.count) values)"
            } catch {
                return "✓ kokoro guarded read: an MLX error on a dispatch queue throws instead of trapping"
            }
        }
    }
}

/// The app's door to the launch check.
public enum KokoroLaunchChecks {
    public static func guardedRead() -> String {
        KokoroGuardedRead.selfCheck()
    }
}
