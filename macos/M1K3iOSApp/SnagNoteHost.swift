//
//  SnagNoteHost.swift
//  M1K3iOS
//
//  #750 on iPhone and iPad: "I hit a snag last time." A small card at the top of the chat
//  screen, raised only after a session that didn't close cleanly (AppCore+Snag) and only for the
//  bands #708's offer is shown to. The report opens in a sheet first, editable, with Mac's three
//  honest buttons: keep it, copy it, or send it from your own mail app. Nothing leaves until Send.
//  A modifier on the chat screen from RootView, so ChatScreen's own long modifier chain is left
//  alone, and the sheet outlives the card it was raised from.
//
//  App glue: SnagNoteScanTests pins the age gate and the one Send call.
//
//  Signed: Kev + claude-opus-5.5, 2026-10-29, Confidence 0.7 (verify-by-launch owed: the card,
//  the sheet, Mail's compose window, VoiceOver on both). Prior: none (new file).
//  Review: Kev + claude-opus-5.5, 2026-10-29 (pre-push review fold) — builds on visionOS: the card's glass goes
//  through GlassCompat's m1k3Glass and the prominent buttons through snagProminent (visionOS has no glass
//  styles); the captions are localized; "Not now" gets a 44 pt target and the buttons stack at large text.
//  Confidence 0.75.
//

import M1K3Chat
import M1K3Diagnostics
import SwiftUI

struct SnagNoteHost: ViewModifier {
    @Environment(AppCore.self) private var core
    @AppStorage(PersistedAgeBandProvider.defaultsKey) private var ageBandRaw: String?
    @State private var draft: SnagDraft?

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if let snag = core.snag, AgeAppropriateness.fieldReportAllowed(for: AgeBand(persisted: ageBandRaw)) {
                    SnagNoteCard(
                        onSee: {
                            draft = core.snagDraft(snag)
                            core.snag = nil
                        },
                        onDismiss: { core.snag = nil }
                    )
                }
            }
            .sheet(item: $draft) { draft in
                SnagReportSheet(draft: draft, onDone: { self.draft = nil })
            }
    }
}

/// The one-time offer, in M1K3's voice. Stacked for a phone's width.
private struct SnagNoteCard: View {
    let onSee: () -> Void
    let onDismiss: () -> Void

    @ViewBuilder private var buttons: some View {
        Button("See the report", action: onSee)
            .snagProminent()
        Button("Not now", action: onDismiss)
            .foregroundStyle(.secondary)
            .frame(minHeight: 44) // a full touch target for the quiet button
            .contentShape(Rectangle())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text("I hit a snag last time. Send Round Tower a short report? You'll see it first.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "bandage").foregroundStyle(.tint)
            }
            // Side by side when they fit; stacked at large Dynamic Type sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .m1k3Glass(cornerRadius: 16)
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}

/// The exact report, editable, then the user's own mail app. Send never closes the sheet: an
/// accepted link is not a compose window, so the text stays here until Done.
private struct SnagReportSheet: View {
    let draft: SnagDraft
    let onDone: () -> Void

    @State private var text: String
    @State private var caption: String?

    private var isBlank: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(draft: SnagDraft, onDone: @escaping () -> Void) {
        self.draft = draft
        self.onDone = onDone
        _text = State(initialValue: draft.body)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("""
                    This is the whole message: that M1K3 didn't close cleanly last time, when that session began, \
                    the brain, the app and system versions, and any crash summaries this device kept. Nothing you \
                    typed or said goes with it. It goes to \(RoundTowerReports.recipient) from your own mail app, \
                    which opens with it filled in. M1K3 sends nothing itself. Round Tower reads it to find what went \
                    wrong, and deletes it if you ask. If you remember what you were doing, add it at the end: that \
                    helps most.
                    """)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)

                    TextEditor(text: $text)
                        .font(.callout)
                        .frame(minHeight: 260)
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                        .accessibilityLabel("The exact text that will be sent")

                    if let caption {
                        Text(caption)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Button("Send by email") {
                        switch SnagMailer.send(subject: draft.subject, body: text) {
                        case .opened:
                            caption = String(localized: """
                            Your mail app should now show it, addressed and filled in; it goes when you send it \
                            there. If no message appeared, Copy instead still has the text.
                            """)
                        case .copiedTruncated:
                            caption = String(localized: """
                            Your mail app opened with the start of it. The message was too long for one link, \
                            so the full text is on your clipboard — paste it in before you send.
                            """)
                        case .copiedNoMailClient, .copiedCouldNotOpen:
                            caption = String(localized: """
                            Your mail app didn't open it. The full text is on your clipboard — paste it into an \
                            email to \(RoundTowerReports.recipient).
                            """)
                        }
                    }
                    .snagProminent()
                    .frame(maxWidth: .infinity)
                    .disabled(isBlank)

                    Button("Copy instead") {
                        SnagMailer.copy(text)
                        caption = String(localized: "Copied. Nothing was sent — paste it wherever you like.")
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(isBlank)
                }
                .padding(20)
            }
            .navigationTitle("Send a short report?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(caption == nil ? "Not now" : "Done", action: onDone)
                }
            }
        }
    }
}

private extension View {
    /// The prominent button: Liquid Glass on iOS, a bordered fill on visionOS, where glass
    /// button styles don't exist (GlassCompat's rule).
    @ViewBuilder
    func snagProminent() -> some View {
        #if os(visionOS)
            buttonStyle(.borderedProminent)
        #else
            buttonStyle(.glassProminent)
        #endif
    }
}
