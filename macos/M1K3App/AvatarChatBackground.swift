//
//  AvatarChatBackground.swift
//  M1K3App
//
//  The avatar (constellation / companion creature / pixel face) as a full-window
//  background behind the chat — the default (Settings or the toolbar toggle turns it
//  off), and REACTIVE: it blooms when M1K3 is idle
//  or speaking, and recedes (dims, blurs, scales back) while you read a streaming
//  answer or type, so the conversation always stays legible. Reuses AvatarSurface
//  (the same 3-way dispatch the voice hero uses), so it inherits the
//  user's chosen companion for free; the reactive decision is the pure, TDD'd
//  ChatBackdropTreatment. Mirrors AudioCaptureBackdrop: a gated, reduce-motion-
//  aware, non-interactive layer over the glass.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.75 (treatment TDD'd;
//  the full-bleed look, legibility over the glass bubbles, and the bloom/recede
//  feel are verify-by-eye at ⌘R). Prior: Unknown.
//  Review: Kev + claude-fable-5.1, 2026-09-12 — the thinking rain now pauses
//  with the same treatment the avatar honours (recede/still/Reduce Motion)
//  and whenever the window is off screen; before, only Low Power paused it.
//  Confidence now 0.8.
//  Review: Kev + claude-opus-5-5, 2026-10-01 — the reading scrim follows the appearance
//  (`BackdropInk`): black at the edges greyed a light window and sank the tray; light
//  now lifts the edges with white instead. Dark is unchanged. Confidence 0.75 (by eye).
//  Review: Kev + claude-opus-5.5, 2026-10-11 — the thinking rain is unmounted (Kev, TestFlight: "janky —
//  remove for now"): its clock froze for a whole turn because the treatment recedes while thinking, so
//  lines stood still then jumped. `showsInferenceRain` and its branch are gone; the pure InferencePhosphor
//  model and BackdropInk.rain stay as the seam to bring it back. This is now THE chat avatar (the panel is
//  retired). Confidence 0.8.
//  Review: Kev + claude-opus-5.5, 2026-10-21 — the backdrop SLEEPS: idle M1K3, an empty composer and no
//  input for `BackdropSleep.idleAfter` (90 s; `-backdropSleepAfter N` overrides) fade the surface out of the
//  tree, and any pointer, key or scroll in the app, or M1K3 doing anything, fades it back. Measured with
//  the chat window in front: animating 46.5% CPU, paused 42.0%, absent 0.0% (a frame cap did nothing),
//  so only absence is cheap. Confidence 0.75 (the rule is pinned; the felt fade is verify-by-launch).
//  Review: Kev + claude-opus-5.5, 2026-10-21 (pre-push review fold) — the input monitor lives in a `.task` (cancelled
//  when the view leaves; onDisappear isn't promised for a closing window), its callback asserts the main actor, a busy
//  M1K3 is re-checked a whole window later (no 1 Hz loop), and `canSleep: false` keeps first run's face awake.

import AppKit
import Foundation
import M1K3Avatar
import OSLog
import SwiftUI

struct AvatarChatBackground: View {
    let env: AppEnvironment
    /// The user is composing — recede so the draft + transcript stay crisp.
    let isTyping: Bool
    /// False where the face IS the show (first run's wake bar): it never sleeps there.
    var canSleep = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Input bookkeeping lives in a box, not in state: a mouse move must not re-render.
    @State private var input = BackdropInputClock()
    @State private var asleep = false

    private static let log = Logger(subsystem: "app.m1k3", category: "companion")

