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
//  Review: Kev + claude-fable-5.1, 2026-09-08 — "Stopped" caption for an `interrupted` answer. Confidence now 0.8.
//  Review: Kev + claude-opus-4-6, 2026-09-22 — added toolTraceRow (the persisted
//  "Used web search · date & time" provenance line), visible live during and after
//  the turn. iOS had no tool trace at all. Confidence 0.85.
//
//  Review: Kev + claude-fable-5.1, 2026-10-09 — "Remember this photo" under a sent image (RememberPhotoButton).
//  Review: Kev + claude-opus-5-5, 2026-10-13 — the Mac's answer row comes to the phone (Kev rates answers on
//  iOS to evaluate chat): speak, copy, share, thumbs up, and thumbs down with an optional note committed on
//  Done (MessageView's semantics). Ratings go to the shared ChatSession store. Confidence 0.8 (verify-by-launch;
//  the wiring is pinned by PhoneAnswerActionsTests).
//  Review: Kev + claude-opus-5-5, 2026-10-13 (#597 follow-up) — 44 pt hit targets, the note field takes focus, and
//  a typed note can't be swiped away. Confidence 0.85.
//  TDD_SKIP: view body.
//  Review: Kev + claude-opus-5.5, 2026-10-27 — a tapped option in a typed `m1k3-choices` block (#717) sends
//  through `onSendFollowUp` (ChatScreen's brainReady gate), set only once the turn is `.complete`, as on the
//  Mac. TDD_SKIP: view body. Confidence 0.75 (verify-by-launch on iPhone owed).
//  Review: Kev + claude-opus-5.5, 2026-10-27 (self-review fold) — the answer's ReadingText says when the turn
//  is still streaming, so an open typed fence is a skeleton only then. Confidence 0.75.

import M1K3AnswerBlocks
import M1K3Chat
import M1K3Knowledge
import SwiftUI
import UIKit

struct MessageBubble: View {
    let message: ChatMessage
    /// Chat backdrop active — M1K3's flat turns get a soft scrim so they read
    /// over the moving avatar (the Mac's LegibilityScrim treatment).
    var scrimmed = false
    /// This answer's rating, if any (the shared ChatSession's map).
    var verdict: FeedbackVerdict?
    /// The saved thumbs-down note, prefilled when the field reopens.
    var existingComment: String?
    var onFeedback: (FeedbackVerdict, String?) -> Void = { _, _ in }
    var onSpeak: (String) -> Void = { _ in }
    var onSendFollowUp: (String) -> Void = { _ in }

    @State private var didCopy = false
    @State private var showComment = false
    @State private var commentDraft = ""
    @FocusState private var noteFocused: Bool

