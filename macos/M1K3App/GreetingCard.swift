//
//  GreetingCard.swift
//  M1K3App
//
//  The guided first action — replaces the passive empty state (wordmark + one
//  sentence, zero affordance) that left a new user staring at a blank box with
//  an empty knowledge base. The hero is DOCUMENT DROP, deliberately over voice:
//  minute-one voice would debut as Apple Speech + system TTS + two TCC dialogs
//  (the product's worst self), while a grounded answer about the user's OWN
//  file is the thesis working at full strength on the default Mini config —
//  zero permissions, zero download. Voice is the minute-five reveal (the
//  labeled toolbar button).
//
//  Three states, driven by the ingest seam:
//    landing  — hero drop-zone (also clickable → importer) + one chip
//    busy     — "Reading it now…" while `isIngesting`
//    ask      — "Got it." + [Ask me about it]: one tap to the first whoa, no
//               blank-page "what do I type" moment. The canned ask renders as
//               an honest, visible user turn.
//
//  Mounted only while the transcript is empty (the existing EmptyChatView
//  slot), so it survives ingest (no messages yet) and vanishes on the first
//  turn. Returning users get the quiet variant — no "Nice to meet you" replay
//  on every new conversation.
//
//  Signed: Kev + claude-fable-5, 2026-07-03, Confidence 0.85 (state logic is
//  plain; look/feel + the ask-state beat are verify-by-launch). Prior: none
//  (new file; supersedes ContentView's EmptyChatView).
//  Review: Kev + claude-fable-5.1, 2026-09-11 — the one hardcoded chip becomes `starters`, drawn by
//  StarterPrompts' context rule (a door chip, up to two from what the stores hold, the rest random),
//  laid out two per row; ContentView redraws them every time the canvas goes blank.

import SwiftUI

struct GreetingCard: View {
    /// Display name from HelloView (nil → greet without one).
    let userName: String?
    /// The LIVE brain's display name for the disclosure caption.
    /// First session ever (no completed turn yet) → the full greeting;
    /// otherwise the quiet returning-user variant.
    let isFirstSession: Bool
    /// Ingest seam (drives the landing → busy → ask morphs).
    let isIngesting: Bool
    let lastIngestedTitle: String?
    /// The chips for this blank canvas (StarterPrompts.pick(context:)); each
    /// carries its own prompt. Empty → no chip row.
    var starters: [String] = ["What can you do?"]

    let onImport: () -> Void
    let onSend: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 20) {
            Text("M1K3")
                .font(.pixel(28))
                .kerning(2)
                .accessibilityAddTraits(.isHeader)

            if isFirstSession {
                Text(greetingLine)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            heroZone
                .frame(maxWidth: 440)

            if lastIngestedTitle == nil, !isIngesting, !starters.isEmpty {
                chipRows
            }
        }
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: isIngesting)
        .animation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.85), value: lastIngestedTitle)
        .padding(24)
        .onChange(of: lastIngestedTitle) { _, title in
            // The morph is visual; VoiceOver users need the same beat spoken.
            if let title {
                AccessibilityNotification.Announcement(
                    "\(title) is indexed. Ask me about it."
                ).post()
            }
        }
    }

    private var greetingLine: String {
        if let userName, !userName.isEmpty {
            "Nice to meet you, \(userName)."
        } else {
            "Nice to meet you."
        }
    }

    // MARK: - Hero zone (landing / busy / ask)

    @ViewBuilder
    private var heroZone: some View {
        if let title = lastIngestedTitle, !isIngesting {
            askState(title: title)
        } else if isIngesting {
            busyState
        } else {
            dropZone
        }
    }

    /// The hero: a big, obviously-droppable, also-clickable zone. The whole
    /// window already accepts drops (ContentView's dropDestination) — this is
    /// the invitation, and clicking opens the importer for the no-drag path.
    private var dropZone: some View {
        Button(action: onImport) {
            VStack(spacing: 8) {
                Text("Drop a file on me.")
                    .font(.title3.weight(.semibold))
                Text("PDF or text — read here, never uploaded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            // Explicit shape: bare glassEffect() defaults to a Capsule — every
            // glass call site in the app passes .rect, and the hit target two
            // lines down is the same 20pt rect (review catch).
            .glassEffect(.regular, in: .rect(cornerRadius: 20))
            .contentShape(.rect(cornerRadius: 20))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Drop a PDF or text file on the window, or activate to pick one. Files are read on this Mac only."
        )
        .accessibilityAddTraits(.isButton)
    }

    private var busyState: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.regular)
            Text("Reading it now…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 36)
        .frame(maxWidth: .infinity)
    }

    /// One tap to the first whoa. "Keep it short" is deliberate — Mini's best
    /// register, and it guards the moment against a wall of text.
    private func askState(title: String) -> some View {
        VStack(spacing: 12) {
            Label {
                Text("Got it. “\(title)” is in my head now.")
                    .font(.callout.weight(.medium))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .transition(.symbolEffect)
            }
            HStack(spacing: 12) {
                Button {
                    onSend("What should I know from “\(title)”? Keep it short.")
                } label: {
                    Text("Ask me about it")
                        .font(.headline)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.glassProminent)

                Button("Drop another", action: onImport)
                    .buttonStyle(.plain)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    /// Two chips per row — four long chips in one HStack overflow the 440pt
    /// hero width; a wrapping layout keeps every chip on one line.
    private var chipRows: some View {
        let rows = stride(from: 0, to: starters.count, by: 2).map { Array(starters[$0 ..< min($0 + 2, starters.count)]) }
        return VStack(spacing: 10) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    ForEach(row, id: \.self) { prompt in
                        chip(prompt) { onSend(prompt) }
                    }
                }
            }
        }
    }

    private func chip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .buttonStyle(.glass)
    }
}