    private var treatment: ChatBackdropTreatment {
        ChatBackdropTreatment.resolve(
            activity: env.avatar.state.activity,
            isTyping: isTyping,
            reduceMotion: reduceMotion,
            // Battery state isn't observable; read at render time. Activity/typing
            // changes re-render and re-read it, which is timely enough.
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    var body: some View {
        let resolved = treatment
        ZStack {
            // Asleep = not in the tree at all: only absence stops the surface's render loop.
            if !asleep {
                AvatarSurface(env: env, paused: !resolved.animatesMotion)
                    .scaleEffect(resolved.scale)
                    .blur(radius: resolved.blur)
                    .opacity(resolved.opacity)
                    .ignoresSafeArea()
                    .transition(.opacity)
            }
            ReadingScrim()
                .ignoresSafeArea()
        }
        // A background must never swallow chat/scroll interaction.
        .allowsHitTesting(false)
        .animation(transition(for: resolved), value: resolved)
        .animation(reduceMotion ? nil : .easeInOut(duration: asleep ? 1.6 : 0.6), value: asleep)
        // The monitor lives exactly as long as this task: SwiftUI cancels it when the view
        // leaves, which onDisappear doesn't promise for a closing window or a torn-down popover.
        .task {
            input.typing = isTyping
            input.start { wake("input") }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
            }
            input.stop()
        }
        .onChange(of: env.avatar.state.activity) { _, activity in
            // The window restarts when M1K3 stops, not when the user last moved.
            input.touch()
            if activity.isActive { wake("activity") }
        }
        .onChange(of: isTyping) { _, typing in
            input.typing = typing
            input.touch()
            if typing { wake("typing") }
        }
        .task(id: asleep) { await sleepWhenIdle() }
        // Decorative here (unlike the voice hero, which IS the
        // content) — VoiceOver has nothing useful to say about a bloom/recede
        // backdrop sitting behind the transcript it must never compete with.
        .accessibilityHidden(true)
    }

    private func wake(_ reason: StaticString) {
        input.touch()
        guard asleep else { return }
        asleep = false
        Self.log.notice("backdrop awake (\(reason, privacy: .public))")
    }

    /// One sleeping Task, re-armed per `asleep` flip: never a clock, never a per-frame read.
    private func sleepWhenIdle() async {
        guard canSleep, !asleep else { return }
        let window = Self.idleAfter
        while !Task.isCancelled {
            let now = Date()
            if BackdropSleep.isAsleep(
                activity: env.avatar.state.activity, isTyping: input.typing,
                lastInput: input.last, now: now, idleAfter: window
            ) {
                asleep = true
                Self.log.notice("backdrop asleep after \(Int(window)) s idle")
                return
            }
            // Busy or typing: the onChange handlers restart the window when that ends, so look
            // again a whole window later; otherwise exactly when the window closes.
            let busy = env.avatar.state.activity.isActive || input.typing
            let due = BackdropSleep.nextCheck(lastInput: input.last, now: now, idleAfter: window)
            let wait = busy ? window : max(due.timeIntervalSince(now), 1)
            try? await Task.sleep(for: .seconds(wait))
        }
    }

    /// `-backdropSleepAfter N` (seconds) for a launch A/B; the shipped window otherwise.
    private static var idleAfter: TimeInterval {
        let override = UserDefaults.standard.double(forKey: "backdropSleepAfter")
        return override > 0 ? override : BackdropSleep.idleAfter
    }

    /// Lively spring when blooming, calm ease when receding, and NO transition
    /// motion under Reduce Motion (the visibility still changes, just instantly).
    private func transition(for resolved: ChatBackdropTreatment) -> Animation? {
        guard !reduceMotion else { return nil }
        return resolved.animatesMotion
            ? .spring(response: 0.5, dampingFraction: 0.85)
            : .easeInOut(duration: 0.3)
    }
}

/// A gentle vertical scrim — stronger at the top (toolbar) and bottom (input
/// bar + the newest, streaming turn), near-clear through the middle — so text
/// reads over the avatar without curtaining it. Darkens on dark, lightens on
/// light (`BackdropInk`). Non-interactive.
private struct ReadingScrim: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let ink = BackdropInk(isDark: colorScheme == .dark)
        let tone: Color = ink.scrimIsDark ? .black : .white
        let scrim = ink.scrim
        LinearGradient(
            stops: [
                .init(color: tone.opacity(scrim.top), location: 0.0),
                .init(color: tone.opacity(scrim.upper), location: 0.28),
                .init(color: tone.opacity(scrim.lower), location: 0.72),
                .init(color: tone.opacity(scrim.bottom), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}

/// The last user input in this app, from a local event monitor. A reference, so the
/// monitor writes a timestamp without touching SwiftUI state; `onInput` runs only to
/// wake a sleeping backdrop.
@MainActor
private final class BackdropInputClock {
    var last = Date()
    var typing = false
    private var monitor: Any?

    func touch() {
        last = Date()
    }

    func start(onInput: @escaping @MainActor () -> Void) {
        guard monitor == nil else { return }
        let kinds: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                            .scrollWheel, .keyDown, .leftMouseDragged]
        // Local monitors are called on the main thread; say so to the compiler.
        monitor = NSEvent.addLocalMonitorForEvents(matching: kinds) { [weak self] event in
            MainActor.assumeIsolated {
                self?.last = Date()
                onInput()
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
