//
//  ChatBackdrop.swift
//  M1K3iOS / M1K3visionOS
//
//  The pixel-face avatar as a full-bleed reactive backdrop once a conversation
//  is underway — the Mac's AvatarChatBackground brought to the phone. It blooms
//  when M1K3 is idle and recedes (dims, blurs, scales back) while an answer
//  streams or the user is composing, so the words always win. The reactive
//  decision is the pure, TDD'd ChatBackdropTreatment shared with the Mac; this
//  view only applies it. Non-interactive and hidden from VoiceOver, like its
//  Mac sibling.
//
//  Signed: Kev + claude-fable-5, 2026-07-18, Confidence 0.8 (the treatment is
//  package-TDD'd; the full-bleed look, legibility, and bloom/recede feel on
//  device are verify-by-launch). Prior: none (new file, patterned on the Mac's
//  AvatarChatBackground.swift).
//

import M1K3Avatar
import SwiftUI

struct ChatBackdrop: View {
    let core: AppCore
    /// The user is composing — keyboard up or a draft in hand. Recede so the
    /// draft + transcript stay crisp. (Broader than the Mac's !draft.isEmpty:
    /// on a phone the keyboard shortens the viewport, so focus alone recedes.)
    let isComposing: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var treatment: ChatBackdropTreatment {
        ChatBackdropTreatment.resolve(
            activity: core.avatar.state.activity,
            isTyping: isComposing,
            reduceMotion: reduceMotion,
            // Battery state isn't observable; read at render time. Activity and
            // composing changes re-render and re-read it, which is timely enough.
            lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    var body: some View {
        let resolved = treatment
        ZStack {
            // paused honors the treatment's promise: recede/still/Reduce Motion
            // render one crisp frame and go QUIET — no 30fps churn under a live
            // blur while MLX is generating, no battery cost under Low Power.
            AvatarSurface(controller: core.avatar, paused: !resolved.animatesMotion)
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
        // Decorative — VoiceOver must never compete with the transcript.
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

/// The Mac's ReadingScrim stops verbatim — slightly darker at the top (nav bar)
/// and bottom (input bar + the newest, streaming turn), near-clear through the
/// middle — so text reads over a bright avatar without curtaining it.
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
