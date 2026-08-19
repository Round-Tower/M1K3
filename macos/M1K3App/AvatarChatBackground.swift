//
//  AvatarChatBackground.swift
//  M1K3App
//
//  The avatar (constellation / companion creature / pixel face) as a full-window
//  background behind the chat — opt-in, and REACTIVE: it blooms when M1K3 is idle
//  or speaking, and recedes (dims, blurs, scales back) while you read a streaming
//  answer or type, so the conversation always stays legible. Reuses AvatarSurface
//  (the same 3-way dispatch the avatar panel + voice hero use), so it inherits the
//  user's chosen companion for free; the reactive decision is the pure, TDD'd
//  ChatBackdropTreatment. Mirrors AudioCaptureBackdrop: a gated, reduce-motion-
//  aware, non-interactive layer over the glass.
//
//  Signed: Kev + claude-opus-4-8, 2026-06-17, Confidence 0.75 (treatment TDD'd;
//  the full-bleed look, legibility over the glass bubbles, and the bloom/recede
//  feel are verify-by-eye at ⌘R). Prior: Unknown.

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
            // The thinking rain over the avatar backdrop — mostly reasoning +
            // tool pings here (the answer's already in the bubble), so it
            // complements the transcript rather than duplicating it. Under the
            // scrim so chat text stays legible; the layer is itself
            // non-interactive + a11y-hidden.
            InferencePhosphorView()
                .ignoresSafeArea()
            ReadingScrim()
                .ignoresSafeArea()
        }
        // A background must never swallow chat/scroll interaction.
        .allowsHitTesting(false)
        .animation(transition(for: resolved), value: resolved)
        // Decorative here (unlike the avatar panel/voice hero, which ARE the
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

/// A gentle vertical scrim — slightly darker at the top (toolbar) and bottom
/// (input bar + the newest, streaming turn), near-clear through the middle — so
/// text reads over a bright avatar without curtaining it. Non-interactive.
private struct ReadingScrim: View {
    var body: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.18), location: 0.0),
                .init(color: .black.opacity(0.04), location: 0.28),
                .init(color: .black.opacity(0.04), location: 0.72),
                .init(color: .black.opacity(0.22), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
    }
}
