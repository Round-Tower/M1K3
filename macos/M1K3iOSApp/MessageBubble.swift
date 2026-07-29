//
//  MessageBubble.swift
//  M1K3iOS / M1K3visionOS
//
//  M1K3's asymmetric transcript rows, ported from the Mac house rule: the user's
//  turns are tinted-glass bubbles on the trailing edge; M1K3's turns are FLAT —
//  no card — sitting on the backdrop so the words read cleanly (the same rule the
//  Mac app follows so reading modes work on words, not markup).
//
//  Signed: Kev + claude-opus-4-8, 2026-07-06, Confidence 0.8. Prior: Unknown.
//  Review: claude-fable-5, 2026-07-18 — the Mac-feel pass: assistant turns now
//  render through the shared ReadingText (default/serif/OpenDyslexic/bionic),
//  gain the LegibilityScrim treatment (the avatar is a live backdrop now), and
//  the FOLLOWUPS chips the shared ChatSession was already populating are finally
//  rendered — tap-to-send via `onSendFollowUp`, mirroring MessageView.
//

import M1K3Chat
import M1K3Knowledge
import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    /// Chat backdrop active — M1K3's flat turns get a soft scrim so they read
    /// over the moving avatar (the Mac's LegibilityScrim treatment).
    var scrimmed = false
    var onSendFollowUp: (String) -> Void = { _ in }

    var body: some View {
        switch message.role {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    // Byte-parity with the Mac's user turn (MessageView): regular
                    // glass, accent tint 0.2, rect 18.
                    .m1k3Glass(cornerRadius: 18, tint: .accentColor.opacity(0.2))
                    .textSelection(.enabled)
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if let label = message.activityLabel, message.text.isEmpty {
                    activityRow(label)
                }
                if !message.text.isEmpty {
                    ReadingText(message.text)
                        .foregroundStyle(.primary)
                        .modifier(LegibilityScrim(active: scrimmed))
                }
                if case let .failed(reason) = message.status {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if !message.sources.isEmpty {
                    sourcesRow(message.sources)
                }
                followUpChips
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func activityRow(_ label: String) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sourcesRow(_ sources: [ChunkHit]) -> some View {
        let titles = Array(Set(sources.map(\.itemTitle))).prefix(4)
        return HStack(spacing: 6) {
            Image(systemName: "text.quote")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(titles.joined(separator: " · "))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.top, 2)
    }

    /// Up to 3 tap-to-send follow-up questions (FollowUpSplit parsed them from
    /// the model's trailing FOLLOWUPS: line — see ChatSession.send). Gated on
    /// `.complete`, matching the Mac's belt-and-braces.
    @ViewBuilder
    private var followUpChips: some View {
        if case .complete = message.status, !message.followUps.isEmpty {
            // Neighbouring glass chips share one container so Liquid Glass
            // renders them as a group (the Mac inputRow pattern).
            M1K3GlassGroup(spacing: 6) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(message.followUps, id: \.self) { question in
                        FollowUpChip(question: question) { onSendFollowUp(question) }
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}

private struct FollowUpChip: View {
    let question: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right").imageScale(.small)
                Text(question)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .m1k3Glass(cornerRadius: 14)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Ask: \(question)")
    }
}

/// The Mac's readability scrim for flat turns over a live avatar backdrop:
/// off → truly card-free; on → a soft dark scrim hugs the text.
private struct LegibilityScrim: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, active ? 12 : 0)
            .padding(.vertical, active ? 8 : 4)
            .background {
                if active {
                    // .thinMaterial, not a flat black fill — the old
                    // .black.opacity(0.3) read as a muddy off-brand slab in
                    // light mode. Kept in lock-step with the macOS
                    // LegibilityScrim (MessageView.swift), 2026-07-25.
                    RoundedRectangle(cornerRadius: 14)
                        .fill(.thinMaterial)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: active)
    }
}