    var body: some View {
        switch message.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if let attachments = message.attachments, !attachments.isEmpty {
                    HStack(alignment: .bottom, spacing: 8) {
                        Spacer(minLength: 48)
                        ForEach(attachments, id: \.url) { attachment in
                            VStack(alignment: .trailing, spacing: 4) {
                                AsyncImage(url: attachment.url) { image in
                                    image.resizable().aspectRatio(contentMode: .fill)
                                } placeholder: {
                                    Color.secondary.opacity(0.2)
                                }
                                .frame(width: 80, height: 80)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .accessibilityLabel("Attached image")
                                RememberPhotoButton(attachment: attachment)
                            }
                        }
                    }
                }
                HStack {
                    Spacer(minLength: 48)
                    Text(message.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .m1k3Glass(cornerRadius: 18, tint: .accentColor.opacity(0.2))
                        .textSelection(.enabled)
                }
            }
        case .assistant:
            VStack(alignment: .leading, spacing: 8) {
                if let label = message.activityLabel, message.text.isEmpty {
                    activityRow(label)
                }
                if !message.text.isEmpty {
                    ReadingText(message.text, streaming: message.status == .streaming)
                        .foregroundStyle(.primary)
                        .environment(\.answerChoiceAction, answerChoiceAction)
                        .modifier(LegibilityScrim(active: scrimmed))
                }
                if message.interrupted == true {
                    Label("Stopped", systemImage: "stop.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if case let .failed(reason) = message.status {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if case .complete = message.status, !message.text.isEmpty {
                    answerActions
                }
                if !message.sources.isEmpty {
                    sourcesRow(message.sources)
                }
                toolTraceRow
                followUpChips
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The Mac's row under a finished answer (MessageView): speak, copy, share, then
    /// a thumbs-up in one tap and a thumbs-down that opens an optional note and
    /// commits with it on Done. A tap on thumbs-down alone never clobbers a saved note.
    private var answerActions: some View {
        HStack(spacing: 6) {
            Button { onSpeak(message.text) } label: { actionIcon("speaker.wave.2") }
                .accessibilityLabel("Speak this answer")
            Button { copyAnswer() } label: { actionIcon(didCopy ? "checkmark" : "doc.on.doc") }
                .accessibilityLabel(didCopy ? "Copied" : "Copy this answer")
            ShareLink(item: message.text + ShareSignature.answerSuffix) { actionIcon("square.and.arrow.up") }
                .accessibilityLabel("Share this answer")
            Divider().frame(height: 16).opacity(0.4)
            Button { onFeedback(.good, nil) } label: {
                actionIcon(verdict == .good ? "hand.thumbsup.fill" : "hand.thumbsup")
                    .foregroundStyle(verdict == .good ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
            }
            .accessibilityLabel("Good answer")
            .accessibilityAddTraits(verdict == .good ? .isSelected : [])
            Button {
                commentDraft = existingComment ?? ""
                showComment = true
            } label: {
                actionIcon(verdict == .bad ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                    .foregroundStyle(verdict == .bad ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
            }
            .accessibilityLabel("Needs work")
            .accessibilityHint("Opens a note on what was off")
            .accessibilityAddTraits(verdict == .bad ? .isSelected : [])
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .sensoryFeedback(.selection, trigger: verdict)
        .sheet(isPresented: $showComment) { feedbackNoteSheet }
    }

    /// One row icon with a 44 pt hit area (the HIG minimum); the glyph stays small.
    private func actionIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.footnote)
            .contentTransition(.symbolEffect(.replace))
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }

    /// The thumbs-down note: optional, but a quick "why" is what makes a bad answer
    /// fixable ("should have searched the web"). Done commits the verdict with it.
    private var feedbackNoteSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Note (optional)", text: $commentDraft, axis: .vertical)
                        .lineLimit(2 ... 6)
                        .focused($noteFocused)
                } footer: {
                    Text("A quick note, like \"should have searched the web\", so this can be fixed later.")
                }
            }
            .navigationTitle("What was off?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showComment = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onFeedback(.bad, commentDraft)
                        showComment = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
        // A typed note is never lost to a stray swipe: Cancel or Done, on purpose.
        .interactiveDismissDisabled(commentDraft != (existingComment ?? ""))
        .onAppear { noteFocused = true }
    }

    /// Copies the answer's markdown source, as the Mac does, with a brief tick.
    private func copyAnswer() {
        UIPasteboard.general.string = message.text
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
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

    @ViewBuilder
    private var toolTraceRow: some View {
        if let tools = message.toolsUsed, !tools.isEmpty {
            Label(ActivityLabeler.traceLabel(for: tools), systemImage: "wrench.and.screwdriver")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .animation(.easeOut(duration: 0.2), value: tools)
                .padding(.top, 2)
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

    /// A tapped option in a typed `m1k3-choices` block sends like a follow-up chip,
    /// once the turn is complete; nil leaves the card read-only.
    private var answerChoiceAction: AnswerChoiceAction? {
        guard case .complete = message.status else { return nil }
        return AnswerChoiceAction(onSendFollowUp)
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
