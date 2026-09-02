//
//  NotchHUDController.swift
//  M1K3App
//
//  Drives the notch HUD's show/hide from `env.speechHighlight.isActive` —
//  the SAME in-process signal ContentView's auto-speak karaoke gate already
//  reads (see AppEnvironment.speechHighlight), so no MCP polling or `defaults`
//  shell-out is needed (both were jam-only workarounds for living outside the
//  app process). Owns one NotchHUDWindow for the app's lifetime.
//
//  Two gotchas carried forward from the jam prototype, load-bearing:
//
//  1. Kokoro's own `speaking` status genuinely flaps true/false every
//     ~150-300ms BETWEEN spoken sentences within one answer (confirmed live,
//     repeatedly) — reacting to the raw signal directly makes a fading-in HUD
//     retreat before its own animation can finish. `NotchHUDVisibility`
//     (M1K3Voice, unit-pinned) debounces this: it only reports an action on an
//     actual state CHANGE, after `hideGraceSeconds` of continuous silence.
//
//  2. `NSAnimationContext`/`.animator()` silently never reached the
//     WindowServer for this exact window config (accessory app +
//     `ignoresMouseEvents` + `.screenSaver` level) — internal state read
//     "shown, alpha 1" for 38+ seconds while a live WindowServer probe
//     (`CGWindowListCopyWindowInfo`) read alpha=0 the whole time. Root cause
//     unconfirmed; worked around with a manual per-frame interpolation
//     instead (this file's `animate`), which the same probe DID prove visible.
//
//  Both poll/animate loops use this repo's `Task` + `Task.sleep` idiom (see
//  `AppEnvironment+AutoSpeak.swift`) rather than `Timer` — no other file in
//  this codebase uses `Timer.scheduledTimer`, and a bare Timer closure needs
//  extra ceremony to prove MainActor isolation under Swift 6 strict
//  concurrency that a `@MainActor` Task already gets for free.
//
//  Signed: Kev + claude-fable-5, 2026-09-01, Confidence 0.8 (the debounce and
//  window plumbing are the jam's proven shapes, ported to this repo's Task
//  idiom instead of Timer; the on-screen feel — entrance/exit beats, the
//  72px avatar's legibility — is verify-by-launch, unheard/unseen by me).
//  Prior: the jam prototype (Kev + claude-fable-5, same session).
//

import AppKit
import Foundation
import M1K3Voice

@MainActor
final class NotchHUDController {
    private unowned let env: AppEnvironment
    private var window: NotchHUDWindow?
    private var visibility = NotchHUDVisibility()
    private var driveTask: Task<Void, Never>?
    private var animTask: Task<Void, Never>?
    private let clockStart = Date()

    init(env: AppEnvironment) {
        self.env = env
    }

    /// Start polling. Safe to call once at launch — the Settings toggle
    /// (`AppEnvironment.notchHUDEnabledKey`, read every tick) gates whether
    /// the HUD can ever actually show, so this runs for the app's whole
    /// lifetime with no separate wiring needed when the toggle flips.
    func start() {
        guard driveTask == nil else { return }
        driveTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    func stop() {
        driveTask?.cancel()
        driveTask = nil
        animTask?.cancel()
        animTask = nil
        window?.orderOut(nil)
        window = nil
    }

    private func tick() {
        let enabled = UserDefaults.standard.bool(forKey: AppEnvironment.notchHUDEnabledKey)
        let speaking = enabled && env.speechHighlight.isActive
        let now = Date().timeIntervalSince(clockStart)
        guard let action = visibility.update(speaking: speaking, atSeconds: now) else { return }
        switch action {
        case .show: showWindow()
        case .hide: hideWindow()
        }
    }

    // MARK: - Show / hide

    private func showWindow() {
        guard let screen = NSScreen.main else { return }
        let window = resolveWindow()
        let shown = window.targetOrigin(on: screen)
        let hidden = window.hiddenOrigin(shownAt: shown)
        window.setFrameOrigin(hidden)
        window.alphaValue = 0
        window.orderFrontRegardless() // never activates the app — ignoresMouseEvents + accessory collection behavior
        animate(
            from: AnimationFrame(origin: hidden, alpha: 0),
            to: AnimationFrame(origin: shown, alpha: 1),
            duration: 0.45, ease: Self.easeOutBack
        )
    }

    private func hideWindow() {
        guard let window, let screen = NSScreen.main else { return }
        let shown = window.targetOrigin(on: screen)
        let hidden = window.hiddenOrigin(shownAt: shown)
        animate(
            from: AnimationFrame(origin: shown, alpha: 1),
            to: AnimationFrame(origin: hidden, alpha: 0),
            duration: 0.3, ease: { $0 * $0 }
        ) { [weak self] in
            self?.window?.orderOut(nil)
        }
    }

    private func resolveWindow() -> NotchHUDWindow {
        if let window { return window }
        let window = NotchHUDWindow(env: env)
        self.window = window
        return window
    }

    // MARK: - Manual animation (NSAnimationContext is a proven no-op here — see header)

    private struct AnimationFrame {
        let origin: NSPoint
        let alpha: CGFloat
    }

    private func animate(
        from: AnimationFrame,
        to: AnimationFrame,
        duration: TimeInterval,
        ease: @escaping (CGFloat) -> CGFloat,
        completion: (() -> Void)? = nil
    ) {
        guard let window else { return }
        animTask?.cancel()
        animTask = Task { @MainActor [weak window] in
            let startedAt = Date()
            while !Task.isCancelled {
                let progress = min(1, Date().timeIntervalSince(startedAt) / duration)
                let eased = ease(CGFloat(progress))
                window?.setFrameOrigin(NSPoint(
                    x: from.origin.x + (to.origin.x - from.origin.x) * eased,
                    y: from.origin.y + (to.origin.y - from.origin.y) * eased
                ))
                window?.alphaValue = from.alpha + (to.alpha - from.alpha) * eased
                if progress >= 1 { break }
                try? await Task.sleep(for: .milliseconds(8)) // ~120Hz
            }
            // If a newer animate() cancelled this task, the successor now owns the
            // window — snapping to THIS animation's final frame (and firing its
            // completion, e.g. hide's orderOut) would clobber it, leaving the HUD
            // stuck at the superseded destination. Only settle if we finished.
            guard !Task.isCancelled else { return }
            window?.setFrameOrigin(to.origin)
            window?.alphaValue = to.alpha
            completion?()
        }
    }

    /// Overshoot-then-settle entrance — a plain linear slide read as flat in
    /// the jam.
    private static func easeOutBack(_ x: CGFloat) -> CGFloat {
        let c1: CGFloat = 1.70158
        let c3 = c1 + 1
        return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2)
    }
}
