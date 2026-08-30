//
//  MLXExitGuard.swift
//  M1K3App
//
//  The quit-during-generation guard (crash D90B5887, 2026-08-30, live-caught
//  by Kev): ⌘Q while a generation is mid-eval lets `exit()` tear down Metal
//  under a cooperative-pool thread that's still inside `mlx_async_eval`; MLX
//  raises, and with no global handler installed mlx-swift `fatalError()`s —
//  turning every clean quit that races a prefill into a crash report. The
//  picker's background downloads (PR #154) make quit-with-work-in-flight the
//  COMMON case, so this stopped being ignorable.
//
//  The guard keeps fail-loud semantics untouched in normal operation (an MLX
//  error mid-session is a real bug and should crash loudly, exactly as
//  before) and changes ONE case: once termination has begun, the error is
//  logged and the erroring thread parks so `exit()` finishes undisturbed.
//
//  Signed: Kev + claude-fable-5, 2026-08-30, Confidence 0.85 (the crash class
//  is read off the symbolicated report + the unified log, not inferred; the
//  park-not-return choice is deliberate — returning would let MLX continue on
//  torn-down Metal state. Verify-owed: ⌘Q mid-generation exits quietly).
//  Prior: none (new file).

import Foundation
import MLX
import os

enum MLXExitGuard {
    /// Flipped on the main thread the moment AppKit begins termination; read
    /// from whatever thread MLX errors on. OSAllocatedUnfairLock over
    /// Synchronization.Atomic so the c-convention handler below can reach it
    /// without capturing context.
    private static let terminating = OSAllocatedUnfairLock(initialState: false)

    private static let log = Logger(subsystem: "app.m1k3", category: "mlx-load")

    /// Install at launch, before any MLX use.
    static func install() {
        installGlobalHandler {
            message, _ in
            let text = message.map { String(cString: $0) } ?? "unknown MLX error"
            if MLXExitGuard.terminating.withLock({ $0 }) {
                MLXExitGuard.log.notice(
                    "mlx error during app termination (suppressed, exit continues): \(text, privacy: .public)"
                )
                // Park, never return: the process is exiting, and returning
                // would resume MLX on Metal state exit() already tore down.
                while true {
                    Thread.sleep(forTimeInterval: 3600)
                }
            } else {
                // Today's behaviour, kept deliberately: fail loud on a live app.
                fatalError(text)
            }
        }
    }

    static func markTerminating() {
        terminating.withLock { $0 = true }
    }

    /// `MLX.setErrorHandler` is deprecated in favour of the task-scoped
    /// `withErrorHandler`, but a task-scoped handler can't cover a teardown
    /// race — the erroring eval belongs to whatever task happened to be in
    /// flight at quit. The protocol hop below calls the deprecated global
    /// installer without spraying a warning over every build.
    private protocol DeprecatedInstaller {
        static func install(
            _ handler: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
        )
    }

    private enum Shim: DeprecatedInstaller {
        @available(*, deprecated)
        static func install(
            _ handler: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
        ) {
            MLX.setErrorHandler(handler)
        }
    }

    private static func installGlobalHandler(
        _ handler: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
    ) {
        (Shim.self as DeprecatedInstaller.Type).install(handler)
    }
}
