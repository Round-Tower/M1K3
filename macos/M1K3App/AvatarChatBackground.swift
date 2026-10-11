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

import Foundation
import M1K3Avatar
import SwiftUI

struct AvatarChatBackground: View {
    let env: AppEnvironment
    /// The user is composing — recede so the draft + transcript stay crisp.
    let isTyping: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
            AvatarSurface(env: env, paused: !resolved.animatesMotion)
                .scaleEffect(resolved.scale)
                .blur(radius: resolved.blur)
                .opacity(resolved.opacity)
                .ignoresSafeArea()
            ReadingScrim()
                .ignoresSafeArea()
        }
        // A background must never swallow chat/scroll interaction.
        .allowsHitTesting(false)
        .animation(transition(for: resolved), value: resolved)
        // Decorative here (unlike the voice hero, which IS the
        // content) — VoiceOver has nothing useful to say about a bloom/recede
        // backdrop sitting behind the transcript it must never compete with.
        .accessibilityHidden(true)
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
